#!/bin/bash
# install-apple.sh - macOS 27.2 on a real Intel Mac (2013 and later), run from Tahoe on the same Mac (Golden Gate's
# finish step does that). macOS 27 for Intel has no graphics drivers; this Mac's Tahoe has the ones it runs on. This
# package works the same way on every Mac:
#  1. reads which graphics drivers the running Tahoe has loaded (AMD, Intel or NVIDIA), copies those kernel drivers
#     into a private folder and the same vendors' user-space bundles onto the macOS 27 system volume. They are read
#     from this Mac and never shipped.
#  2. on AMD graphics, adds one load command to macOS 27's copy of libAMDIL902 (Tahoe's shader compiler) so it loads
#     amdil_rtfix.dylib, which lets it compile macOS 27's shaders. Only the exact 18,187,216-byte build is changed.
#  3. links the auxiliary kernel collection (those graphics drivers + NMXAudio, the audio driver) against the laid-down
#     macOS 27.2 boot and system collections. kmutil must run here: macOS 27's own refuses this pair.
#  4. installs three helpers on macOS 27: RenderBox on its CPU renderer (this GPU has no framebuffer fetch), the
#     internal speakers as the default output, and a DHCP request for wired ports that come up without an address.
#
#   sudo bash install-apple.sh --payload <this folder> --system "/Volumes/<name>" --data "/Volumes/<name> - Data"
#        [--esp <partition>] [--dry-run | --apply | --uninstall]
#
# No mode word is a dry run. Code 0 done or clean dry run, 1 refused or failed, 2 unknown option.
# A file it adds is listed in added.list under <data>/Library/NullMoth/golden-gate/apple; a file it replaces is kept
# first under .../apple/orig/<path>. --uninstall removes the added files and puts the kept ones back.
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=$HERE; SYS=""; DATA=""; MODE="--dry-run"
# test-hook-begin
KMUTIL=/usr/bin/kmutil
TAHOE_EXT=""                           # one folder holding Tahoe's AMD drivers and bundles, in place of the search
MODEL=""                               # the Mac's model, in place of reading it
GFXIDS=""                              # graphics driver bundle IDs, in place of reading what Tahoe has loaded
# test-hook-end
while [ $# -gt 0 ]; do case "$1" in
  --payload) PAYLOAD=${2:-}; shift;; --system) SYS=${2:-}; shift;; --data) DATA=${2:-}; shift;; --esp) shift;;
  --dry-run|--apply|--uninstall) MODE=$1;;
  # test-hook-begin
  --kmutil) KMUTIL=${2:-}; shift;; --tahoe-ext) TAHOE_EXT=${2:-}; shift;; --model) MODEL=${2:-}; shift;; --gfx-ids) GFXIDS=${2:-}; shift;;
  # test-hook-end
  *) echo "STOP unknown option $1"; exit 2;; esac; shift; done
say() { echo "  $*"; }
die() { echo "STOP $*"; exit 1; }

[ -n "$SYS" ] && [ -d "$SYS/System/Library" ] || die "--system must name the mounted macOS 27 system volume"
[ -n "$DATA" ] && [ -d "$DATA" ] || die "--data must name the mounted macOS 27 data volume"
STATE="$DATA/Library/NullMoth/golden-gate/apple"; ADDED="$STATE/added.list"; KEPT="$STATE/orig"
AUX="$DATA/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
BOOTKC="$SYS/System/Library/KernelCollections/BootKernelExtensions.kc"
SYSKC="$SYS/System/Library/KernelCollections/SystemKernelExtensions.kc"
KERNEL="$SYS/System/Library/Kernels/kernel"
P="$PAYLOAD/payload"; MAN="$PAYLOAD/MANIFEST"
IL=System/Library/Extensions/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib
IL_SIZE=18187216
HOOK=/usr/local/lib/nullmoth/amdil_rtfix.dylib

