#!/usr/bin/env python3
"""Stock-27 mode for a2x-keepalive.sh: when the kernel armed the hook itself (a2x.exec_hook_bootarm_result = 0), Apple's
own arm64-only programs depend on it for the whole uptime, including shutdown. Disarming then breaks the machine, so the
exec-storm guard only logs and the dead-man window is an hour. Anchored edits, counts asserted."""
import sys
p = sys.argv[1]; s = open(p).read()
def sub(old, new):
    global s
    assert s.count(old) == 1, f"anchor count {s.count(old)}: {old[:50]!r}"
    s = s.replace(old, new)
sub('DEADMAN=120\n', '''DEADMAN=120
# Stock 27: the kernel armed the hook at boot (a2xbootarm=1), so Apple's arm64-only files need it until power-off.
STOCK=0; [ "$(sysctl -n a2x.exec_hook_bootarm_result 2>/dev/null)" = "0" ] && STOCK=1
[ "$STOCK" = 1 ] && DEADMAN=3600
''')
sub('''    if [ "$rate" -gt "$MAX_PER_MIN" ]; then''', '''    # stock 27: a busy minute is the system's own programs, never a reason to disarm
    if [ "$STOCK" = 1 ] && [ "$rate" -gt "$MAX_PER_MIN" ]; then
        say "busy: ${rate} execs/min (stock 27, not disarming) claimed=$now"
    elif [ "$rate" -gt "$MAX_PER_MIN" ]; then''')
open(p, 'w').write(s); print("patched", p)
