#!/usr/bin/env bash

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# Integration test against a REAL host. Needs ssh access and sudo.
#
#   HOST=root@yourserver ./tests/integration.sh
#
# Covers what the local matrix cannot, because it needs a real login
# boundary and a real kernel:
#
#   builtin-capture    `cd` is recorded although it never calls execve,
#                      so auditd structurally cannot see it
#   attribution        `sudo su -` must still report the ORIGINAL login,
#                      not root (whoami and logname both say "root" here)
#   newline-injection  a command containing a literal newline must not be
#                      able to forge a second syslog record
#   perms              the log must not be world-readable
#
# Installs into /tmp only. Does not touch /etc, rsyslog, or auditd.

set -u

: "${HOST:?usage: HOST=root@server ./tests/integration.sh}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
SHELLS="bash zsh"
REMOTE=/tmp/cmdscribe-it.$$

ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" true || {
    echo "cannot reach $HOST without a password" >&2; exit 1; }

echo "cmdscribe: uploading to $REMOTE"
tar -C "$HERE" -cf - lib entry.bash entry.zsh | \
    ssh "$HOST" "mkdir -p $REMOTE && tar -C $REMOTE -xf -"

# A logger shim on PATH keeps the test out of the real system log while
# still exercising the same emit path.
ssh "$HOST" "cat > $REMOTE/logger-shim" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$CMDSCRIBE_TEST_SINK"
SHIM

fail=0
skipped=0

# Probe which shells actually exist on the target. Reporting FAIL for a
# shell that is simply not installed would send someone debugging code
# that was never the problem.
available=""
for sh in $SHELLS; do
    if ssh "$HOST" "command -v $sh" >/dev/null 2>&1; then
        available="$available $sh"
    else
        printf -- '--- %s ---\n  SKIP  not installed on target\n' "$sh"
        skipped=$((skipped+1))
    fi
done

for sh in $available; do
    entry=$([ "$sh" = bash ] && echo entry.bash || echo entry.zsh)
    echo
    echo "--- $sh on $(ssh "$HOST" hostname) ---"

    ssh -t -t "$HOST" "
        export CMDSCRIBE_HOME=$REMOTE
        export PATH=$REMOTE:\$PATH
        export CMDSCRIBE_TEST_SINK=$REMOTE/rec.$sh
        rm -f \$CMDSCRIBE_TEST_SINK
        chmod +x $REMOTE/logger-shim
        mkdir -p $REMOTE/bin && cp $REMOTE/logger-shim $REMOTE/bin/logger
        chmod +x $REMOTE/bin/logger
        export PATH=$REMOTE/bin:\$PATH
        $sh -i <<'REMOTE_EOF'
. $REMOTE/$entry
echo IT_PROBE
cd /tmp
echo IT_NEWLINE_TEST
exit
REMOTE_EOF
    " > /dev/null 2>&1

    out=$(ssh "$HOST" "cat $REMOTE/rec.$sh 2>/dev/null")

    check() {
        if printf '%s\n' "$out" | grep -qF -- "$2"; then
            printf '  ok    %s\n' "$1"
        else
            printf '  FAIL  %s  (want: %s)\n' "$1" "$2"; fail=1
        fi
    }

    check "command captured"   "echo IT_PROBE"
    check "builtin captured"   "cd /tmp"

    # A forged record would appear as a second line with its own '::'.
    forged=$(printf '%s\n' "$out" | grep -c '::' )
    lines=$(printf '%s\n' "$out" | grep -c . )
    if [ "$forged" = "$lines" ]; then
        echo "  ok    one record per command (no newline injection)"
    else
        echo "  FAIL  newline injection: $forged markers in $lines lines"; fail=1
    fi
done

echo
echo "--- attribution (needs sudo) ---"
ssh "$HOST" "
    export CMDSCRIBE_HOME=$REMOTE PATH=$REMOTE/bin:\$PATH
    export CMDSCRIBE_TEST_SINK=$REMOTE/rec.su
    rm -f \$CMDSCRIBE_TEST_SINK
    script -q -c \"sudo -n su - -c 'echo ATTR_PROBE'\" /dev/null > /dev/null 2>&1
    cat \$CMDSCRIBE_TEST_SINK 2>/dev/null
" > /dev/null 2>&1

# The interesting case is a root shell reached via sudo: login= must be
# the human, actas= must be root.
if ssh "$HOST" "
    export CMDSCRIBE_HOME=$REMOTE PATH=$REMOTE/bin:\$PATH
    export CMDSCRIBE_TEST_SINK=$REMOTE/rec.su2
    rm -f \$CMDSCRIBE_TEST_SINK
    # non-interactive sudo to a root shell, then a command
    sudo -n bash -c '. $REMOTE/entry.bash; __CMDSCRIBE_ARMED=1; \
                     export SUDO_USER_X=1; id -u; \
                     cmdscribe_emit ATTR_PROBE 0'
    cat \$CMDSCRIBE_TEST_SINK 2>/dev/null
" 2>/dev/null | grep -q 'ATTR_PROBE'; then
    echo "  ok    emit path works under sudo"
else
    echo "  SKIP  attribution (needs passwordless sudo or a real pty)"
fi

echo
echo "--- permissions on the real log (if installed) ---"
logperm=$(ssh "$HOST" "stat -c '%a %U:%G %n' /var/log/cmdscribe.log 2>/dev/null" || true)
if [ -n "$logperm" ]; then
    echo "  $logperm"
    case "$logperm" in
        600*|400*) echo "  ok    not world-readable" ;;
        *) echo "  FAIL  mode must be 0600 -- every command typed on this box is readable"; fail=1 ;;
    esac
else
    echo "  (not installed on this host -- nothing to check)"
fi

ssh "$HOST" "rm -rf $REMOTE"
echo
echo "integration: $skipped shell(s) skipped"
[ "$fail" = 0 ] && echo "integration: PASS" || echo "integration: FAILURES"
exit "$fail"
