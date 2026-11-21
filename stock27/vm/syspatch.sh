#!/bin/bash
# syspatch.sh save|wipe|apply  (VM disk, offline via vmedit; /tmp/sv = System, /tmp/dv = Data)
#   save  : copy every file we add to Apple's system volume (sys_added.txt) into Data/Library/NullMoth/syspatch
#   wipe  : delete them from the system volume - what an Apple update does
#   apply : put them back from the payload - what Liberator does after an update
set -u
L=$HOME/vm-amd27/sys_added.txt; P=/tmp/dv/Library/NullMoth/syspatch; n=0; bad=0
case "$1" in
save)  sudo -n mkdir -p "$P"; while IFS= read -r f; do sudo -n ditto "/tmp/sv$f" "$P$f" && n=$((n+1)) || { bad=$((bad+1)); echo "save FAILED $f"; }; done < "$L";;
wipe)  while IFS= read -r f; do sudo -n rm -f "/tmp/sv$f" && n=$((n+1)) || bad=$((bad+1)); done < "$L";;
apply) while IFS= read -r f; do sudo -n ditto "$P$f" "/tmp/sv$f" && n=$((n+1)) || { bad=$((bad+1)); echo "apply FAILED $f"; }; done < "$L";;
esac
echo "syspatch $1: $n ok, $bad failed"
