// SPDX-License-Identifier: BSD-3-Clause
//
// sandbox.c - the "Sandbox" MAC policy and the com.apple.security.sandbox library for macOS 27 x86_64.
//
// macOS 27 ships Sandbox.kext for arm64e only. Without a policy named "Sandbox", every __mac_syscall("Sandbox", ...)
// fails, libsystem_secinit traps on the refused profile apply, and Quarantine, AppleSystemPolicy and
// EndpointSecurity cannot load because they link against this bundle.
//
// This version is PERMISSIVE: profiles are accepted and not enforced, every check answers "allowed", no file has
// a storage class, and no process has a container. It provides the interfaces so the system runs; it is not a
// security boundary. Enforcement (the 27 profile format, 204 operations) is separate work.
//
// Call numbers are the 27 dispatch table (hook_policy_syscall). The mac_policy_ops slot of mpo_policy_syscall is
// 117 in the 27 layout (verified against the 27 Sandbox binary: slots 115/116/117 = init/initbsd/syscall).

#include <mach/mach_types.h>
#include <libkern/libkern.h>
#include <sys/errno.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <string.h>
#include <sys/vnode.h>

extern int file_vnode_withvid(int fd, vnode_t *vpp, uint32_t *vidp);   /* com.apple.kpi.bsd (file_vnode is private-only) */
extern int file_drop(int fd);

struct mac_policy_conf {
    const char          *mpc_name;
    const char          *mpc_fullname;
    char const * const  *mpc_labelnames;
    unsigned int         mpc_labelname_count;
    const void          *mpc_ops;
    int                  mpc_loadtime_flags;
    int                 *mpc_field_off;
    int                  mpc_runtime_flags;
    void                *mpc_list;
    void                *mpc_data;
};
typedef unsigned int mac_policy_handle_t;
extern int mac_policy_register(struct mac_policy_conf *mpc, mac_policy_handle_t *handlep, void *xd);

#define MPO_SLOTS          335      // entries in the 27 mac_policy_ops
#define MPO_POLICY_SYSCALL 117
#define MPO_CRED_LABEL_ASSOCIATE_FORK 9   // 27.2 kernel: _mac_cred_label_associate_fork calls [ops+0x48](cred, child proc)
#define MPO_PROC_NOTIFY_EXIT 243          // 27.2 kernel: _proc_exit -> _mac_proc_notify_exit(proc) calls [ops+0x798]
#define MPO_VNODE_CHECK_OPEN 267       // mpo_vnode_check_open in the 27 layout (mpo_slots_27.tsv, ops+0x858)
#define MPO_PRIV_GRANT     314      // mpo_priv_grant in the 27 layout (mpo_slots_27.tsv; Apple's _hook_priv_grant)

typedef uint64_t user_addr_t;
struct proc;

// Storage-class property bits, as exported by the 27 bundle.
const uint64_t SANDBOX_STORAGE_CLASS_GROUP_ANY = 0;
const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_READ_RESTRICTED = 1;
const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_WRITE_RESTRICTED = 2;
const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_REPLACEMENT_RESTRICTED = 4;
const uint64_t SANDBOX_STORAGE_CLASS_PROPERTY_ACCEPTS_USER_APPROVAL = 0x8000000000000000ULL;

enum {
    SB_SET_USERLAND_PROFILE = 0, SB_SET_KEXT_PROFILE = 1, SB_CHECK = 2, SB_NOTE = 3, SB_CONTAINER = 4,
    SB_EXT_ISSUE = 5, SB_EXT_CONSUME = 6, SB_EXT_RELEASE = 7, SB_EXT_UPDATE_FILE = 8,
    SB_SUSPEND = 10, SB_UNSUSPEND = 11, SB_PASSTHROUGH_ACCESS = 12, SB_INSPECT = 16, SB_CHECK_BULK = 21,
    SB_BUILTIN_QUERY = 22, SB_REF_RETAIN = 28, SB_REF_RELEASE = 29, SB_PATTERN_SET = 31, SB_PATTERN_GET = 32,
    SB_APPROVAL_RESULT = 33, SB_APPROVAL_CACHE_CLEAR = 40, SB_APPROVAL_WATCHDOG = 41, SB_MOUNT_FLAG_SET = 46,
    SB_SPAWNATTRS_QUERY = 51, SB_MSGFILTER_CHECK = 52, SB_MSGFILTER_RELEASE = 53, SB_PROFILE_REGISTRATION = 59,
    SB_MSGFILTER_RETAIN = 61, SB_APPBUNDLE_REGISTER = 62, SB_APPBUNDLE_UNREGISTER = 63, SB_ENABLE_STATE_FLAG = 65,
    SB_SET_CONTAINER = 66, SB_GET_CONTAINER_EXPECTED = 67, SB_BASTION_PROFILE = 68, SB_SYNCROOT_REGISTER = 69,
    SB_SANDCASTLE_EXCEPTION = 71, SB_APPCONTAINER_REGISTER = 75, SB_APPCONTAINER_UNREGISTER = 76,
    SB_APPCONTAINER_CHECK = 77, SB_EXT_UPDATE_BY_FILEID = 79, SB_EXT_RELEASE_LAST = 80, SB_ROOT_TRANSLATION = 82,
    SB_FINDER_AUTOMATION = 83, SB_DISKIMAGE_REGISTER = 85, SB_DISKIMAGE_UNREGISTER = 86, SB_REVOKE = 88,
    SB_APPPROTECTION_REGISTER = 89, SB_APPBUNDLE_SCAN_START = 91, SB_APPBUNDLE_SCAN_END = 92,
    SB_ROOTLESS_FD_CLASS = 261, SB_ROOTLESS_FD_CLASS_CHECK = 264,   // 27.2 new range 0x103-0x108; only 261 measured (others stay unknown + logged)
};

