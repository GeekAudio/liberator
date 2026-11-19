#!/bin/bash
# make-kernel-collections.sh - make the two Intel kernel collections macOS 27.2 (26B123) starts from.
#
# Apple ships no Intel kernel collections for macOS 27. It does ship, in the Kernel Debug Kit for this build, the
# Intel kernel and Intel builds of its kernel extensions. This script takes those files from the kit you download,
# lays the needed parts end to end in a fixed order (the lists boot-26B123.src and sys-26B123.src), and turns each
# of the two results into a collection with bspatch and a delta kept beside this script. The deltas hold the link
# data of the collections and our own changes; every byte of Apple's code in the result comes from your kit.
#
# Only tools that come with macOS are used, so this runs the same on macOS 15 and macOS 26. Each step is checked
# against a pinned checksum: the kit's kernel, both laid-out sources, both deltas, and both results. Nothing is
# placed unless both collections are exactly the known ones; the driver's auxiliary collection is linked against
# exactly this boot collection.
#
#   sudo bash make-kernel-collections.sh --out DIR            dry run: checks, changes nothing
#   sudo bash make-kernel-collections.sh --out DIR --apply    make, verify, place the two files in DIR
#
# options
#   --out DIR     where BootKernelExtensions.kc and SystemKernelExtensions.kc go (give it to lay-down-27.sh as
#                 --kernel-collections). Must belong to root and not be writable by anyone else.
#   --kdk PATH    a Kernel Debug Kit for 26B123 you already have: the downloaded image (.dmg), or the folder an
#                 installed kit lives in (/Library/Developer/KDKs/KDK_27.2_26B123.kdk). Without it the image is
#                 downloaded from KDK_URL below and checked against a pinned checksum.
#   --work DIR    where the download and the opened package go (about 8 GB while it runs, removed afterwards)
#
# It ends with code 0 (done, or a clean dry run), 1 (refused or failed), 2 (unknown option) or 3: the running macOS
# lacks something this needs. Code 3 comes with one line starting "SYSTEM:" and only before anything is written.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
HERE=$(cd "$(dirname "$0")" && pwd)

BUILD=26B123
KDK_URL="https://github.com/dortania/KdkSupportPkg/releases/download/26B123/Kernel_Debug_Kit_27.2_build_26B123.dmg"
KDK_SIZE=1251288981
KDK_SHA256=c582c072188a15d8dbe0b878ab84563af8fb2baa25da2ea9565140de3df2228c
KERNEL_SHA256=3c9317518535791503970fbec322b9bba70e91f3a233536205ccd77b047ffc83
# kind, size and checksum of the laid-out source, size and checksum of the result, name of the result
KINDS="boot 86975005 26ac46a8020dc0ada411430a6d822d09cbc93af1ddb5407b9d5adac3369e1f72 64995328 e8aadd4736a06f34b403ee256e419d673ba8d8b412e44c0fdb7df7f87acd55ca BootKernelExtensions.kc
sys 23591473 7186040efe7c320f86147562735d235f222764be9fd0cf98c1410dafebb672b3 15958016 262c64047e9058e923a2a62e9d2361667a310ad3d7ca220595ad76269ad76434 SystemKernelExtensions.kc"
# the files kept beside this script, with their checksums
PARTS="4c6acb446c0fcec6820019bd5ecd02882f9003fe05ffccec37e5d4d1d155e86a boot-26B123.src
cc4c6d342ac105785c0b91320db5d7b701a23625184f2ffaafa6c3ba7cb1c319 sys-26B123.src
eeece21c8ae55e005bcf56b2726c08415bc90e5d2b594eb051f0e65a5b1ff52a boot-26B123.delta
8f275e337593905fba1d66425d39ce5f92d988042b4ffa20f8e74aa20f88074a sys-26B123.delta"
NEED_GB_DOWNLOAD=8; NEED_GB_IMAGE=7; NEED_GB_FOLDER=1
# for the progress lines: the size of the opened package, and how long each phase takes (seconds; the download at
# 30 MB a second, the others as measured)
KDK_TREE_BYTES=5537808384; T_UNPACK=30; T_COLLECTIONS=22

