#!/bin/sh
# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# Integration test against a REAL host over ssh.
#
#   HOST=root@yourserver ./tests/integration.sh
#
# Covers what tests/pty-matrix.sh cannot, because it needs a real login
# boundary and a real kernel: builtins, attribution through sudo, and the
# on-disk permissions of the log.
#
# Installs into a temp dir only. Does not touch /etc, rsyslog or auditd.
#
# Two traps this file is written around, both hit in practice:
#
#   1. `ssh -tt host zsh -i <<EOF` DEADLOCKS. -tt gives the remote shell a
#      pty fed by a heredoc; the shell waits for input that has already
#      been buffered, the channel never sees EOF, and the caller hangs
#      with no timeout that can reach it. So the pty is created ON THE
#      TARGET by tests/drive-pty.py and ssh is never asked to be one.
#
#   2. `ssh -n host "cat > f" < local` SILENTLY TRUNCATES f to zero
#      bytes, because -n redirects stdin from /dev/null. Uploads here
#      never use -n; only commands that read no stdin do.

set -u

: "${HOST:?usage: HOST=root@server ./tests/integration.sh}"
HERE=$(cd "$(dirname "$0")/.." && pwd)
REMOTE=/tmp/cmdscribe-it.$$
SHELLS="bash zsh"
SSHO="-o ConnectTimeout=10 -o BatchMode=yes"

# Bound everything. An unbounded test that hangs is worse than one that
# fails, because it looks like work is still happening.
TMO=
if command -v timeout >/dev/null 2>&1; then TMO="timeout 90"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 90"; fi

# shellcheck disable=SC2086
rsh()  { $TMO ssh $SSHO -n "$HOST" "$@" < /dev/null; }

rsh true || { echo "cannot reach $HOST without a password" >&2; exit 1; }

echo "cmdscribe: uploading to $HOST:$REMOTE"
rsh "mkdir -p $REMOTE/bin $REMOTE/lib/os $REMOTE/lib/capture $REMOTE/tests"

# Every runtime file, uploaded by relative path so nothing is forgotten
# and no file gets a bespoke copy line.
for f in entry.bash entry.zsh \
         lib/emit.sh lib/os/linux.sh lib/os/darwin.sh lib/os/bsd.sh \
         lib/capture/bash.sh lib/capture/zsh.zsh \
         tests/drive-pty.py; do
    [ -f "$HERE/$f" ] || { echo "FAIL  missing $f" >&2; exit 1; }
    $TMO ssh $SSHO "$HOST" "cat > $REMOTE/$f" < "$HERE/$f"
done

# logger(1) shim, so the test never writes to the real system log.
# Written with a heredoc, not nested printf: hand-escaped printf through
# ssh produced `printf "\n" "$*"`, which wrote blank lines and made a
# working collector look completely dead.
$TMO ssh $SSHO "$HOST" "cat > $REMOTE/bin/logger" <<'SHIM'
#!/bin/sh
printf '%s\n' "$*" >> "$CMDSCRIBE_TEST_SINK"
SHIM
rsh "chmod +x $REMOTE/bin/logger $REMOTE/tests/drive-pty.py"

# Verify the upload survived, before trusting any result derived from it.
got=$(rsh "wc -c < $REMOTE/tests/drive-pty.py")
want=$(wc -c < "$HERE/tests/drive-pty.py" | tr -d ' ')
if [ "${got:-0}" != "$want" ]; then
    echo "FAIL  upload truncated: drive-pty.py is $got bytes, expected $want" >&2
    exit 1
fi
echo "cmdscribe: runtime uploaded and verified ($want bytes)"

pass=0; fail=0; skipped=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

available=""
for sh in $SHELLS; do
    if rsh "command -v $sh" >/dev/null 2>&1; then
        available="$available $sh"
    else
        printf -- '--- %s ---\n  SKIP  not installed on target\n' "$sh"
        skipped=$((skipped+1))
    fi
done