static unsigned int sb_unknown_logged;

extern int copyinstr(user_addr_t uaddr, void *kaddr, size_t len, size_t *done);

#define SB_EXT_TOKEN_MAX 0x3ff0          // the buffer libsystem_sandbox allocates for the token (27.2, measured)

static void sb_hex(char *o, uint64_t v, int digits)
{
    static const char hx[] = "0123456789abcdef";
    for (int i = digits - 1; i >= 0; i--) { o[i] = hx[v & 0xf]; v >>= 4; }
}

// A token in Apple's layout: <64 hex mac>;<flags 2>;<8>;<8>;<8>;<class len 16>;<class>;01;<type 8>;<16>;<path len 2>;<path>
// Permissive: consume accepts anything, so the mac is zeros; the shape is kept so a parser in userland reads it.
static int sb_ext_issue(user_addr_t arg)
{
    uint64_t a[7];
    char cls[128], path[1024], tok[320];      // kernel stack, ~1.5 KB: no shared state between callers
    size_t cl = 0, pl = 0;
    if (!arg || copyin(arg, a, sizeof a)) return EFAULT;
    if (!a[4]) return EINVAL;
    cls[0] = path[0] = 0;
    if (a[0] && copyinstr(a[0], cls, sizeof cls, &cl)) cls[0] = 0;
    if (a[2] && copyinstr(a[2], path, sizeof path, &pl)) path[0] = 0;
    cl = 0; while (cls[cl]) cl++;
    pl = 0; while (path[pl]) pl++;
    char *o = tok;
    for (int i = 0; i < 64; i++) *o++ = '0';
    *o++ = ';'; *o++ = '0'; *o++ = '0';
    for (int k = 0; k < 3; k++) { *o++ = ';'; for (int i = 0; i < 8; i++) *o++ = '0'; }
    *o++ = ';'; sb_hex(o, cl, 16); o += 16;
    *o++ = ';'; for (size_t i = 0; i < cl; i++) *o++ = cls[i];
    *o++ = ';'; *o++ = '0'; *o++ = '1';
    *o++ = ';'; sb_hex(o, a[1] & 0xffffffffULL, 8); o += 8;
    *o++ = ';'; for (int i = 0; i < 16; i++) *o++ = '0';
    *o++ = ';'; sb_hex(o, pl > 0xff ? 0xff : pl, 2); o += 2;
    *o++ = ';';
    size_t hl = (size_t)(o - tok);             // header max 64+3+27+17+(1+127)+3+9+17+3+1 = 272 < 320
    if (hl + pl + 1 > SB_EXT_TOKEN_MAX) return ENAMETOOLONG;
    int e = copyout(tok, a[4], hl);
    if (!e) e = copyout(path, a[4] + hl, pl + 1);   // path[pl] is the NUL
    return e;
}

static int64_t sb_ext_handle_next = 1;

static int sb_ext_consume(user_addr_t arg)
{
    uint64_t a[3];
    if (!arg || copyin(arg, a, sizeof a)) return EFAULT;
    int64_t h = __sync_fetch_and_add(&sb_ext_handle_next, 1);
    if (a[2]) (void)copyout(&h, a[2], sizeof h);
    return 0;
}

/* WHICH PROCESSES ARE SANDBOXED, AND WHERE THEIR CONTAINER IS. Measured on macOS 27.2 (26B123,
      libsystem_secinit + libsystem_sandbox, dyld_info -disassemble):
        SET_USERLAND_PROFILE (0) args = { profile bytes, length, container root path or NULL, strlen(path)+1 or 0 }
          (libsecinit _libsecinit_appsandbox and libsandbox sandbox_apply_bytecode build the same four words)
        CHECK (2) args = { &result, pid, operation or NULL, filter type, filter arg, flags, pidversion }
          flags bit 0x40000000 = the pidversion at +0x30 must match (sandbox_check_by_audit_token sets it)
          libsandbox returns result != 0; with operation NULL that is "this process is sandboxed" (libxpc xpc_main asks it)
        CONTAINER (4) args = { pid, 0, buffer, size, 0 }  (sandbox_container_path_for_pid; pid 0 is made getpid() in user space)
   Before this, op 0 returned 0 and recorded nothing: sandbox_check(pid, NULL, 0) = 0 for EVERY process (measured:
      cfprefsd, secinitd, Finder, every .appex), so a sandboxed XPC service trapped in libxpc ("requested sandbox, but is not
      sandboxed!") and no app had a container.
   Apple keeps this on the credential label: a fork child inherits it, exec keeps it. Here it is a table keyed by the proc
      itself (exec keeps the proc), entered at op 0, copied to the child in cred_label_associate_fork and removed in
      proc_notify_exit. 27.2 KDK kernel, measured: _mac_cred_label_associate_fork calls [ops+0x48](cred, child proc) from the
      fork path -> slot 9; _proc_exit calls _mac_proc_notify_exit(proc) -> [ops+0x798] -> slot 243. A child always passes the
      fork hook, which first clears any entry left for its proc address, so a reused address never inherits a stale answer.
      Operations are still answered "allowed" — enforcement is PLAN 2b/2c. */
extern struct proc *current_proc(void);
extern int PE_parse_boot_argn(const char *arg_string, void *arg_ptr, int max_arg);   /* IOKit KPI */
extern struct proc *proc_find(int pid);
extern int proc_rele(struct proc *p);
extern int proc_pid(struct proc *p);
extern void proc_name(int pid, char *buf, int size);
/* proc_find_audit_token (sys/proc.h, BSDKernel): proc_find + pidversion == val[7], else NULL */