MODE=dry; OUT=""; KDK=""; WORK="/Library/Application Support/1401/golden-gate/laydown"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply;;
    --dry-run) MODE=dry;;
    --out) OUT=${2:?}; shift;;
    --kdk) KDK=${2:?}; shift;;
    --work) WORK=${2:?}; shift;;
    *) echo "STOP unknown option $1"; echo "RESULT stop"; exit 2;;
  esac
  shift
done
step() { echo "STEP $*"; }
ok()   { echo "OK   $*"; }
note() { echo "NOTE $*"; }
# Progress for the program that shows this run, one line each, never in a dry run:
#   PLAN <phase>:<weight> ...                          once, the phases this run will go through; weights sum to 100
#   PROGRESS <phase> <percent> <done bytes> <total bytes>   percent 0-100 within the phase; bytes 0 when they say nothing
# While a long step runs, a watcher looks every 2 seconds at what the step has produced so far and prints a line when
# the percent has moved. It never says 100: pg_end does, when the step is over and was checked.
PG_WATCH=""
pg() { echo "PROGRESS $1 $2 $3 $4"; }
pg_now() {  # <kind> <what>: bytes so far. file: a growing file; tree: a folder; used: a mounted volume; dd: a dd's own count
  case "$1" in
    file) stat -f %z "$2" 2>/dev/null || echo 0;;
    tree) du -sk "$2" 2>/dev/null | awk '{print $1 * 1024}';;
    used) df -k "$2" 2>/dev/null | awk 'NR==2 {print $3 * 1024}';;
    dd)   kill -INFO "$(cat "$2.pid" 2>/dev/null)" 2>/dev/null; sleep 0.3; awk '/bytes transferred/ {v=$1} END {print v + 0}' "$2" 2>/dev/null;;
  esac
}
pg_watch() {  # <phase> <total bytes> <kind> <what> [<bytes to take off> [<percent already said>]]
  local phase=$1 total=$2 kind=$3 what=$4 base=${5:-0} from=${6:-}
  [ -n "$from" ] || { pg "$phase" 0 0 "$total"; from=0; }
  ( last=$from
    while sleep 2; do
      now=$(pg_now "$kind" "$what"); now=$(( ${now:-0} - base )); [ "$now" -ge 0 ] || now=0
      pct=$(( total > 0 ? now * 100 / total : 0 )); [ "$pct" -le 99 ] || pct=99
      [ "$pct" -le "$last" ] || { echo "PROGRESS $phase $pct $now $total"; last=$pct; }
    done ) &
  PG_WATCH=$!
}
# The watcher is stopped with KILL, which it cannot ignore or outlive: a plain kill could leave it running, and
# the wait below would then wait for ever.
pg_stop() { [ -z "$PG_WATCH" ] || { kill -KILL "$PG_WATCH" 2>/dev/null; wait "$PG_WATCH" 2>/dev/null; PG_WATCH=""; }; }
pg_end() { pg_stop; pg "$1" 100 "$2" "$2"; }
plan() {  # <phase>:<seconds> ...: the PLAN line; each phase's share of the time, at least 1, summing to 100
  printf '%s\n' "$@" | awk -F: '{n[NR] = $1; s[NR] = $2; t += $2; if (!big || $2 > s[big]) big = NR}
    END { for (i = 1; i <= NR; i++) { w[i] = int(s[i] * 100 / t); if (w[i] < 1) w[i] = 1; sum += w[i] }
          w[big] += 100 - sum; printf "PLAN"; for (i = 1; i <= NR; i++) printf " %s:%d", n[i], w[i]; printf "\n" }'
}
ATTACHED=""; BUILD_DIR=""
cleanup() {
  pg_stop
  local d; for d in $ATTACHED; do hdiutil detach "$d" -quiet 2>/dev/null || hdiutil detach "$d" -force -quiet 2>/dev/null; done
  ATTACHED=""
  [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
}
stop() { echo "STOP $*"; cleanup; echo "RESULT stop"; exit 1; }
trap cleanup EXIT
sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
free_gb() { df -g "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }
# A folder a root script reads from or writes to: it and every folder above it belong to root, none is writable by
# group or others (the sticky temporary folders are not accepted), and no part of the path is a symbolic link.
safe_dir() {
  local p=$1 q
  case "$p" in /*) :;; *) echo "$p is not a full path"; return 1;; esac
  q=$p
  while [ "$q" != "/" ] && [ -n "$q" ]; do
    [ ! -L "$q" ] || { echo "$q is a symbolic link"; return 1; }
    if [ -e "$q" ]; then
      [ -d "$q" ] || { echo "$q is not a folder"; return 1; }
      [ "$(stat -f %u "$q")" = 0 ] || { echo "$q does not belong to root"; return 1; }
      case "$(stat -f %Lp "$q")" in *[2367][0-7]|*[2367]) echo "$q is writable by group or others"; return 1;; esac
    fi
    q=$(dirname "$q")
  done
}

# ---------------------------------------------------------------------------------------------------------------
step "this machine"
# A refusal that is the running macOS's doing (a system tool is missing or cannot do what is needed) ends with code 3
# and one line starting "SYSTEM:". Every such check runs here, before anything is downloaded or written.
system_stop() { echo "SYSTEM: $*"; echo "RESULT system"; exit 3; }
for t in bspatch hdiutil pkgutil shasum curl tail head stat df awk; do command -v "$t" >/dev/null 2>&1 || system_stop "the system tool '$t' is missing"; done
bspatch 2>&1 | grep -q 'oldfile newfile patchfile' || system_stop "bspatch on this macOS is not the one this script knows"
pkgutil --expand-full /nonexistent-package /nonexistent-folder 2>&1 | grep -q 'unrecognized option' && system_stop "pkgutil on this macOS cannot open a package in full (--expand-full)"
[ "$(printf abc | shasum -a 256 2>/dev/null | awk '{print $1}')" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ] || system_stop "shasum on this macOS does not compute sha256"
ok "macOS $(sw_vers -productVersion 2>/dev/null), the needed system tools are present"

step "the files beside this script"
echo "$PARTS" | while read -r want f; do
  [ -f "$HERE/$f" ] && [ ! -L "$HERE/$f" ] || { echo "missing $f"; exit 1; }
  [ "$(sha "$HERE/$f")" = "$want" ] || { echo "changed or incomplete $f"; exit 1; }
done || stop "a file this script needs is missing or is not the one it was made for (line above). Nothing was downloaded or written"
ok "4 files present and unchanged"

step "folders"
[ -n "$OUT" ] || stop "give --out DIR"
if [ "$MODE" = apply ]; then [ "$(id -u)" = 0 ] || stop "run with sudo"; fi
why=$(safe_dir "$OUT") || stop "--out: $why"
why=$(safe_dir "$WORK") || stop "--work: $why"
ok "out $OUT, work $WORK"

step "the Kernel Debug Kit"
SRC_KIND=download; NEED_GB=$NEED_GB_DOWNLOAD
if [ -n "$KDK" ]; then
  if [ -d "$KDK" ]; then
    [ -f "$KDK/System/Library/Kernels/kernel" ] || stop "--kdk: $KDK holds no System/Library/Kernels/kernel"
    SRC_KIND=folder; NEED_GB=$NEED_GB_FOLDER
  elif [ -f "$KDK" ]; then SRC_KIND=image; NEED_GB=$NEED_GB_IMAGE
  else stop "--kdk: $KDK is neither a file nor a folder"; fi
  note "using $KDK; its kernel and every part taken from it are checked"
else
  KDK=$WORK/Kernel_Debug_Kit_27.2_build_${BUILD}.dmg
  if [ -f "$KDK" ] && [ "$(stat -f %z "$KDK")" = "$KDK_SIZE" ]; then note "found $KDK"; NEED_GB=$NEED_GB_IMAGE
  else
    len=$(curl -fsSIL --proto =https --proto-redir =https -m 60 "$KDK_URL" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v}')
    [ "$len" = "$KDK_SIZE" ] || stop "the address for the Kernel Debug Kit does not offer the known file (answer: ${len:-none}). Download 'Kernel Debug Kit 27.2 build $BUILD' from Apple's developer downloads and give it with --kdk"
    note "will download $KDK_URL (1.25 GB)"
  fi
fi
WP=$WORK; while [ ! -d "$WP" ]; do WP=$(dirname "$WP"); done
FREE=$(free_gb "$WP")
[ -n "$FREE" ] && [ "$FREE" -ge "$NEED_GB" ] || stop "$WP has ${FREE:-an unknown amount of} GB free; $NEED_GB GB are needed while this runs"
ok "source chosen, $FREE GB free"

if [ "$MODE" != apply ]; then
  echo "NOTE dry run. With --apply this would: get and check the Kernel Debug Kit, open its package, lay the kernel and"
  echo "NOTE the listed extension files end to end, check both results, make the two collections with bspatch, compare"
  echo "NOTE them with the known checksums, place them in $OUT and remove everything else it made."
  echo "RESULT dry"; exit 0
fi

# =============================================================================================================
umask 077
mkdir -p "$WORK" "$OUT" || stop "cannot make the folders"
why=$(safe_dir "$OUT") || stop "--out: $why"
why=$(safe_dir "$WORK") || stop "--work: $why"
BUILD_DIR=$WORK/kernel-collections.build
rm -rf "$BUILD_DIR"; mkdir -m 700 "$BUILD_DIR" || stop "could not make $BUILD_DIR"

# the phases of this run: no download when the image is already here, no unpacking when a kit folder was given
PH=""
[ "$SRC_KIND" != download ] || { [ -f "$KDK" ] && [ "$(stat -f %z "$KDK")" = "$KDK_SIZE" ]; } || PH="kdk-download:$((KDK_SIZE / 30000000))"
[ "$SRC_KIND" = folder ] || PH="$PH kdk-unpack:$T_UNPACK"
plan $PH collections:$T_COLLECTIONS

step "get and check the kit"
if [ "$SRC_KIND" = download ]; then
  if [ ! -f "$KDK" ] || [ "$(stat -f %z "$KDK")" != "$KDK_SIZE" ]; then
    pg_watch kdk-download "$KDK_SIZE" file "$KDK"
    curl -sS -f -L -C - --proto =https --proto-redir =https -o "$KDK" --connect-timeout 30 --retry 50 --retry-delay 5 --retry-all-errors \
         --speed-limit 1024 --speed-time 120 "$KDK_URL"; rc=$?
    pg_stop
    [ "$rc" = 0 ] || stop "the download did not finish (curl $rc); run again to continue it"
    [ "$(stat -f %z "$KDK")" = "$KDK_SIZE" ] || stop "the downloaded kit does not have the known size: delete $KDK and run again"
    pg kdk-download 100 "$KDK_SIZE" "$KDK_SIZE"
  fi
  [ "$(stat -f %z "$KDK")" = "$KDK_SIZE" ] && [ "$(sha "$KDK")" = "$KDK_SHA256" ] || stop "the downloaded kit does not have the known size and checksum: delete $KDK and run again"
  ok "downloaded kit has the pinned sha256"
fi
if [ "$SRC_KIND" = folder ]; then ROOT=$KDK
else
  out=$(hdiutil attach -readonly -nobrowse -noautoopen "$KDK" 2>&1) || stop "could not attach the kit image"
  dev=$(echo "$out" | awk '$1 ~ /^\/dev\/disk[0-9]+$/ {print $1; exit}'); ATTACHED="$ATTACHED $dev"
  MP=$(echo "$out" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')
  PKG="$MP/KernelDebugKit.pkg"
  [ -f "$PKG" ] || stop "the image holds no KernelDebugKit.pkg"
  pg_watch kdk-unpack "$KDK_TREE_BYTES" tree "$BUILD_DIR/package"
  pkgutil --expand-full "$PKG" "$BUILD_DIR/package" >/dev/null 2>&1; rc=$?
  pg_stop
  [ "$rc" = 0 ] || stop "could not open the kit's package"
  pg kdk-unpack 100 "$KDK_TREE_BYTES" "$KDK_TREE_BYTES"
  ROOT=$BUILD_DIR/package/KDK.pkg/Payload
  hdiutil detach "$dev" -quiet 2>/dev/null && ATTACHED=""
fi
[ -f "$ROOT/System/Library/Kernels/kernel" ] || stop "the kit does not hold a kernel where expected"
[ "$(sha "$ROOT/System/Library/Kernels/kernel")" = "$KERNEL_SHA256" ] || stop "this is not the Kernel Debug Kit for macOS 27.2 ($BUILD): its kernel is a different one. Nothing was placed in $OUT"
ok "the kit's kernel is the macOS 27.2 ($BUILD) Intel kernel"

# Lay the listed parts end to end. One line of a list: first byte to take (counted from 0), number of bytes, file.
lay_out() {  # $1 list  $2 result
  local off len rel f
  : > "$2" || return 1
  while IFS='	' read -r off len rel; do
    f=$ROOT/$rel
    [ -f "$f" ] || { echo "the kit has no $rel"; return 1; }
    tail -c +$((off + 1)) "$f" | head -c "$len" >> "$2" || return 1
  done < "$1"
}
pg collections 0 0 0
echo "$KINDS" | while read -r kind ssize ssha tsize tsha name; do
  step "the $kind collection"
  why=$(lay_out "$HERE/$kind-$BUILD.src" "$BUILD_DIR/$kind.source") || { echo "STOP ${why:-could not lay out the source}"; exit 1; }
  [ "$(stat -f %z "$BUILD_DIR/$kind.source")" = "$ssize" ] && [ "$(sha "$BUILD_DIR/$kind.source")" = "$ssha" ] \
    || { echo "STOP a file in this kit differs from the one the $kind collection is made from. Nothing was placed in $OUT"; exit 1; }
  [ "$kind" = boot ] && pg collections 35 0 0 || pg collections 85 0 0
  bspatch "$BUILD_DIR/$kind.source" "$BUILD_DIR/$name" "$HERE/$kind-$BUILD.delta" || { echo "STOP bspatch could not make the $kind collection"; exit 1; }
  [ "$(stat -f %z "$BUILD_DIR/$name")" = "$tsize" ] && [ "$(sha "$BUILD_DIR/$name")" = "$tsha" ] \
    || { echo "STOP the $kind collection does not have the known checksum. Nothing was placed in $OUT"; exit 1; }
  rm -f "$BUILD_DIR/$kind.source"
  [ "$kind" != boot ] || pg collections 70 0 0
  ok "$name has the known checksum"
done || { cleanup; echo "RESULT stop"; exit 1; }

step "place"
echo "$KINDS" | while read -r kind ssize ssha tsize tsha name; do
  cp "$BUILD_DIR/$name" "$OUT/$name.new" && chown root:wheel "$OUT/$name.new" && chmod 644 "$OUT/$name.new" && mv -f "$OUT/$name.new" "$OUT/$name" || exit 1
  [ "$(sha "$OUT/$name")" = "$tsha" ] || exit 1
done || stop "could not place the collections, or they do not read back with the known checksums"
pg collections 100 0 0
cleanup
echo "OK   BootKernelExtensions.kc and SystemKernelExtensions.kc are in $OUT"
echo "RESULT ok"