rel() { case "$1" in "$SYS"/*) echo "S:${1#"$SYS"}";; *) echo "D:${1#"$DATA"}";; esac; }
abs() { case "$1" in S:*) echo "$SYS${1#S:}";; D:*) echo "$DATA${1#D:}";; esac; }

if [ "$MODE" = --uninstall ]; then
  echo "STEP removing the Mac Pro package"
  [ -f "$ADDED" ] || { say "nothing was installed by this package"; exit 0; }
  while IFS= read -r r; do [ -n "$r" ] && rm -rf "$(abs "$r")"; done < "$ADDED"
  if [ -d "$KEPT" ]; then (cd "$KEPT" && find . -type f -o -type l) | while IFS= read -r f; do
    f=${f#./}; t=$(abs "${f%%/*}:/${f#*/}"); mkdir -p "${t%/*}" && mv -f "$KEPT/$f" "$t"; done; fi
  rm -rf "$STATE"; say "removed; restart to finish"; exit 0
fi

echo "STEP checking this Mac and the package"
# Golden Gate says whether the startup files are a real Mac's own (GG_EFIKIND=mac); a PC on AMD graphics is not served
# by this package. --model stands in for a test.
GIVEN=$MODEL; [ -n "$MODEL" ] || MODEL=$(sysctl -n hw.model 2>/dev/null)
# A PC (GG_EFIKIND=pc) whose Tahoe runs its built-in graphics on Apple's driver gets that driver alone: the kit's own
# PC path already covers the rest of a PC, so nothing else of its Tahoe is carried, and the Mac-only helpers stay off.
PC=0
if [ "${GG_EFIKIND:-}" = pc ]; then PC=1; say "a PC: only the graphics drivers its Tahoe runs on are carried"
elif [ "${GG_EFIKIND:-}" != mac ] && [ -z "$GIVEN" ]; then
  die "this package is for real Macs and PCs on Apple's graphics driver, and Golden Gate did not say which this is. Nothing was changed"; fi
[ $PC = 1 ] || case "$MODEL" in *Mac*|Mac-*) say "a real Mac: $MODEL";; *) die "this package is for real Macs; this machine reads as '$MODEL'. Nothing was changed";; esac
# Model class: what sits behind the keyboard, trackpad and audio (see MODELS.md), reported so a log shows it.
# The model comes from the firmware's own board data first: a boot loader may show another model name to macOS.
T2=0; SPI=0; REAL=$MODEL
if [ -z "$GIVEN" ]; then
  b=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"target-type" = <"\([^"]*\)">.*/\1/p;s/.*"board-id" = <"\([^"]*\)">.*/\1/p' | head -1)
  [ -n "$b" ] && say "board data: $b"
fi
case "$MODEL" in
  MacBookAir8,*|MacBookAir9,*|MacBookPro15,*|MacBookPro16,*|Macmini8,*|iMac20,*|iMacPro1,1|MacPro7,1) T2=1;;
  MacBook8,1|MacBook9,1|MacBook10,1|MacBookPro12,1|MacBookPro13,*|MacBookPro14,*) SPI=1;;
esac
if [ "$GIVEN" = "" ] && [ "$T2" = 0 ]; then   # a spoofed model name must not hide a T2: look for its bridge on the PCI bus
  ioreg -rxc IOPCIDevice 2>/dev/null | grep -qiE '"vendor-id" = <6b100000>' &&
    ioreg -rxc IOPCIDevice 2>/dev/null | grep -qiE '"device-id" = <(01|02|03)180000>' && T2=1
fi
# T1 and T2 Macs are not refused: their own Tahoe already runs the drivers for what sits behind the T1/T2 chip or the SPI
# bus (Apple's own on a Tahoe-supported Mac, the patcher's on an older one), and those are carried over below like every
# other driver. Said here so a report shows which class the Mac is in.
[ "$T2" = 1 ] && say "$REAL has an Apple T2 chip: its storage, keyboard, trackpad and speaker drivers come from its own Tahoe"
[ "$SPI" = 1 ] && say "$REAL has its keyboard and trackpad on an SPI bus: those drivers come from its own Tahoe"
[ -f "$MAN" ] || die "the package has no MANIFEST. Nothing was changed"
while read -r kind mode sum path; do
  case "$kind" in F) [ "$(md5 -q "$P$path" 2>/dev/null)" = "$sum" ] || die "$path does not match the package's MANIFEST. Nothing was changed";; esac
done < <(grep -v '^#' "$MAN")
say "package files match MANIFEST"
# The whole Mac, the way the PC side maps a PC: every driver this Mac's Tahoe has loaded that macOS 27's own
# collections do not carry (graphics, Wi-Fi, Bluetooth, audio, USB, Thunderbolt, sensors) is carried over and linked
# for macOS 27. Apple's copies are in /System/Library/Extensions; a root patch may have put some in /Library/Extensions.
# A kext OpenCore injected has no folder on disk and is left out (OpenCore injects it into macOS 27 as well).
DIRS=${TAHOE_EXT:-/System/Library/Extensions /Library/Extensions}
for f in "$KERNEL" "$BOOTKC" "$SYSKC"; do [ -f "$f" ] || die "the macOS 27 volume has no ${f##*/}: lay down macOS 27 and its kernel collections first"; done
if [ -z "$GFXIDS" ]; then
  in27=$("$KMUTIL" inspect -B "$BOOTKC" -S "$SYSKC" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^com\./) print $i}' | sort -u)
  GFXIDS=$(kmutil showloaded --list-only 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^com\./) print $i}' | sort -u |
    grep -vxF -f <(printf '%s\n' "$in27" com.nullmoth.NMXAudio) | grep -v '^com\.apple\.kpi\.' | tr '\n' ' ')
