#!/usr/bin/env bash

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# Acceptance matrix. Drives a REAL pty so PROMPT_COMMAND / preexec
# actually fire, then asserts on the records produced.
#
# Every assertion here corresponds to a bug that was actually observed
# while developing this, which is why they are not negotiable:
#
#   history-number-leak   BSD sed silently ignores GNU '\+'; and a naive
#                         ${var#*[0-9]} strips only to the FIRST digit
#   timestamp-splice      HISTTIMEFORMAT injected a timestamp mid-record
#   wrong-exit-status     HISTIGNORE made history(1) re-report the
#                         PREVIOUS command, carrying the wrong $?
#   sourcing-artifact     sourcing the hook logged one of its own comment
#                         lines as if it were a typed command
#   attribution-loss      whoami AND logname both report "root" after
#                         `sudo su -` (see lib/os/linux.sh)
#   log-injection         a literal newline in a command forged new
#                         syslog records

set -u

HERE=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

SINK="$WORK/records"
: > "$SINK"

# Shim logger(1) so tests never touch the system log.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/logger" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$CMDSCRIBE_TEST_SINK"
SHIM
chmod +x "$WORK/bin/logger"

export PATH="$WORK/bin:$PATH"
export CMDSCRIBE_TEST_SINK="$SINK"
export CMDSCRIBE_HOME="$HERE"

pass=0; fail=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

has()     { grep -qF  -- "$1" "$SINK" 2>/dev/null; }
hasnt()   { ! grep -qF  -- "$1" "$SINK" 2>/dev/null; }
has_re()  { grep -qE     "$1" "$SINK" 2>/dev/null; }

assert()      { if has "$2";    then ok   "$1"; else bad "$1  (want: $2)"; fi; }
refute()      { if hasnt "$2";  then ok   "$1"; else bad "$1  (forbidden: $2)"; fi; }
assert_re()   { if has_re "$2"; then ok   "$1"; else bad "$1  (want /re/: $2)"; fi; }
refute_re()   { if ! has_re "$2"; then ok "$1"; else bad "$1  (forbidden /re/: $2)"; fi; }

drive() { # <shell> <entry>
    local shell="$1" entry="$2"
    : > "$SINK"
    printf -- '--- %s ---\n' "$shell"

    python3 - "$shell" "$entry" "$WORK" <<'PY'
import os, pty, select, sys, time

shell, entry, work = sys.argv[1], sys.argv[2], sys.argv[3]

# zsh reads $ZDOTDIR/.zshrc; give it a clean one so the developer's own
# zshrc cannot mask a failure.
zdot = os.path.join(work, "zdot")
os.makedirs(zdot, exist_ok=True)
with open(os.path.join(zdot, ".zshrc"), "w") as fh:
    fh.write(". %s\n" % entry)

cmds = [". %s\n" % entry,
        "echo CS_PROBE_ONE\n",
        "false\n",
        "cd /tmp\n",
        "ls; whoami\n",
        "exit\n"]

pid, fd = pty.fork()
if pid == 0:
    if "zsh" in shell:
        os.environ["ZDOTDIR"] = zdot
        os.execvp(shell, [shell, "-d"])       # -d skips .zshenv only
    else:
        os.execvp(shell, [shell, "--norc", "-i"])

def drain(t=0.8):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                if not os.read(fd, 4096):
                    break
            except OSError:
                break

drain(0.5)
for c in cmds:
    os.write(fd, c.encode())
    drain(0.8)
os.waitpid(pid, 0)
PY

    assert "command text captured"        "echo CS_PROBE_ONE"
    assert "compound line captured"       "ls; whoami"
    assert_re "real exit status recorded"  "rc=1 :: false"
    refute_re "history number stripped"    "::[[:space:]]+[0-9]+[[:space:]]"
    refute_re "no sourcing artifact"       "::[[:space:]]*#"
    refute_re "no timestamp splice"        "::[[:space:]]*\\[20[0-9][0-9]-[0-9][0-9]-"
}

printf 'cmdscribe acceptance matrix\n'
printf '(builtin capture, log-injection and sudo/su attribution are\n'
printf ' covered by tests/integration.sh, which needs a target host)\n\n'

command -v bash >/dev/null && drive bash "$HERE/entry.bash"
echo
command -v zsh  >/dev/null && drive zsh  "$HERE/entry.zsh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
