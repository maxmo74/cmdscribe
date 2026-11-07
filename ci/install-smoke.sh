#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# End-to-end install smoke test on a real Linux host, as root.
#
# This exists because tests/pty-matrix.sh sources entry.bash directly and so
# never executes install.sh at all. The bug that made a macOS installer read
# its own version string out loud -- a helper named say() used before its
# definition, resolving to /usr/bin/say -- was invisible to the matrix. On
# Linux there is no /usr/bin/say, so that same line aborts the install under
# `set -e` on every host. Nothing in the suite at that point would have said
# so. This job does.
#
# It also asserts the two properties that make this an auditing tool rather
# than a logging example: the log is not world-readable, and removing the
# tool does not remove what it recorded.

set -eu

cd "$(dirname "$0")/.." || exit 1

LOG=/var/log/cmdscribe.log
# Markers come from the command list in tests/drive-pty.py. If that list
# changes these assertions stop matching and this job fails loudly, which is
# the desired failure mode -- the alternative is a smoke test that greps for
# something nothing ever sends and passes forever. Verified against the file
# rather than remembered: the probe is IT_PROBE, and CS_PROBE_ONE belongs to
# tests/pty-matrix.sh, which maintains its own list.
MARK=IT_PROBE
NL_MARK=IT_NL1
step() { printf '\n== %s\n' "$1"; }
die()  { printf '\nFAIL: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root (it installs into /etc)"
case $(uname -s) in
    Linux) PREFIX=/usr/share/cmdscribe ;;
    *)     die "Linux only; macOS install is covered by tests/integration.sh" ;;
esac

# rsyslog is the sink on Linux. If it is absent the log assertions below would
# have nothing to assert on, so this fails rather than quietly skipping them:
# a green run that checked nothing is worse than a red one.
command -v rsyslogd >/dev/null 2>&1 || die "rsyslogd not found; install rsyslog or this proves nothing"
command -v python3  >/dev/null 2>&1 || die "python3 required (tests/drive-pty.py)"
command -v zsh      >/dev/null 2>&1 || die "zsh not found; the zsh half would be silently untested"

step "0. starting state"
[ ! -e "$LOG" ] || die "$LOG already exists; this test needs a clean host"
[ ! -e /etc/rsyslog.d/10-cmdscribe.conf ] || die "cmdscribe rsyslog rule already present"

step "1. install"
# The single most important assertion in this file is just this: that
# install.sh exits 0 on a Linux host.
./install.sh || die "install.sh exited non-zero on Linux"

[ -f "$PREFIX/entry.bash" ] || die "missing $PREFIX/entry.bash"
[ -f "$PREFIX/entry.zsh" ]  || die "missing $PREFIX/entry.zsh"
[ -d "$PREFIX/lib/capture" ] || die "missing $PREFIX/lib/capture"
[ -f "$PREFIX/VERSION" ] || die "missing $PREFIX/VERSION"
[ -f /etc/profile.d/zz-cmdscribe.sh ] || die "bash hook not installed into /etc/profile.d"
grep -q 'entry\.zsh' /etc/zsh/zshrc 2>/dev/null \
    || grep -q 'entry\.zsh' /etc/zshrc 2>/dev/null \
    || die "zsh hook not present in any global zsh rc"
[ -f /etc/rsyslog.d/10-cmdscribe.conf ] || die "rsyslog rule not installed"
printf '   installed, version %s\n' "$(cat "$PREFIX/VERSION")"

step "2. the rsyslog config is actually valid"
# A bad rule can leave rsyslog stopped, which stops ALL system logging on the
# box, not just ours. rsyslogd -N1 is the syntax check.
rsyslogd -N1 >/tmp/rsyslog-check 2>&1 || { cat /tmp/rsyslog-check; die "rsyslogd -N1 rejected the config"; }
printf '   rsyslogd -N1 ok\n'

step "3. capture through a real login shell (bash)"
python3 tests/drive-pty.py bash system 30 /tmp/smoke-bash.log >/dev/null 2>&1 \
    || die "drive-pty.py failed for bash"
sleep 2
[ -e "$LOG" ] || die "no $LOG after a bash login shell ran commands"
if ! grep -q "$MARK" "$LOG"; then
    # Do not just fail: make the shell describe itself. Whatever is wrong, the
    # answer is in what the shell thinks PROMPT_COMMAND, HISTCONTROL and its own
    # history are, and that is only observable from inside the session. The
    # transcript lands in the job artifact.
    printf '   first command missing -- asking the shell what it can see\n'
    CS_EXTRA='echo CSDBG_PC=$PROMPT_COMMAND;echo CSDBG_HC=$HISTCONTROL;echo CSDBG_HF=$HISTFILE;echo CSDBG_N=$(HISTTIMEFORMAT= history | wc -l);HISTTIMEFORMAT= history' \
        python3 tests/drive-pty.py bash system 30 /tmp/smoke-diag.log >/dev/null 2>&1
    printf '   every record in %s (%s lines):\n' "$LOG" "$(wc -l < "$LOG")"
    cat "$LOG"
    die "probe command not recorded by bash"