fi
kext_of() {   # the folder of the kext with bundle ID $1, in DIRS (top level and one plug-in level)
  local d k; for d in $DIRS; do for k in "$d"/*.kext "$d"/*.kext/Contents/PlugIns/*.kext; do [ -d "$k" ] || continue
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$k/Contents/Info.plist" 2>/dev/null)" = "$1" ] && { echo "$k"; return 0; }
  done; done; return 1; }
VENDORS=""; KEXTPATHS=""; CARRY=""
is_gfx() { case "$1" in *Graphics*|*Framebuffer*|*AMD*|*ATI*|*Radeon*|*Accelerat*|*GPU*|*Display*|*MCCS*|*nvidia*|*NVDA*|*GeForce*) return 0;; esac; return 1; }
for id in $GFXIDS; do [ $PC = 1 ] && ! is_gfx "$id" && continue
  k=$(kext_of "$id") || continue; KEXTPATHS="$KEXTPATHS $k"; CARRY="$CARRY $id"
  case "$id" in *AMD*) VENDORS="$VENDORS AMD";; *AppleIntel*Graphics*|*AppleIntel*Framebuffer*) VENDORS="$VENDORS AppleIntel";; *nvidia*|*NVDA*|*GeForce*) VENDORS="$VENDORS GeForce NVDA";; esac; done
[ -n "$CARRY" ] || die "found no driver of this machine's Tahoe to carry over. Nothing was changed"
BUNDLES=""; for d in $DIRS; do for v in $(echo $VENDORS | tr ' ' '\n' | sort -u); do for b in "$d"/$v*.bundle; do [ -d "$b" ] && BUNDLES="$BUNDLES $b"; done; done; done
say "this Mac's Tahoe: $(echo $CARRY | wc -w | tr -d ' ') drivers that macOS 27 lacks, $(echo $BUNDLES | wc -w | tr -d ' ') graphics bundles"
[ "$MODE" = --apply ] || { echo "dry run finished; nothing was changed. Run again with --apply to install."; exit 0; }

WORK=$(mktemp -d /private/var/tmp/gg-apple.XXXXXX) || die "no private work folder"
trap 'rm -rf "$WORK"' EXIT
echo "STEP linking the auxiliary kernel collection"
mkdir "$WORK/repo"
for k in $KEXTPATHS; do cp -RX "$k" "$WORK/repo/" || die "could not copy ${k##*/}"; done
cp -RX "$P/Library/Extensions/NMXAudio.kext" "$WORK/repo/" || die "could not copy NMXAudio.kext"
chown -R root:wheel "$WORK/repo"; chmod -R go-w "$WORK/repo"
IDS="com.nullmoth.NMXAudio $CARRY"
# A Tahoe driver that needs something macOS 27 does not have cannot link. kmutil names it ("Could not use 'id'"); it is
# left out, said so, and the rest are linked again. The audio driver and at least one other must remain.
for try in 1 2 3 4 5 6; do
  args=""; for id in $IDS; do args="$args -b $id"; done
  rm -f "$WORK/aux.kc"
  # shellcheck disable=SC2086
  "$KMUTIL" create -n aux -a x86_64 --allow-missing-kdk --build 26B123 -z --no-authentication --kernel "$KERNEL" \
    -B "$BOOTKC" -S "$SYSKC" --repository "$WORK/repo" -x $args -A "$WORK/aux.kc" > "$WORK/kmutil.log" 2>&1 && [ -f "$WORK/aux.kc" ] && break
  bad=$(grep -oE "Could not use '[^']+'|Unable to resolve dependencies: '[^']+'" "$WORK/kmutil.log" | sed -E "s/.*'([^']+)'/\1/" | sort -u)
  [ -n "$bad" ] || { grep -v '^$' "$WORK/kmutil.log" | tail -12; die "the drivers did not link against the macOS 27.2 collections. Nothing was changed"; }
  for b in $bad; do [ "$b" = com.nullmoth.NMXAudio ] && die "the audio driver did not link. Nothing was changed"; say "left out (does not link on macOS 27): $b"; done
  IDS=$(printf '%s\n' $IDS | grep -vxF -f <(printf '%s\n' $bad) | tr '\n' ' ')