#define SBT_N   4096        /* live sandboxed processes at once; chosen, ~10x what a full desktop runs */
#define SBC_N   154         /* distinct containers at once (about 60 on a full desktop). Sized so the process table's origin fields
                               fit in the same __DATA size, which keeps the boot kernel collection's layout and the kit's patch
                               records after this kext where they are */
#define SBC_LEN 1024        /* MAXPATHLEN */
/* rpid/rwhy/rnm = the process that applied the profile (the ROOT, copied unchanged to every fork child) and how:
   'c' op 0 container profile, 'a' op 1 sandbox_apply. Beta 4: `log` on 27 said "Cannot run while sandboxed" with no
   recorded reason - inherited entries were never logged, so the origin was invisible. */
static struct { const struct proc *key; int pid; short ci; char rwhy; int rpid; char rnm[17]; } sbt[SBT_N];   /* key 0 = free; ci -1 = no container */
static unsigned int sb_self_logged;
static char sbc[SBC_N][SBC_LEN];
static lck_mtx_t *sb_mtx;
static unsigned int sb_set_logged, sb_full_logged;

/* Data-vault confinement. This stand-in does not evaluate profiles, but one consequence of a profile is checked by
   Apple's own code: Shortcuts (siriactionsd, VoiceShortcutClient WFSandboxEnter) marks its profile cache as a data vault
   (op 261), applies its profile with sandbox_apply (op 1), then lists the cache and exits unless that fails with
   permission denied. Measured n 27.2: with nothing enforced it exited 230 times and every App-Intent widget
   (Weather, Photos) stayed empty. Rule: once a process has applied its own profile, the vaults it marked itself are
   closed to it. Vaults marked by others and app-sandboxed processes (op 0) are untouched. */
#define SBV_N 64            /* vaults remembered at once; chosen, a handful of daemons mark one each */
#define SBV_PER_PROC 8      /* chosen: one process may hold at most 8; its 9th replaces its oldest open one */
static struct { const struct proc *key; int pid; vnode_t vp; uint32_t vid; int closed; uint32_t seq; } sbv[SBV_N];
static uint32_t sbv_seq;
static unsigned int sbv_logged;
static volatile int sbv_any;   /* set once any vault is closed; the open hook costs one load until then */

static void sbv_drop_locked(const struct proc *k)
{
    for (int i = 0; i < SBV_N; i++) if (sbv[i].key == k) sbv[i].key = 0;
}

static int sbt_find_locked(const struct proc *k, int pid)
{
    if (!k) return -1;
    for (int i = 0; i < SBT_N; i++) if (sbt[i].key == k && sbt[i].pid == pid) return i;
    return -1;
}

static void sbt_drop_locked(const struct proc *k)
{
    for (int i = 0; i < SBT_N; i++) if (sbt[i].key == k) sbt[i].key = 0;
}

/* index of path in the container pool, adding it; a slot no live entry refers to is reused; -2 = pool full */
static int sbc_intern_locked(const char *path)
{
    for (int c = 0; c < SBC_N; c++) if (sbc[c][0] && !strcmp(sbc[c], path)) return c;
    for (int c = 0; c < SBC_N; c++) {
        int used = sbc[c][0] != 0;
        for (int i = 0; used == 1 && i < SBT_N; i++) if (sbt[i].key && sbt[i].ci == c) used = 2;
        if (used != 2) { strlcpy(sbc[c], path, SBC_LEN); return c; }
    }
    return -2;
}

static int sbt_put_locked(const struct proc *k, int pid, short ci, char rwhy, int rpid, const char *rnm)
{
    int i = sbt_find_locked(k, pid);
    if (i < 0) for (int j = 0; j < SBT_N; j++) if (!sbt[j].key) { i = j; break; }
    if (i < 0) return ENOSPC;
    sbt[i].key = k; sbt[i].pid = pid; sbt[i].ci = ci;
    sbt[i].rwhy = rwhy; sbt[i].rpid = rpid; strlcpy(sbt[i].rnm, rnm ? rnm : "?", sizeof sbt[i].rnm);
    return 0;
}

static int sb_profile_set(user_addr_t arg)
{
    if (!sb_mtx) return 0;                            /* a2xsbstate=0: the old permissive answer */
    uint64_t a[4];
    char path[SBC_LEN];
    size_t done = 0;
    if (!arg || copyin(arg, a, sizeof a)) return EFAULT;
    if (!a[0]) return EINVAL;
    path[0] = 0;
    if (a[2]) { int e = copyinstr(a[2], path, sizeof path, &done); if (e) return e; }
    struct proc *me = current_proc();
    int pid = proc_pid(me), e = 0;
    char rnm[17]; proc_name(pid, rnm, sizeof rnm);
    lck_mtx_lock(sb_mtx);
    short ci = -1;
    if (path[0]) { int c = sbc_intern_locked(path); if (c == -2) e = ENOSPC; else ci = (short)c; }
    if (!e) e = sbt_put_locked(me, pid, ci, 'c', pid, rnm);
    lck_mtx_unlock(sb_mtx);
    if (e) {
        if (sb_full_logged++ < 8) printf("a2x-sandbox: profile for pid %d NOT recorded (%d) - table full\n", pid, e);
        return e;
    }
    if (sb_set_logged < 64) {
        char nm[64]; proc_name(pid, nm, sizeof nm); sb_set_logged++;
        printf("a2x-sandbox: sandboxed pid %d %s container %s\n", pid, nm, path[0] ? path : "(none)");
    }
    return 0;
}