fi
printf '   bash recorded: %s\n' "$(grep -m1 "$MARK" "$LOG" | sed 's/.*:: //')"

step "3b. a command typed before the first prompt is still recorded"
# Regression test for a real silent-loss defect. The hook used to discard its
# first PROMPT_COMMAND invocation to suppress the line that sourced it, which
# threw away a genuine command whenever the two coincided -- and they coincide
# when input is already buffered and bash executes it before drawing a prompt.
# This writes the command the instant the pty exists, with no wait at all.
python3 - <<'PY' || die "type-ahead probe could not run"
import os, pty, select, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-l"])
os.write(fd, b"echo IT_EARLY\n")          # no wait: worst case on purpose
end = time.time() + 8
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            if not os.read(fd, 4096):
                break
        except OSError:
            break
os.write(fd, b"exit\n")
time.sleep(0.5)
PY
sleep 2
grep -q "IT_EARLY" "$LOG" \
    || die "IT_EARLY vanished: a command typed before the first prompt was discarded"
printf '   early command recorded\n'

step "4. capture through a real login shell (zsh)"
python3 tests/drive-pty.py zsh system 30 /tmp/smoke-zsh.log >/dev/null 2>&1 \
    || die "drive-pty.py failed for zsh"
sleep 2
grep -c "$MARK" "$LOG" | awk '{if ($1 < 2) exit 1}' \
    || { die "zsh did not record its own probe (expected >=2 records total)"; }
printf '   zsh recorded, %s records total\n' "$(grep -c "$MARK" "$LOG")"

step "5. a newline in a command must not forge a second record"
# The log-injection property: `echo 'A\nB'` arrives as one command containing
# a real newline and must appear as ONE line, collapsed.
grep -q "$NL_MARK" "$LOG" || die "newline probe missing from log"
nl_lines=$(grep -c "$NL_MARK" "$LOG")
[ "$nl_lines" = 2 ] || die "newline probe produced $nl_lines records, expected 2 (bash+zsh)"
# The count above is the weak version. This is the actual property: the two
# halves must share ONE line. A record carrying IT_NL1 without IT_NL2 means
# the embedded newline split it, i.e. anyone who can type can author arbitrary
# log lines that look like independent records.
if grep "$NL_MARK" "$LOG" | grep -qv 'IT_NL2'; then
    grep "$NL_MARK" "$LOG"
    die "a record contains IT_NL1 without IT_NL2: the newline forged a second record"
fi
printf '   collapsed into one record in both shells\n'

step "6. the log is not readable by the people it records"
perms=$(stat -c '%a' "$LOG")
owner=$(stat -c '%U:%G' "$LOG")
[ "$perms" = "600" ] || die "$LOG is mode $perms, expected 0600"
[ "$owner" = "root:root" ] || die "$LOG is owned by $owner, expected root:root"
printf '   %s %s\n' "$perms" "$owner"

step "7. re-install over an existing install (idempotence)"
# Re-running install used to skip the manifest, which left hooks alive after a
# later uninstall. Both directions are checked here and in step 9.
./install.sh >/dev/null || die "re-install failed"
[ -f /etc/profile.d/zz-cmdscribe.sh ] || die "re-install removed the bash hook"
printf '   still installed, hooks intact\n'

step "8. uninstall must remove the tool and KEEP the evidence"
before=$(wc -l < "$LOG")
./uninstall.sh >/dev/null || die "uninstall.sh exited non-zero"
[ ! -e /etc/profile.d/zz-cmdscribe.sh ] || die "bash hook survived uninstall"
[ ! -e /etc/rsyslog.d/10-cmdscribe.conf ] || die "rsyslog rule survived uninstall"
[ ! -d "$PREFIX" ] || die "$PREFIX survived uninstall"
[ -e "$LOG" ] || die "uninstall DELETED THE LOG. An auditing tool must not"
after=$(wc -l < "$LOG")
[ "$after" -ge "$before" ] || die "log shrank during uninstall ($before -> $after)"
grep -q "$MARK" "$LOG" || die "records disappeared during uninstall"
printf '   tool gone, %s records still present\n' "$after"
printf '   rsyslog still parses: %s\n' \
    "$(rsyslogd -N1 >/dev/null 2>&1 && echo yes || echo NO)"

step "9. install again after uninstall"
rm -f "$LOG"   # only because step 0 requires a clean host; uninstall kept it
./install.sh >/dev/null || die "install after uninstall failed"
python3 tests/drive-pty.py bash system 30 /tmp/smoke3.log >/dev/null 2>&1
sleep 2
[ -e "$LOG" ] && grep -q "$MARK" "$LOG" || die "capture does not work after uninstall+reinstall"
printf '   capturing again\n'

step "10. uninstall leaves a machine that logs nothing of ours"
./uninstall.sh >/dev/null
before_n=$(wc -l < "$LOG")
python3 tests/drive-pty.py bash system 30 /tmp/smoke4.log >/dev/null 2>&1
sleep 2
after_n=$(wc -l < "$LOG")
[ "$before_n" = "$after_n" ] || die "a shell still emitted records after uninstall"
printf '   no records emitted, as expected\n'

printf '\ninstall-smoke: all checks passed\n'