done
[ -f "$WORK/aux.kc" ] || die "kmutil wrote no collection. Nothing was changed"
# A Mac whose graphics driver was left out above would start macOS 27 with no display. Refuse rather than place it.
printf '%s\n' $IDS | grep -qE 'Framebuffer|Graphics|AMDFramebuffer|AMD7000Controller|AMDRadeonX|NVDA|GeForce' ||
  die "none of this Mac's graphics drivers links against macOS 27.2 (left out above), so it would start with no display. Nothing was changed"
inside=$("$KMUTIL" inspect -A "$WORK/aux.kc" -B "$BOOTKC" -S "$SYSKC" 2>/dev/null)
for id in $IDS; do printf '%s\n' "$inside" | grep -qF "$id" || die "linked, but $id is not in the collection. Nothing was changed"; done
say "linked: $(stat -f %z "$WORK/aux.kc") bytes, $(echo $IDS | wc -w | tr -d ' ') extensions"

HOOKIT=0; src=""
for d in $DIRS; do [ -f "$d/$IL" ] && src="$d/$IL" && break; [ -f "$d/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib" ] && src="$d/AMDShared.bundle/Contents/PlugIns/libAMDIL902.dylib" && break; done
if [ -n "$src" ] && [ "$(stat -f %z "$src")" = "$IL_SIZE" ]; then
  echo "STEP preparing the shader compiler"
  python3 "$PAYLOAD/addlc.py" "$src" "$WORK/libAMDIL902.dylib" "$HOOK" >/dev/null || die "could not add the shader hook. Nothing was changed"
  codesign -f -s - "$WORK/libAMDIL902.dylib" >/dev/null 2>&1 || die "could not sign the patched shader compiler. Nothing was changed"
  HOOKIT=1
elif [ -n "$src" ]; then say "this Tahoe's AMD shader compiler is another build; it is copied unchanged"; fi

echo "STEP placing"
if mount | grep -F " on $SYS (" | grep -q 'read-only'; then
  /sbin/mount -uw "$SYS" 2>/dev/null
  mount | grep -F " on $SYS (" | grep -q 'read-only' && die "the macOS 27 system volume is read-only and could not be made writable"
fi
mkdir -p "$STATE" "$KEPT" || die "could not make $STATE"; touch "$ADDED"
keep() { local r k; [ -e "$1" ] || [ -L "$1" ] || return 0; r=$(rel "$1"); k="$KEPT/${r%%:*}${r#*:}"
  [ -e "$k" ] && return 0; grep -qxF "$r" "$ADDED" && return 0; mkdir -p "${k%/*}" && mv "$1" "$k" || die "could not keep $1"; }
put() {   # $1 = source (file or folder), $2 = destination, $3 = mode for a file
  keep "$2"; mkdir -p "${2%/*}" || die "could not make ${2%/*}"; rm -rf "$2.gg-new"
  if [ -d "$1" ]; then cp -RX "$1" "$2.gg-new" && chown -R root:wheel "$2.gg-new"; chmod -R go-w "$2.gg-new"
  else cp -X "$1" "$2.gg-new" && chown root:wheel "$2.gg-new"; chmod "$3" "$2.gg-new"; fi
  rm -rf "$2" && mv -f "$2.gg-new" "$2" || die "could not place $2"
  grep -qxF "$(rel "$2")" "$ADDED" || rel "$2" >> "$ADDED"; }
for b in $BUNDLES; do put "$b" "$SYS/System/Library/Extensions/${b##*/}" 755; done
if [ "$HOOKIT" = 1 ]; then put "$WORK/libAMDIL902.dylib" "$SYS/$IL" 755; put "$P$HOOK" "$DATA$HOOK" 755; fi
put "$P/Library/Extensions/NMXAudio.kext" "$DATA/Library/Extensions/NMXAudio.kext" 755
# the speaker choice and the wired-port address request are a Mac's: a PC keeps its own outputs and network setup
for f in usr/local/libexec/nullmoth/audsel usr/local/libexec/nullmoth/netup.sh; do
  [ $PC = 1 ] && continue; put "$P/$f" "$DATA/$f" 755; done
for f in "$P"/Library/LaunchDaemons/*.plist "$P"/Library/LaunchAgents/*.plist; do
  [ $PC = 1 ] && case "${f##*/}" in com.nullmoth.audsel.plist|com.nullmoth.netup.plist) continue;; esac
  put "$f" "$DATA${f#"$P"}" 644; done
put "$WORK/aux.kc" "$AUX" 644
say "installed; restart into macOS 27 to finish"
