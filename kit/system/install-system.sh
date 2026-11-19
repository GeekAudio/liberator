#!/bin/bash
# Installs the macOS 27 system package: the interpreter for Apple silicon programs, the routes that send
# those programs to it, and the start-up scripts. Dry run unless --apply is given; --uninstall puts everything back.
# usage: install-system.sh [--system <volume> --data <volume>] [--dry-run | --apply | --uninstall]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MODE=dry; SYS=""; DATA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply|--uninstall) MODE=$1;;
    --dry-run|dry) MODE=dry;;
    --system) SYS=${2:-}; shift;;
    --data) DATA=${2:-}; shift;;
    --payload|--esp) shift;;                 # given by Golden Gate to every installer it runs; not used here
    *) echo "STOP: usage: install-system.sh [--system <volume> --data <volume>] [--dry-run | --apply | --uninstall]"; exit 1;;
  esac
  shift
done
SYS=${SYS%/}; DATA=${DATA%/}
if [ -n "$SYS" ] || [ -n "$DATA" ]; then
  [ -n "$SYS" ] && [ -n "$DATA" ] || { echo "STOP: --system and --data are given together"; exit 1; }
  [ -f "$SYS/System/Library/CoreServices/SystemVersion.plist" ] || { echo "STOP: $SYS is not a macOS system volume"; exit 1; }
  [ -d "$DATA/Library" ] || { echo "STOP: $DATA is not a macOS data volume"; exit 1; }