/* 1 = sandboxed, 0 = not, -1 = no such process (or its pidversion differs) */
static int sb_is_sandboxed(int pid, int want_ver, int ver, char *container, size_t clen)
{
    if (container && clen) container[0] = 0;
    if (pid <= 0 || !sb_mtx) return 0;
    struct proc *q;
    if (want_ver) { audit_token_t t = {{0}}; t.val[5] = (unsigned)pid; t.val[7] = (unsigned)ver; q = proc_find_audit_token(t); }
    else q = proc_find(pid);
    if (!q) return -1;
    lck_mtx_lock(sb_mtx);
    int i = sbt_find_locked(q, pid), r = i >= 0;
    if (r && container && clen && sbt[i].ci >= 0) strlcpy(container, sbc[sbt[i].ci], clen);
    lck_mtx_unlock(sb_mtx);
    proc_rele(q);
    return r;
}

/* mac_policy_ops slot 9 (27.2): runs in the parent's thread with the new child; the child of a sandboxed process is
   sandboxed with the same container, and no child starts with an entry left at its address */
static void sb_cred_label_associate_fork(void *cred, struct proc *child)
{
    struct proc *parent = current_proc();
    if (!sb_mtx || !child || child == parent) return;
    int e = 0, cpid = proc_pid(child);
    lck_mtx_lock(sb_mtx);
    sbt_drop_locked(child);
    int i = sbt_find_locked(parent, proc_pid(parent));
    if (i >= 0) e = sbt_put_locked(child, cpid, sbt[i].ci, sbt[i].rwhy, sbt[i].rpid, sbt[i].rnm);
    lck_mtx_unlock(sb_mtx);
    if (e && sb_full_logged++ < 8) printf("a2x-sandbox: fork child pid %d NOT recorded - table full\n", cpid);
}

/* mac_policy_ops slot 243 (27.2): the process is gone */
static void sb_proc_notify_exit(struct proc *p)
{
    if (!p || !sb_mtx) return;
    lck_mtx_lock(sb_mtx);
    sbt_drop_locked(p);
    sbv_drop_locked(p);
    lck_mtx_unlock(sb_mtx);
}

/* op 261: { fd of the directory just made, storage-class label }. Remember the directory for this process. */
static void sbv_mark(user_addr_t arg)
{
    uint64_t a[2];
    vnode_t vp = 0;
    if (!sb_mtx || !arg || copyin(arg, a, sizeof a)) return;
    uint32_t vid = 0;
    if (file_vnode_withvid((int)a[0], &vp, &vid) || !vp) return;
    struct proc *me = current_proc();
    int pid = proc_pid(me), placed = 0;
    lck_mtx_lock(sb_mtx);
    for (int i = 0; i < SBV_N && !placed; i++)
        if (sbv[i].key == me && sbv[i].pid == pid && sbv[i].vp == vp && sbv[i].vid == vid) placed = 1;
    int mine = 0, oldest = -1;
    for (int i = 0; i < SBV_N && !placed; i++)
        if (sbv[i].key == me && sbv[i].pid == pid) {
            mine++;
            if (!sbv[i].closed && (oldest < 0 || sbv[i].seq < sbv[oldest].seq)) oldest = i;
        }
    int slot = -1;
    if (!placed && mine >= SBV_PER_PROC) slot = oldest;          /* over its share: replace its own oldest open vault */
    for (int i = 0; i < SBV_N && !placed && slot < 0 && mine < SBV_PER_PROC; i++) if (!sbv[i].key) slot = i;
    if (!placed && slot >= 0) {
        sbv[slot].key = me; sbv[slot].pid = pid; sbv[slot].vp = vp; sbv[slot].vid = vid; sbv[slot].closed = 0;
        sbv[slot].seq = ++sbv_seq; placed = 1;
    }
    lck_mtx_unlock(sb_mtx);
    file_drop((int)a[0]);
    if (!placed && sbv_logged++ < 8) printf("a2x-sandbox: vault for pid %d NOT recorded - table full\n", pid);
}

/* op 1 (libsandbox sandbox_apply on 27): the process is now sandboxed by its own profile; its vaults close */
static int sbv_apply(void)
{
    if (!sb_mtx) return 0;
    struct proc *me = current_proc();
    int pid = proc_pid(me), n = 0, e;
    char rnm[17]; proc_name(pid, rnm, sizeof rnm);
    lck_mtx_lock(sb_mtx);
    e = sbt_put_locked(me, pid, -1, 'a', pid, rnm);
    for (int i = 0; i < SBV_N; i++) if (sbv[i].key == me && sbv[i].pid == pid) { sbv[i].closed = 1; n++; }
    if (n) sbv_any = 1;
    lck_mtx_unlock(sb_mtx);
    if (e && sb_full_logged++ < 8) printf("a2x-sandbox: profile for pid %d NOT recorded (%d) - table full\n", pid, e);
    if (n && sbv_logged++ < 64) {
        char nm[64]; proc_name(pid, nm, sizeof nm);
        printf("a2x-sandbox: pid %d %s applied its profile - %d vault(s) closed to it\n", pid, nm, n);
    }
    return 0;
}

/* mac_policy_ops slot 267 (27.2) */
static int sb_vnode_check_open(void *cred, vnode_t vp, void *label, int acc_mode)
{
    if (!sbv_any || !sb_mtx || !vp) return 0;
    struct proc *me = current_proc();
    int pid = proc_pid(me), deny = 0;
    uint32_t vid = vnode_vid(vp);
    lck_mtx_lock(sb_mtx);
    for (int i = 0; i < SBV_N && !deny; i++)
        if (sbv[i].key == me && sbv[i].pid == pid && sbv[i].closed && sbv[i].vp == vp && sbv[i].vid == vid) deny = 1;
    lck_mtx_unlock(sb_mtx);
    return deny ? EPERM : 0;
}

