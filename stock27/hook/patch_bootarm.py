#!/usr/bin/env python3
"""Arm the exec hook from kernel start (boot-arg a2xbootarm=1), so arm64-only programs launchd runs before any daemon
(boot tasks such as cc_fips_test) reach the interpreter. Anchored on exact strings; every count asserted."""
import sys
p = sys.argv[1]; s = open(p).read()

def sub(old, new, n=1):
    global s
    c = s.count(old); assert c == n, f"anchor count {c} != {n}: {old[:60]!r}"
    s = s.replace(old, new)

sub('#include <kern/clock.h>\n', '#include <kern/clock.h>\n#include <pexpert/pexpert.h>  /* PE_parse_boot_argn - the boot-arm switch */\n')

sub('kern_return_t\na2x_hook_start(kmod_info_t *ki __unused, void *d __unused)\n', r'''/* ---------------------------------------------------------- boot arm */

/*
 * Arming from a daemon leaves a window: launchd runs its boot tasks (cc_fips_test and others) before any
 * LaunchDaemon starts, and with Apple's own arm64-only files in place those fail with "Bad CPU type" and
 * launchd panics on purpose. With boot-arg a2xbootarm=1 the hook arms itself as soon as the kernel's
 * code-signing policies are in place.
 *
 * Order matters: the split-signature MAC policy must be registered after AMFI's, so this waits until the
 * sandbox stand-in publishes security.mac.sandbox.sentinel, which happens after AMFI registers. If that
 * never appears (a configuration without it), it arms anyway after 30 s and says so.
 *
 * The dead-man still applies, with a boot-length window; the keepalive daemon takes it over when it runs.
 */
extern int a2x_adopt_enable;
#define A2X_BOOTARM_DEADMAN_SECS 900
#define A2X_BOOTARM_POLL_MS      10
#define A2X_BOOTARM_MAX_POLLS    3000            /* 30 s */
static thread_call_t a2x_bootarm_call;
static uint32_t a2x_bootarm_polls;
static int a2x_bootarm_result = -1;              /* -1 = not attempted */

static void
a2x_bootarm_fire(void *a __unused, void *b __unused)
{
	size_t len = 0;
	int have = (sysctlbyname("security.mac.sandbox.sentinel", NULL, &len, NULL, 0) == 0);
	uint64_t deadline;

	if (!have && ++a2x_bootarm_polls < A2X_BOOTARM_MAX_POLLS) {
		clock_interval_to_deadline(A2X_BOOTARM_POLL_MS, NSEC_PER_MSEC, &deadline);
		thread_call_enter_delayed(a2x_bootarm_call, deadline);
		return;
	}
	a2x_adopt_enable = 1;
	if (a2x_deadman_secs < A2X_BOOTARM_DEADMAN_SECS) {
		a2x_deadman_secs = A2X_BOOTARM_DEADMAN_SECS;
	}
	a2x_bootarm_result = a2x_arm();
	A2X_LOG("boot-arm: %s after %u polls, arm=%d",
	    have ? "code-signing policies ready" : "TIMED OUT waiting for the sandbox sentinel",
	    a2x_bootarm_polls, a2x_bootarm_result);
}

SYSCTL_INT(_a2x, OID_AUTO, exec_hook_bootarm_result, CTLFLAG_RD | CTLFLAG_LOCKED,
    &a2x_bootarm_result, 0, "boot-arm outcome: -1 not tried, 0 armed, else errno");

kern_return_t
a2x_hook_start(kmod_info_t *ki __unused, void *d __unused)
''')

sub('''	&sysctl__a2x_exec_fat_graded, &sysctl__a2x_exec_fat_installed,
};''', '''	&sysctl__a2x_exec_fat_graded, &sysctl__a2x_exec_fat_installed,
	&sysctl__a2x_exec_hook_bootarm_result,
};''')

sub('''	A2X_LOG("loaded, verified=%d, armed=0; "
	    "arm with: sysctl -w a2x.exec_hook_enable=1", a2x_verified);
	return KERN_SUCCESS;''', '''	A2X_LOG("loaded, verified=%d, armed=0; "
	    "arm with: sysctl -w a2x.exec_hook_enable=1", a2x_verified);

	int bootarm = 0;
	if (PE_parse_boot_argn("a2xbootarm", &bootarm, sizeof(bootarm)) && bootarm && a2x_verified &&
	    a2x_deadman_call != NULL) {
		a2x_bootarm_call = thread_call_allocate(a2x_bootarm_fire, NULL);
		if (a2x_bootarm_call != NULL) {
			thread_call_enter(a2x_bootarm_call);
			A2X_LOG("boot-arm requested (a2xbootarm=1): waiting for the code-signing policies");
		}
	}
	return KERN_SUCCESS;''')
open(p, 'w').write(s); print("patched", p)