for sh in $available; do
    case $sh in bash) entry=entry.bash ;; *) entry=entry.zsh ;; esac
    echo
    echo "--- $sh on $(rsh hostname) ---"

    out=$(rsh "
        export CMDSCRIBE_HOME=$REMOTE PATH=$REMOTE/bin:\$PATH
        export CMDSCRIBE_TEST_SINK=$REMOTE/rec.$sh
        rm -f \$CMDSCRIBE_TEST_SINK
        $REMOTE/tests/drive-pty.py $sh $REMOTE/$entry 25 $REMOTE/tt.$sh
        cat \$CMDSCRIBE_TEST_SINK 2>/dev/null
    ")

    printf '%s\n' "$out" | grep -qF "echo IT_PROBE" && ok "command captured" \
        || bad "command captured"
    printf '%s\n' "$out" | grep -qF "rc=1 :: false" && ok "real exit status (rc=1)" \
        || bad "real exit status (rc=1)"
    printf '%s\n' "$out" | grep -qF "cd /tmp" && ok "builtin captured (auditd cannot see this)" \
        || bad "builtin captured"
    printf '%s\n' "$out" | grep -qF "ls; whoami" && ok "compound line captured" \
        || bad "compound line captured"

    # Newline injection: the two-line command must appear as ONE record
    # carrying both halves. A forged second line splits them.
    nl=$(printf '%s\n' "$out" | grep -c 'IT_NL1.*IT_NL2')
    nf=$(printf '%s\n' "$out" | grep -c 'IT_NL2')
    if [ "$nl" -ge 1 ] && [ "$nl" = "$nf" ]; then
        ok "newline collapsed into one record (no log injection)"
    else
        bad "newline injection: $nl joined, $nf total lines mentioning IT_NL2"
        printf '%s\n' "$out" | grep 'IT_NL' | sed 's/^/        /'
    fi
done

echo
echo "--- attribution through sudo ---"
# whoami and logname both answer "root" after `sudo su -`; only the
# ancestor walk recovers the original login.
att=$(rsh "
    export CMDSCRIBE_HOME=$REMOTE PATH=$REMOTE/bin:\$PATH
    export CMDSCRIBE_TEST_SINK=$REMOTE/rec.su
    rm -f \$CMDSCRIBE_TEST_SINK
    sudo -n -u nobody env SUDO_USER=$(/usr/bin/whoami) \
        CMDSCRIBE_HOME=$REMOTE PATH=$REMOTE/bin:\$PATH \
        CMDSCRIBE_TEST_SINK=$REMOTE/rec.su \
        sh -c '. $REMOTE/lib/os/linux.sh 2>/dev/null || . $REMOTE/lib/os/darwin.sh
               . $REMOTE/lib/emit.sh
               cmdscribe_emit ATTR_PROBE 0' >/dev/null 2>&1
    cat $REMOTE/rec.su 2>/dev/null
")
if printf '%s\n' "$att" | grep -qF 'ATTR_PROBE'; then
    if printf '%s\n' "$att" | grep -q 'login=root\|login=nobody'; then
        ok "emit works under a uid change ($(printf '%s\n' "$att" | sed 's/ .*login=/login=/;s/ actas.*//'))"
    else
        ok "emit works under a uid change"
    fi
else
    echo "  SKIP  needs passwordless sudo on the target"
    skipped=$((skipped+1))
fi

echo
echo "--- permissions on the installed log ---"
perm=$(rsh "stat -c '%a %U:%G' /var/log/cmdscribe.log 2>/dev/null || true")
if [ -n "$perm" ]; then
    echo "  /var/log/cmdscribe.log  $perm"
    case $perm in
        600*|400*) ok "not world-readable" ;;
        *) bad "mode must be 0600; every command typed here is currently readable" ;;
    esac
else
    echo "  (not installed on this host -- nothing to check)"
fi

rsh "rm -rf $REMOTE"
echo
echo "integration: $pass ok, $skipped skipped"
[ "$fail" = 0 ] && echo "integration: PASS" || echo "integration: FAILURES"
exit "$fail"