static int sb_policy_syscall(struct proc *p, int call, user_addr_t arg)
{
    switch (call) {
    case SB_CONTAINER: {             // sbstate: { pid, 0, buffer, size, 0 }
        uint64_t a[4]; char c[SBC_LEN];
        if (!arg || copyin(arg, a, sizeof a)) return EFAULT;
        int r = sb_is_sandboxed((int)a[0], 0, 0, c, sizeof c);
        if (r < 0) return ESRCH;
        if (!r || !c[0]) return ENOENT;
        size_t n = strlen(c) + 1;
        if (!a[2] || a[3] < n) return ERANGE;
        return copyout(c, a[2], n);
    }
    case SB_GET_CONTAINER_EXPECTED:
        return ENOENT;
    case SB_EXT_ISSUE:
        // p-5 fix (was a jump-table byte patch): ENOTSUP broke every GUI session process.
        // success must also WRITE a token: libsecinit traps on an empty container extension.
        return sb_ext_issue(arg);
    case SB_EXT_CONSUME:
        return sb_ext_consume(arg);
    case SB_ROOTLESS_FD_CLASS:
        sbv_mark(arg);
        return 0;
    case SB_ROOTLESS_FD_CLASS_CHECK:   // 264: same {fd,label}, called right after 261 to confirm it took; must agree
        // 27.2 rootless_mkdir_{nounlink,restricted,datavault} (libsystem_sandbox 0x...dc99, measured) calls op 261
        // with {fd of the new dir, storage-class label} and UNLINKS the dir if it fails: dirhelper could not create
        // /var/folders/zz on a fresh Data volume -> confstr EIO -> WindowServer exit(1). Permissive model = no file has a
        // storage class (sandbox_check_storage_class_for_vnode answers ENOENT), so accept and record nothing.
        return 0;
    case SB_CHECK: {
        // libsandbox sandbox_check_common passes args+0 = &result (an UNINITIALIZED word on its stack) and
        // returns `result != 0` = DENIED when the syscall returns 0. Returning 0 without writing it made every
        // sandbox_check deny on stack garbage: launchd's privileged mach-lookup check -> 1100 BOOTSTRAP_NOT_PRIVILEGED
        // -> configd SCDynamicStoreCreate NULL -> configd crash -> no en0, no ssh. Permissive = write 0 (allowed).
        // sbstate: operation NULL asks "is this process sandboxed"; any operation is still allowed (enforcement = PLAN 2c).
        // only the first three words are required: a shorter caller's struct must not turn into EFAULT (= -1 = "denied")
        uint64_t a[7] = {0}, res = 0;
        if (!arg || copyin(arg, a, 3 * sizeof a[0])) return EFAULT;
        if (copyin(arg + 3 * sizeof a[0], &a[3], 4 * sizeof a[0])) a[3] = a[4] = a[5] = a[6] = 0;
        if (!a[2]) {
            int r = sb_is_sandboxed((int)a[1], (a[5] & 0x40000000ULL) != 0, (int)a[6], 0, 0);
            if (r < 0) return ESRCH;
            res = (uint64_t)r;
            int me = proc_pid(current_proc());
            if (r == 1 && (int)a[1] == me && sb_self_logged < 48) {
                char nm[17], why = '?', rn[17] = "?"; int rp = -1;
                proc_name(me, nm, sizeof nm);
                lck_mtx_lock(sb_mtx);
                int i = sbt_find_locked(current_proc(), me);
                if (i >= 0) { why = sbt[i].rwhy; rp = sbt[i].rpid; strlcpy(rn, sbt[i].rnm, sizeof rn); }
                lck_mtx_unlock(sb_mtx);
                sb_self_logged++;
                printf("a2x-sandbox: self-check pid %d %s = sandboxed; root pid %d %s via %c\n", me, nm, rp, rn, why);
            }
        }
        if (a[0]) (void)copyout(&res, (user_addr_t)a[0], sizeof res);
        return 0;
    }
    case SB_SET_USERLAND_PROFILE:
        return sb_profile_set(arg);
    case SB_SET_KEXT_PROFILE:
        return sbv_apply();
    case SB_NOTE:
    case SB_EXT_RELEASE: case SB_EXT_UPDATE_FILE: case SB_SUSPEND: case SB_UNSUSPEND:
    case SB_PASSTHROUGH_ACCESS: case SB_INSPECT: case SB_CHECK_BULK: case SB_BUILTIN_QUERY:
    case SB_REF_RETAIN: case SB_REF_RELEASE: case SB_PATTERN_SET: case SB_PATTERN_GET: case SB_APPROVAL_RESULT:
    case SB_APPROVAL_CACHE_CLEAR: case SB_APPROVAL_WATCHDOG: case SB_MOUNT_FLAG_SET: case SB_SPAWNATTRS_QUERY:
    case SB_MSGFILTER_CHECK: case SB_MSGFILTER_RELEASE: case SB_PROFILE_REGISTRATION: case SB_MSGFILTER_RETAIN:
    case SB_APPBUNDLE_REGISTER: case SB_APPBUNDLE_UNREGISTER: case SB_ENABLE_STATE_FLAG: case SB_SET_CONTAINER:
    case SB_BASTION_PROFILE: case SB_SYNCROOT_REGISTER: case SB_SANDCASTLE_EXCEPTION:
    case SB_APPCONTAINER_REGISTER: case SB_APPCONTAINER_UNREGISTER: case SB_APPCONTAINER_CHECK:
    case SB_EXT_UPDATE_BY_FILEID: case SB_EXT_RELEASE_LAST: case SB_ROOT_TRANSLATION: case SB_FINDER_AUTOMATION:
    case SB_DISKIMAGE_REGISTER: case SB_DISKIMAGE_UNREGISTER: case SB_REVOKE: case SB_APPPROTECTION_REGISTER:
    case SB_APPBUNDLE_SCAN_START: case SB_APPBUNDLE_SCAN_END:
        return 0;
    default:
        if (sb_unknown_logged < 32) { sb_unknown_logged++; printf("a2x-sandbox: unknown call %d\n", call); }
        return ENOTSUP;                 // the 27 dispatcher's own default
    }
}