fi
r() { case "$1" in /Library|/usr/local|/private/var|/Users|/Library/*|/usr/local/*|/private/var/*|/Users/*) printf '%s' "$DATA$1";; *) printf '%s' "$SYS$1";; esac; }
STATE=$(r /Library/NullMoth/golden-gate)
ORIG=$STATE/orig
LOG=$STATE/install.log
PB=/usr/libexec/PlistBuddy
say() { echo "$*"; [ -d "$STATE" ] && echo "$(date '+%F %T') $*" >> "$LOG"; }
die() { say "STOP: $*"; exit 1; }
run() { if [ "$MODE" = "--apply" ]; then "$@"; else echo "  would run: $*"; fi; }
place() { local mode=$1 src=$2 dst=$3
  if [ "$MODE" != "--apply" ]; then echo "  would place: $dst"; return 0; fi
  cp "$src" "$dst.ggnew" && chown root:wheel "$dst.ggnew" && chmod "$mode" "$dst.ggnew" && mv -f "$dst.ggnew" "$dst" || { rm -f "$dst.ggnew"; die "could not place $dst"; }; }
add() { local mode=$1 src=$2 lf=$3 d p todo="" x left
  d=$(r "$lf")
  [ -f "$src" ] || die "kit has no ${src#"$HERE"/}"
  if [ -f "$d" ] && [ ! -L "$d" ] && [ "$(md5 -q "$d")" = "$(md5 -q "$src")" ] && [ "$(stat -f '%u:%g %Lp' "$d")" = "0:0 $mode" ]; then
    echo "  already in place: $lf"; return 0
  fi
  if [ "$MODE" != "--apply" ]; then echo "  would place: $d"; return 0; fi
  p=${lf%/*}
  while [ -n "$p" ] && [ ! -d "$(r "$p")" ]; do todo="$p
$todo"; p=${p%/*}; done
  while IFS= read -r x; do [ -n "$x" ] || continue
    mkdir "$(r "$x")" && chown root:wheel "$(r "$x")" && chmod 755 "$(r "$x")" && echo "$x" >> "$STATE/added-dirs.list" || die "could not make the folder $x"
  done <<EOF
$todo
EOF
  if [ -e "$d" ] || [ -L "$d" ]; then
    if [ ! -e "$ORIG$lf" ]; then mkdir -p "$(dirname "$ORIG$lf")" && cp -p "$d" "$ORIG$lf" || die "could not keep the original of $lf"; fi
  elif ! grep -Fxq -- "$lf" "$STATE/added.list" 2>/dev/null; then echo "$lf" >> "$STATE/added.list"; fi
  rm -f "$d.ggnew"
  cp -X "$src" "$d.ggnew" && chown root:wheel "$d.ggnew" && chmod "$mode" "$d.ggnew" && mv -f "$d.ggnew" "$d" || { rm -f "$d.ggnew"; die "could not place $lf"; }
  /usr/bin/xattr -c "$d" 2>/dev/null
  [ "$(md5 -q "$d")" = "$(md5 -q "$src")" ] || die "$lf does not read back as the kit's file"
  [ "$(stat -f '%u:%g %Lp' "$d")" = "0:0 $mode" ] || die "$lf reads back with owner $(stat -f '%u:%g' "$d") and mode $(stat -f '%Lp' "$d"), not root:wheel $mode; does the volume ignore ownership?"
  left=$(/usr/bin/xattr "$d" 2>/dev/null | tr '\n' ' ')
  say "placed $lf$([ -z "$left" ] || echo " (it still carries: $left)")"
}

[ "$(id -u)" = 0 ] || die "run with sudo"
if [ "$(stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then tail -c 524288 "$LOG" > "$LOG.cap" 2>/dev/null && mv -f "$LOG.cap" "$LOG"; fi
[ "$(/usr/sbin/sysctl -n hw.cputype 2>/dev/null)" = 7 ] || die "this installs on an Intel machine"
if [ -n "$SYS" ]; then BUILD=$(/usr/bin/plutil -extract ProductBuildVersion raw -o - "$SYS/System/Library/CoreServices/SystemVersion.plist" 2>/dev/null)
else BUILD=$(sw_vers -buildVersion); fi
KITBUILD=$(sed -n 's/^BuildVersion:[[:space:]]*//p' "$HERE/BUILT-ON.txt")
[ -n "$KITBUILD" ] || die "the kit has no BUILT-ON.txt"
[ "$BUILD" = "$KITBUILD" ] || die "this kit is for macOS build $KITBUILD and ${SYS:-this machine} has ${BUILD:-no readable build}; the route list would not match"

if [ "$MODE" = "--uninstall" ]; then
  [ -d "$ORIG" ] || die "nothing to uninstall: $ORIG does not exist"
  n=0
  while IFS= read -r b; do
    f=$(r "${b#"$ORIG"}")
    cp -p "$b" "$f.ggrestore" && mv -f "$f.ggrestore" "$f" && n=$((n+1))
  done < <(find "$ORIG" -type f)
  for f in /Library/LaunchDaemons/com.nullmoth.a2xarm.plist /Library/LaunchDaemons/com.nullmoth.bringup.auxload.plist \
           /Library/LaunchDaemons/com.nullmoth.keepdisplayawake.boot.plist /Library/LaunchDaemons/com.nullmoth.startreport.plist; do
    [ -f "$(r "$f")" ] && { [ -z "$SYS" ] && launchctl bootout system "$f" 2>/dev/null; rm -f "$(r "$f")"; }
  done
  rm -rf "$(r /usr/libexec/a2x)" "$(r /Library/NullMoth/bringup)" "$(r /usr/local/libexec/a2x-keepalive.sh)" "$(r /usr/local/lib/arm2x86)"
  if [ -f "$STATE/added.list" ]; then
    while IFS= read -r p; do [ -n "$p" ] || continue; [ -e "$ORIG$p" ] || rm -f "$(r "$p")"; done < "$STATE/added.list"
    rm -f "$STATE/added.list"
  fi
  if [ -f "$STATE/added-dirs.list" ]; then
    /usr/bin/tail -r "$STATE/added-dirs.list" | while IFS= read -r p; do [ -n "$p" ] && rmdir "$(r "$p")" 2>/dev/null; done
    rm -f "$STATE/added-dirs.list"
  fi
  say "restored $n programs and removed the interpreter; restart to finish"
  exit 0
fi

echo "== 1. the kit is intact"
bad=0
while read -r sum path; do
  [ -f "$HERE/$path" ] || { echo "  missing $path"; bad=$((bad+1)); continue; }
  [ "$(md5 -q "$HERE/$path")" = "$sum" ] || { echo "  changed $path"; bad=$((bad+1)); }
done < "$HERE/MD5SUMS"
[ "$bad" = 0 ] || die "$bad kit files are missing or changed"
for t in /usr/bin/codesign /usr/bin/plutil "$PB"; do [ -x "$t" ] || die "$t is missing on this system"; done
echo "  ok"

SYSMNT=${SYS:-/}
if mount | grep -F " on $SYSMNT (" | grep -q 'read-only'; then
  if [ "$MODE" = "--apply" ]; then /sbin/mount -uw "$SYSMNT" 2>/dev/null; mount | grep -F " on $SYSMNT (" | grep -q 'read-only' && die "the system volume is read-only and could not be made writable"; say "system volume remounted writable"
  else echo "  the system volume is read-only: --apply will remount it writable"; fi
fi
[ "$MODE" = "--apply" ] && { mkdir -p "$ORIG" || die "cannot create $STATE"; chmod 755 "$STATE"; }

echo "== 2. the interpreter in /usr/libexec/a2x"
SIGNED=$(mktemp /tmp/gg-host.XXXXXX)
cp "$HERE/a2x/a2xhost-mac.unsigned" "$SIGNED" || die "copy"
/usr/bin/codesign -f -s - -i .a2xhost-mac --entitlements "$HERE/a2x/a2xhost-standalone.entitlements.plist" "$SIGNED" >/dev/null 2>&1 || die "could not sign the interpreter"
/usr/bin/codesign --verify --strict "$SIGNED" || die "the signed interpreter does not verify"
run mkdir -p "$(r /usr/libexec/a2x)"
for f in a2xhost a2xhost-cat a2xpre.dylib; do place 755 "$HERE/a2x/$f" "$(r "/usr/libexec/a2x/$f")"; done
place 755 "$SIGNED" "$(r /usr/libexec/a2x/a2xhost-mac)"
place 755 "$HERE/a2x/a2xroute" "$(r /usr/libexec/a2x/a2xroute)"
place 755 "$HERE/a2x/mkroute.sh" "$(r /usr/libexec/a2x/mkroute.sh)"
place 755 "$HERE/a2x/a2xhost-mac.unsigned" "$(r /usr/libexec/a2x/a2xhost-mac.unsigned)"
place 755 "$HERE/a2x/a2xhost-cat.unsigned" "$(r /usr/libexec/a2x/a2xhost-cat.unsigned)"
run mkdir -p "$(r /usr/local/lib/arm2x86)"
place 755 "$HERE/a2x/libc++.1.0.dylib" "$(r /usr/local/lib/arm2x86/libc++.1.0.dylib)"

place 755 "$HERE/a2x/libcsfill.dylib" "$(r /usr/libexec/a2x/libcsfill.dylib)"
for cs_job in /System/Library/LaunchAgents/com.apple.corespotlightd.plist /System/Library/LaunchAgents/com.apple.managedcorespotlightd.plist; do
cs_f=$(r "$cs_job")
if [ ! -f "$cs_f" ]; then echo "  no $cs_job on this system; skipped"
elif [ "$("$PB" -c "Print :EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$cs_f" 2>/dev/null)" = /usr/libexec/a2x/libcsfill.dylib ]; then echo "  already loads the library: $cs_job"
elif "$PB" -c "Print :EnvironmentVariables:DYLD_INSERT_LIBRARIES" "$cs_f" >/dev/null 2>&1; then die "$cs_job already inserts another library; not touched"
elif [ "$MODE" != "--apply" ]; then echo "  would edit: $cs_job"
else
  cs_t=$(mktemp /tmp/gg-job.XXXXXX) && cp "$cs_f" "$cs_t" || die "copy of $cs_job"
  "$PB" -c "Print :EnvironmentVariables" "$cs_t" >/dev/null 2>&1 || "$PB" -c "Add :EnvironmentVariables dict" "$cs_t" >/dev/null || die "could not edit $cs_job"
  "$PB" -c "Add :EnvironmentVariables:DYLD_INSERT_LIBRARIES string /usr/libexec/a2x/libcsfill.dylib" "$cs_t" >/dev/null || die "could not edit $cs_job"
  /usr/bin/plutil -lint "$cs_t" >/dev/null || die "the edited $cs_job does not parse; not installed"
  cs_b="$ORIG$cs_job"; if [ ! -f "$cs_b" ]; then mkdir -p "$(dirname "$cs_b")" && cp -p "$cs_f" "$cs_b" || die "could not keep the original of $cs_job"; fi
  place 644 "$cs_t" "$cs_f"; rm -f "$cs_t"; say "edited $cs_job"
fi
done

echo "== 3. boot-time bring-up"
run mkdir -p "$(r /Library/NullMoth/bringup)" "$(r /usr/local/libexec)" "$(r /Library/LaunchDaemons)"
# Interpreter stop reports: any process adds one, nothing but root reads, replaces or deletes. Root-owned, sticky,
# write+search for everyone (1733) - never the world-writable 1777 an earlier build left behind.
run mkdir -p "$(r /private/var/tmp/a2x-reports)"
run chown root:wheel "$(r /private/var/tmp/a2x-reports)"
run chmod 1733 "$(r /private/var/tmp/a2x-reports)"
if [ "$MODE" = "--apply" ]; then
  [ "$(stat -f '%u:%g %Sp' "$(r /private/var/tmp/a2x-reports)")" = "0:0 drwx-wx-wt" ] || die "a2x-reports is not root:wheel 1733"
  for rf in "$(r /private/var/tmp/a2x-reports)"/*.log; do [ -f "$rf" ] && [ ! -L "$rf" ] && chmod 600 "$rf"; done
fi
for f in nvload.sh ws-gate.sh lw-gate.sh cryptex-place.sh start-report.sh nvgo wsready; do
  [ -f "$HERE/bringup/$f" ] || die "kit has no bringup/$f"
  place 755 "$HERE/bringup/$f" "$(r "/Library/NullMoth/bringup/$f")"
done
[ -f "$HERE/libexec/a2x-keepalive.sh" ] || die "kit has no libexec/a2x-keepalive.sh"
place 755 "$HERE/libexec/a2x-keepalive.sh" "$(r /usr/local/libexec/a2x-keepalive.sh)"
[ -f "$HERE/libexec/a2x-userapps.sh" ] || die "kit has no libexec/a2x-userapps.sh"
place 755 "$HERE/libexec/a2x-userapps.sh" "$(r /usr/local/libexec/a2x-userapps.sh)"
for p in com.nullmoth.a2xarm.plist com.nullmoth.a2xuserapps.plist com.nullmoth.bringup.auxload.plist com.nullmoth.keepdisplayawake.boot.plist com.nullmoth.startreport.plist; do
  [ -f "$HERE/daemons/$p" ] || die "kit has no $p"
  /usr/bin/plutil -lint "$HERE/daemons/$p" >/dev/null || die "$p does not parse"
  place 644 "$HERE/daemons/$p" "$(r "/Library/LaunchDaemons/$p")"
done

echo "== 3b. Apple's own macOS updates are not downloaded or installed by themselves"
# The kernel collections and the system patches of this package are made for one build ($KITBUILD). A newer macOS 27 build
# installed over it would start without them, so Apple's update is checked for but never taken without the owner asking
# (see docs/UPDATES.md). Security data and configuration data updates stay on.
[ -f "$HERE/hold/com.apple.SoftwareUpdate.plist" ] || die "kit has no hold/com.apple.SoftwareUpdate.plist"
/usr/bin/plutil -lint "$HERE/hold/com.apple.SoftwareUpdate.plist" >/dev/null || die "hold/com.apple.SoftwareUpdate.plist does not parse"
add 644 "$HERE/hold/com.apple.SoftwareUpdate.plist" /Library/Preferences/com.apple.SoftwareUpdate.plist

echo "== 3a. two files macOS 27 needs on an Intel PC and does not have"
add 644 "$HERE/driverkit/dyld_shared_cache_x86_64" /System/DriverKit/System/Library/dyld/dyld_shared_cache_x86_64
CHG="$HERE/lib/charging-init.dylib"
[ -f "$CHG" ] || die "kit has no lib/charging-init.dylib"
chgsum=$(/usr/bin/shasum -a 256 "$CHG" | awk '{print $1}')
[ ${#chgsum} = 64 ] || die "could not take the checksum of lib/charging-init.dylib"
[ "$(sed -n 's/^CHG_SHA=//p' "$HERE/libexec/a2x-keepalive.sh")" = "$chgsum" ] || die "libexec/a2x-keepalive.sh names another checksum than lib/charging-init.dylib has ($chgsum); the start-up script would not use it"
add 755 "$CHG" /usr/local/lib/nullmoth/charging-init.dylib
if [ "$MODE" = "--apply" ]; then
  d=$(r /usr/local/lib/nullmoth)
  chown root:wheel "$d" && chmod 755 "$d" && [ "$(stat -f '%u:%g %Lp' "$d")" = "0:0 755" ] || die "/usr/local/lib/nullmoth is not root:wheel 755"
fi

echo "== 3b. the window server and the login window start through the gates"
gate_job() {  # <job path> <Apple's program> <gate script> <ws|lw>
  local lf=$1 apple=$2 gate=$3 kind=$4 f t cur b
  f=$(r "$lf"); [ -f "$f" ] || die "$lf is missing on this system"
  cur=$("$PB" -c "Print :ProgramArguments:0" "$f" 2>/dev/null)
  if [ "$cur" = "$gate" ]; then echo "  already through its gate: $lf"; return 0; fi
  [ "$cur" = "$apple" ] || die "$lf starts $cur, which is neither Apple's program nor the gate; not touched"
  if [ "$MODE" != "--apply" ]; then echo "  would edit: $lf"; return 0; fi
  t=$(mktemp /tmp/gg-job.XXXXXX) && cp "$f" "$t" || die "copy of $lf"
  "$PB" -c "Set :ProgramArguments:0 $gate" "$t" >/dev/null || die "could not edit $lf"
  if [ "$kind" = ws ]; then
    for k in StandardErrorPath StandardOutPath; do
      "$PB" -c "Add :$k string /var/log/nullmoth-ws-stderr.log" "$t" >/dev/null 2>&1 || "$PB" -c "Set :$k /var/log/nullmoth-ws-stderr.log" "$t" >/dev/null || die "could not edit $lf"
    done
  else
    "$PB" -c "Set :Program $gate" "$t" >/dev/null || die "could not edit $lf"
  fi
  /usr/bin/plutil -lint "$t" >/dev/null || die "the edited $lf does not parse; not installed"
  [ "$("$PB" -c "Print :ProgramArguments:0" "$t")" = "$gate" ] || die "the edit of $lf did not take; not installed"
  b="$ORIG$lf"
  if [ ! -f "$b" ]; then mkdir -p "$(dirname "$b")" && cp -p "$f" "$b" || die "could not keep the original of $lf"; fi
  place 644 "$t" "$f"; rm -f "$t"
  say "edited $lf"
}
gate_job /System/Library/LaunchDaemons/com.apple.WindowServer.plist /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer /Library/NullMoth/bringup/ws-gate.sh ws
gate_job /System/Library/LaunchDaemons/com.apple.loginwindow.plist /System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow /Library/NullMoth/bringup/lw-gate.sh lw

want=0; have=0; made=0; skipped=0; failed=0
route_one() { local lf=$1 own_ident=${2:-} f host ident id cur new b perm own adhoc
  f=$(r "$lf"); want=$((want+1))
  [ -f "$f" ] || { skipped=$((skipped+1)); return 0; }
  case "$("$HERE/a2x/a2xroute" --platform "$f" 2>/dev/null)" in
    6) host="$HERE/a2x/a2xhost-cat.unsigned"; ident=.a2xhost-cat;;
    1) host="$HERE/a2x/a2xhost-mac.unsigned"; ident=.a2xhost-mac;;
    *) skipped=$((skipped+1)); echo "  left alone, it has no arm64 slice or declares no platform a host exists for: $f"; return 0;;
  esac
  id=$(/usr/bin/codesign -dv -a x86_64 "$f" 2>&1 | sed -n 's/^Identifier=//p')
  if [ -n "$own_ident" ]; then
    ident=$own_ident
    adhoc=$(/usr/bin/codesign -dv -a x86_64 "$f" 2>&1 | grep -c 'flags=0x[0-9a-f]*(adhoc')
    if [ "$id" = "$own_ident" ] && [ "$adhoc" = 1 ]; then id=.a2xhost-mac; else id=""; fi
  fi
  if [ "$id" = ".a2xhost-mac" ] || [ "$id" = ".a2xhost-cat" ]; then
    cur=$(/usr/bin/codesign -dvvv -a x86_64 "$f" 2>&1 | sed -n 's/^CDHash=//p')
    bash "$HERE/a2x/mkroute.sh" "$host" "$f" "$SIGNED.r" "$ident" >/dev/null 2>&1 || { failed=$((failed+1)); echo "  cannot rebuild $f"; return 0; }
    new=$(/usr/bin/codesign -dvvv -a x86_64 "$SIGNED.r" 2>&1 | sed -n 's/^CDHash=//p')
    [ -n "$cur" ] && [ "$cur" = "$new" ] && { have=$((have+1)); rm -f "$SIGNED.r"; return 0; }       # already this interpreter build
  elif [ -n "$id" ]; then
    skipped=$((skipped+1)); echo "  left alone, it has its own Intel half ($id): $f"; return 0
  else
    bash "$HERE/a2x/mkroute.sh" "$host" "$f" "$SIGNED.r" "$ident" >/dev/null 2>&1 || { failed=$((failed+1)); echo "  cannot route $f"; return 0; }
  fi
  if [ "$MODE" = "--apply" ]; then
    b="$ORIG$lf"
    if [ ! -f "$b" ]; then mkdir -p "$(dirname "$b")" && cp -p "$f" "$b" || { failed=$((failed+1)); rm -f "$SIGNED.r"; return 0; }; fi
    perm=$(stat -f '%Lp' "$f"); own=$(stat -f '%u:%g' "$f")
    cp "$SIGNED.r" "$f.ggnew" && chown "$own" "$f.ggnew" && chmod "$perm" "$f.ggnew" && mv -f "$f.ggnew" "$f" && made=$((made+1)) || failed=$((failed+1))
  else
    made=$((made+1))
  fi
  rm -f "$SIGNED.r"
}
echo "== 4. routes: Apple's arm64-only programs get the interpreter as their Intel half"
while IFS= read -r f; do route_one "$f"; done < "$HERE/a2x/routes-26B123.txt"
route_one /System/Library/CoreServices/UIKitSystem.app/Contents/MacOS/UIKitSystem
route_one /usr/libexec/xpcproxy com.apple.xpc.proxy
route_one /usr/libexec/lsd com.apple.lsd
say "routes: $want listed, $have already current, $made $([ "$MODE" = "--apply" ] && echo made || echo 'to make'), $skipped skipped, $failed failed"
[ "$failed" = 0 ] || die "$failed routes failed; nothing else was changed for them"

echo "== 4b. applications start in one exec"
want=0; have=0; made=0; skipped=0; failed=0
for app in "$SYS"/System/Applications/*.app "$SYS"/System/Applications/Utilities/*.app "$SYS"/System/Library/CoreServices/Dock.app "$SYS"/System/Library/CoreServices/Finder.app; do
  exe=$("$PB" -c "Print :CFBundleExecutable" "$app/Contents/Info.plist" 2>/dev/null); [ -n "$exe" ] || continue
  f="$app/Contents/MacOS/$exe"; [ -f "$f" ] || continue
  /usr/bin/file "$f" | /usr/bin/grep -q arm64 || continue
  route_one "${f#"$SYS"}"
done

echo "== 4c. command-line developer tools start"
swant=0; shave=0; smade=0; sfailed=0
shim_one() { local f=$1 lf=$2 id adhoc b perm own cur new
  id=$(/usr/bin/codesign -dv -a x86_64 "$f" 2>&1 | sed -n 's/^Identifier=//p')
  case "$id" in com.apple.dt.xcode_select.tool-shim-public|com.apple.dt.xcode_select.tool-shim|com.apple.xcrun) ;; *) return 0;; esac
  /usr/bin/file "$f" | /usr/bin/grep -q arm64 || return 0
  swant=$((swant+1))
  adhoc=$(/usr/bin/codesign -dv -a x86_64 "$f" 2>&1 | grep -c 'flags=0x[0-9a-f]*(adhoc')
  cp "$HERE/a2x/a2xshim" "$SIGNED.s" && /usr/bin/codesign -f -s - -i "$id" "-r=designated => identifier \"$id\"" "$SIGNED.s" >/dev/null 2>&1 \
    && "$HERE/a2x/a2xroute" "$SIGNED.s" "$f" "$SIGNED.r" >/dev/null 2>&1 || { sfailed=$((sfailed+1)); echo "  cannot make the launcher for $lf"; rm -f "$SIGNED.s" "$SIGNED.r"; return 0; }
  if [ "$adhoc" = 1 ]; then      # ours already: current when it is this same launcher
    cur=$(/usr/bin/codesign -dvvv -a x86_64 "$f" 2>&1 | sed -n 's/^CDHash=//p'); new=$(/usr/bin/codesign -dvvv -a x86_64 "$SIGNED.r" 2>&1 | sed -n 's/^CDHash=//p')
    [ -n "$cur" ] && [ "$cur" = "$new" ] && { shave=$((shave+1)); rm -f "$SIGNED.s" "$SIGNED.r"; return 0; }
  fi
  if [ "$MODE" = "--apply" ]; then
    b="$ORIG$lf"
    if [ ! -f "$b" ]; then mkdir -p "$(dirname "$b")" && cp -p "$f" "$b" || { sfailed=$((sfailed+1)); rm -f "$SIGNED.s" "$SIGNED.r"; return 0; }; fi
    perm=$(stat -f '%Lp' "$f"); own=$(stat -f '%u:%g' "$f")
    cp "$SIGNED.r" "$f.ggnew" && chown "$own" "$f.ggnew" && chmod "$perm" "$f.ggnew" && mv -f "$f.ggnew" "$f" && smade=$((smade+1)) || sfailed=$((sfailed+1))
  else smade=$((smade+1)); fi
  rm -f "$SIGNED.s" "$SIGNED.r"
}
for f in "$SYS"/usr/bin/*; do [ -f "$f" ] && [ ! -L "$f" ] && shim_one "$f" "${f#"$SYS"}"; done
say "developer-tool launchers: $swant found, $shave already current, $smade $([ "$MODE" = "--apply" ] && echo made || echo 'to make'), $sfailed failed"
[ "$sfailed" = 0 ] || die "$sfailed developer-tool launchers could not be made"
rm -f "$SIGNED" "$SIGNED.r"
say "applications: $want arm64 executables, $have already current, $made $([ "$MODE" = "--apply" ] && echo made || echo 'to make'), $skipped with their own Intel half, $failed failed"
[ "$failed" = 0 ] || die "$failed applications could not be routed"

echo "== 5. not done by this script"
echo "  the exec-hook kernel extension and the NVIDIA kernel extensions load through the boot loader (1401 builds that)"
echo "  the NVIDIA driver bundle and its settings come from the driver package"
[ "$MODE" = "--apply" ] && say "installed; restart to finish" || echo "dry run finished; nothing was changed. Run again with --apply to install."