static const void *sb_ops[MPO_SLOTS];
static struct mac_policy_conf sb_conf = {
    .mpc_name = "Sandbox",
    .mpc_fullname = "Seatbelt sandbox policy",
    .mpc_ops = sb_ops,
};
static mac_policy_handle_t sb_handle;

// ---- library interface used by Quarantine and AppleSystemPolicy ----

int sandbox_check_vnode(void *ctx, int type, void *a2, void *a3, void *a4)
{
    return 0;
}

int sandbox_requires_quarantine_for_vnode(void *vp)
{
    return 0;
}

// Quarantine: 0 = success, the label is stored through out (identity + 0x78); no label in a permissive sandbox.
int sandbox_responsibility_label_alloc(void *identity, void **out)
{
    if (out) *out = NULL;
    return 0;
}

void sandbox_responsibility_label_free(void *label)
{
}

void sandbox_set_responsibility_functions(const void *table)
{
}

// No vnode has a storage class. A question about any of the three restriction properties (mask bits 0-2) is answered
// "no" with success; anything else is EINVAL. This is what the shipped collection's byte patch at file offset 0x108a494
// made the previous build answer ("as the 27.2 one does"); it now lives here instead of in the patch list.
int sandbox_check_storage_class_for_vnode(void *vp, uint64_t mask, const char *name, uint8_t *out)
{
    if (!(mask & 7)) return EINVAL;
    if (out) *out = 0;
    return 0;
}

// Block ABI: the invoke pointer is at offset 16; it receives the block itself, then the arguments.
struct sb_block { void *isa; int flags; int reserved; void (*invoke)(void *, void *); };

int sandbox_get_syspolicy_for_vnode_b(void *vp, struct sb_block *blk)
{
    if (blk && blk->invoke) blk->invoke(blk, NULL);     // no recorded policy, as for an uncached vnode
    return 0;
}

int sandbox_set_syspolicy_for_vnode(void *vp, void *policy)
{
    return 0;
}

void sandbox_set_syspolicy_invalidation_callback(void *cb)
{
}

// AppleSystemPolicy panics at start unless this returns 0 ("ASP unable to register sandbox callback: %d").
int sandbox_set_bastion_callback(void *cb)
{
    return 0;
}

kern_return_t a2x_sandbox_start(kmod_info_t *ki, void *data);

/* 27 kernel _mach_msg_filter_callbacks (KDK: register needs +0x08 non-null; v1 needs +0x10..+0x30 non-null). */
struct a2x_mmfilter_cbs {
    unsigned int version;                                         /* +0x00 */
    int           (*fetch)(void *task, void *portlabel, int msgid, int *fpid);  /* +0x08 1 = allow */
    kern_return_t (*alloc)(void *sp_info, void **sblabel_out);     /* +0x10 */
    void          (*dealloc)(void *sblabel);                       /* +0x18 */
    void         *(*derive)(void *sblabel, int *flags);            /* +0x20 */
    kern_return_t (*get_conn_policy)(void *svc, void *conn, int *fpid); /* +0x28 */
    void         *(*retain)(void *sblabel);                        /* +0x30 returns a pointer */
};
/* kmutil ignores an unsigned kext that declares kpi.private (A/B), and only kpi.private exports the register
   function. So it is found by slide from mac_policy_register (kpi.dsep, already bound). Unslid addresses are from the
   27 kernel 26A5425a, md5 5610e408 (= the KC tree kernel). A byte guard refuses to call anything else. */
/* { _mac_policy_register, _mach_msg_filter_register_callback } unslid: 27.0 26A5425a, 27.2 26B123 (KDK symbols). */
static const struct { uint64_t mpr, mmf; const char *name; } a2x_mmf_kernels[] = {
    { 0xffffff8000ab4340ULL, 0xffffff80002627f0ULL, "27.0 26A5425a" },
    { 0xffffff8000ab9a00ULL, 0xffffff8000262750ULL, "27.2 26B123" },
};
typedef int (*a2x_mmf_reg_t)(const struct a2x_mmfilter_cbs *);
static int sb_mm_register(const struct a2x_mmfilter_cbs *cbs)
{
    static const unsigned char want[13] = { 0x48,0x85,0xff,0x74,0x54,0xb8,0x05,0x00,0x00,0x00,0x48,0x83,0x3d };
    for (unsigned k = 0; k < sizeof a2x_mmf_kernels / sizeof a2x_mmf_kernels[0]; k++) {
        uint64_t slide = (uint64_t)(uintptr_t)&mac_policy_register - a2x_mmf_kernels[k].mpr;
        if (slide & 0xfffULL) continue;                       /* not this kernel */
        const unsigned char *fn = (const unsigned char *)(uintptr_t)(a2x_mmf_kernels[k].mmf + slide);
        int i = 0;
        while (i < 13 && fn[i] == want[i]) i++;
        if (i < 13) {
            printf("a2x-sandbox: mmf register guard MISMATCH at byte %d (%s, slide 0x%llx) - not called\n", i, a2x_mmf_kernels[k].name, slide);
            return -1;
        }
        printf("a2x-sandbox: mmf kernel %s slide 0x%llx\n", a2x_mmf_kernels[k].name, slide);
        return ((a2x_mmf_reg_t)(uintptr_t)fn)(cbs);
    }
    printf("a2x-sandbox: mmf no known kernel (mac_policy_register %p) - not called\n", (void *)&mac_policy_register);
    return -1;
}

static int sb_mm_fetch(void *task, void *portlabel, int msgid, int *fpid) { if (fpid) *fpid = 0; return 1; }
/* No label on any service port: is_connection_for_service then returns 0 with filter id 0. */
static kern_return_t sb_mm_alloc(void *sp_info, void **out) { if (out) *out = 0; return KERN_SUCCESS; }
static void sb_mm_dealloc(void *l) { }
static void *sb_mm_derive(void *l, int *flags) { return 0; }
static kern_return_t sb_mm_getconn(void *svc, void *conn, int *fpid) { if (fpid) *fpid = 0; return KERN_SUCCESS; }
static void *sb_mm_retain(void *l) { return l; }
static const struct a2x_mmfilter_cbs sb_mm_cbs = {
    1, sb_mm_fetch, sb_mm_alloc, sb_mm_dealloc, sb_mm_derive, sb_mm_getconn, sb_mm_retain,
};
/* ---- privilege grants ----
 * priv_check_cred() gives root every privilege by uid; anyone else needs a MAC policy to GRANT it. On 27 that policy is
 * Sandbox: _hook_priv_grant evaluates "system-privilege", and the platform profile allows each PRIV_* only to a process
 * holding the matching entitlement. Same rule here, same entitlement names (the 27 Sandbox's own strings).
 * Without it every non-root daemon that needs one fails: WindowServer (uid 88) work_interval_create -> EPERM -> NULL
 * work interval -> SIGSEGV at WSInitialize, and the desktop never comes up. */
struct task;
extern struct task *current_task(void);
extern void *a2x_copy_client_entitlement(struct task *t, const char *name)
    __asm("__ZN12IOUserClient21copyClientEntitlementEP4taskPKc");
extern void a2x_osobject_release(const void *o) __asm("__ZNK8OSObject7releaseEv");
extern const void *const *const kOSBooleanTrue;   /* C++ reference in libkern: the symbol holds a pointer to the object's pointer */

static const struct { int priv; const char *ent; } sb_priv_ents[] = {
    { 1001, "com.apple.private.kernel.uuid-policy" },              /* PRIV_PROC_UUID_POLICY */
    { 1002, "com.apple.private.kernel.global-proc-info" },         /* PRIV_GLOBAL_PROC_INFO */
    { 1003, "com.apple.private.kernel.system-override" },          /* PRIV_SYSTEM_OVERRIDE */
    { 1005, "com.apple.private.kernel.selective-forced-idle" },    /* PRIV_SELECTIVE_FORCED_IDLE */
    { 1008, "com.apple.private.kernel.work-interval" },            /* PRIV_WORK_INTERVAL */
    { 1009, "com.apple.private.smb.timemachine-control" },         /* PRIV_SMB_TIMEMACHINE_CONTROL */
    { 1011, "com.apple.private.kernel.ktrace-background" },        /* PRIV_KTRACE_BACKGROUND */
    { 1012, "com.apple.private.kernel.setpriority-darwin-role" },  /* PRIV_SETPRIORITY_DARWIN_ROLE */
    { 1013, "com.apple.private.kernel.set-package-extensions" },   /* PRIV_PACKAGE_EXTENSIONS */
    { 1014, "com.apple.private.apfs.trim-active-file" },           /* PRIV_TRIM_ACTIVE_FILE */
    { 10000, "com.apple.private.network.privileged-traffic-class" },
    { 10001, "com.apple.private.network.socket-delegate" },
    { 10002, "com.apple.private.network.interface-control" },
    { 10003, "com.apple.private.network.statistics" },
    { 10004, "com.apple.private.necp.policies" },
    { 10008, "com.apple.private.network.intcoproc.restricted" },
    { 10010, "com.apple.developer.networking.multipath_extended" },
    { 10014, "com.apple.private.validated-resolver" },
    { 10015, "com.apple.developer.networking.custom-protocol" },
    { 10016, "com.apple.private.necp.drop_all_bypass" },
    { 10017, "com.apple.private.network.ipsec-wake-packet" },
    { 11000, "com.apple.private.network.reserved-port" },
    { 12000, "com.apple.private.skywalk.register-user-pipe" },
    { 12001, "com.apple.private.skywalk.register-kernel-pipe" },
    { 12002, "com.apple.private.skywalk.register-net-if" },
    { 12003, "com.apple.private.skywalk.register-flow-switch" },
    { 12010, "com.apple.private.skywalk.observe-all" },
    { 12011, "com.apple.private.skywalk.observe-stats" },
    { 14000, "com.apple.private.vfs.open-by-id" },
    { 14001, "com.apple.private.vfs.move-data-extents" },
    { 14002, "com.apple.private.vfs.snapshot" },
    { 14002, "com.apple.developer.vfs.snapshot" },
    { 14002, "com.apple.private.apfs.arv.limited.snapshot" },
    { 14004, "com.apple.private.vfs.dataless-resolver" },
    { 14006, "com.apple.private.vfs.setsize" },
};

static int sb_has_bool_ent(const char *name)
{
    struct task *t = current_task();
    if (!t) return 0;
    const void *o = a2x_copy_client_entitlement(t, name);
    if (!o) return 0;
    int yes = (o == *kOSBooleanTrue);
    a2x_osobject_release(o);
    return yes;
}

/* 0 = granted; EPERM = not granted here (priv_check_cred then returns EPERM unless another policy grants it). */
static int sb_priv_grant(void *cred, int priv)
{
    for (unsigned i = 0; i < sizeof sb_priv_ents / sizeof sb_priv_ents[0]; i++)
        if (sb_priv_ents[i].priv == priv && sb_has_bool_ent(sb_priv_ents[i].ent)) return 0;
    return EPERM;
}

kern_return_t a2x_sandbox_stop(kmod_info_t *ki, void *data);

/* security.mac.sandbox.sentinel: libsystem_sandbox _amkrtemp reads it to name every atomic temp file
   (<path><sentinel>-XXXXXX). Absent = NULL + ENOENT = AtomicTempFile::create throws = no keychain can be created,
   so no System.keychain. Real 27: ".sb-" + 8 hex, different on every machine.
   _sysctl__security_mac_children is exported only by kpi.private, which makes kmutil silently drop this unsigned
   kext (project_m27_kc_member_kmutil_traps), so the parent is found by walking down from kpi.bsd's sysctl__children. */
extern struct sysctl_oid_list sysctl__children;
extern void read_random(void *buffer, u_int numBytes);
static struct sysctl_oid_list sb_sysctl_children;
static char sb_sentinel[16];
static struct sysctl_oid sb_oid_node = {
    .oid_parent = 0, .oid_number = OID_AUTO, .oid_kind = CTLTYPE_NODE | CTLFLAG_RD | CTLFLAG_LOCKED | CTLFLAG_KERN | CTLFLAG_OID2,
    .oid_arg1 = &sb_sysctl_children, .oid_arg2 = 0, .oid_name = "sandbox", .oid_handler = 0, .oid_fmt = "N",
    .oid_descr = "", .oid_version = SYSCTL_OID_VERSION, .oid_refcnt = 0,
};
static struct sysctl_oid sb_oid_sentinel = {
    .oid_parent = &sb_sysctl_children, .oid_number = OID_AUTO, .oid_kind = CTLTYPE_STRING | CTLFLAG_RD | CTLFLAG_LOCKED | CTLFLAG_KERN | CTLFLAG_OID2,
    .oid_arg1 = sb_sentinel, .oid_arg2 = sizeof sb_sentinel, .oid_name = "sentinel", .oid_handler = sysctl_handle_string, .oid_fmt = "A",
    .oid_descr = "", .oid_version = SYSCTL_OID_VERSION, .oid_refcnt = 0,
};
static struct sysctl_oid_list *sb_sysctl_child(struct sysctl_oid_list *list, const char *name)
{
    struct sysctl_oid *o;
    SLIST_FOREACH(o, list, oid_link)
        if (o->oid_name && !strcmp(o->oid_name, name) && (o->oid_kind & CTLTYPE) == CTLTYPE_NODE) return (struct sysctl_oid_list *)o->oid_arg1;
    return 0;
}
static void sb_publish_sentinel(void)
{
    uint32_t r = 0;
    read_random(&r, sizeof r);
    snprintf(sb_sentinel, sizeof sb_sentinel, ".sb-%08x", r);
    struct sysctl_oid_list *sec = sb_sysctl_child(&sysctl__children, "security");
    struct sysctl_oid_list *mac = sec ? sb_sysctl_child(sec, "mac") : 0;
    if (!mac) { printf("a2x-sandbox: security.mac not found - sentinel NOT published\n"); return; }
    sb_oid_node.oid_parent = mac;
    sysctl_register_oid(&sb_oid_node);
    sysctl_register_oid(&sb_oid_sentinel);
    printf("a2x-sandbox: security.mac.sandbox.sentinel = %s\n", sb_sentinel);
}

kern_return_t a2x_sandbox_start(kmod_info_t *ki, void *data)
{
    sb_publish_sentinel();
    /* sbstate escape hatch: boot-arg a2xsbstate=0 (OpenCore config.plist, editable with the VM off) = no table, no hooks,
       every answer as before this change. Printed either way so the serial log says which one booted. */
    int sbon = 1;
    (void)PE_parse_boot_argn("a2xsbstate", &sbon, sizeof sbon);
    if (sbon) {
        sb_mtx = lck_mtx_alloc_init(lck_grp_alloc_init("a2x-sandbox", 0), 0);   /* sbstate */
        if (!sb_mtx) { printf("a2x-sandbox: no lock - not registering\n"); return KERN_FAILURE; }
        sb_ops[MPO_CRED_LABEL_ASSOCIATE_FORK] = (const void *)sb_cred_label_associate_fork;
        sb_ops[MPO_PROC_NOTIFY_EXIT] = (const void *)sb_proc_notify_exit;
        sb_ops[MPO_VNODE_CHECK_OPEN] = (const void *)sb_vnode_check_open;
    }
    printf("a2x-sandbox: sandboxed-process table %s (fork slot %d, exit slot %d)\n", sbon ? "ON" : "OFF by a2xsbstate=0",
           MPO_CRED_LABEL_ASSOCIATE_FORK, MPO_PROC_NOTIFY_EXIT);
    sb_ops[MPO_POLICY_SYSCALL] = (const void *)sb_policy_syscall;
    sb_ops[MPO_PRIV_GRANT] = (const void *)sb_priv_grant;
    int r = mac_policy_register(&sb_conf, &sb_handle, data);
    printf("a2x-sandbox: mac_policy_register(\"Sandbox\") = %d (permissive)\n", r);
    /* without this every XPC check-in fails kr=46 (version 0 = not registered). */
    int mr = sb_mm_register(&sb_mm_cbs);
    printf("a2x-sandbox: mach_msg_filter_register_callback(v1) = %d\n", mr);
    return r == 0 ? KERN_SUCCESS : KERN_FAILURE;
}

kern_return_t a2x_sandbox_stop(kmod_info_t *ki, void *data)
{
    return KERN_FAILURE;
}
