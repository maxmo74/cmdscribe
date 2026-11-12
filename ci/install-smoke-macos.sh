#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# End-to-end install smoke test on macOS, as root.
#
# ci/install-smoke.sh is Linux-only and says so. The acceptance matrix on
# macos-latest sources entry.bash/entry.zsh directly and therefore never runs
# install.sh -- which is exactly how a version of the macOS installer that read
# its own version string out loud (a helper named say(), resolving to
# /usr/bin/say) reached a release. macOS is the only platform with /usr/bin/say,
# so macOS was the only place that bug was audible, and macOS was the one place
# the installer was never executed.
#
# What this asserts that the matrix cannot:
#   - the runtime lands in /usr/local/share, not /usr/share. /usr is on the
#     SIP-sealed read-only system volume, so the latter fails with EPERM *as
#     root*. An installer that hardcodes /usr/share works perfectly on every
#     Linux CI runner and fails on every Mac.
#   - the hooks land in the three rc files macOS actually uses.
#   - records reach the unified log, found with the exact query the README
#     documents. If that query ever stops matching reality, this job goes red
#     instead of a reader concluding their box is idle.
#   - uninstall restores those rc files byte-identically, verified against
#     backups this script took itself rather than against the ones install.sh
#     made, so the test cannot simply agree with the installer's mistakes.
#   - the log survives the uninstall.

set -eu

cd "$(dirname "$0")/.." || exit 1

PREFIX=/usr/local/share/cmdscribe
LOG=/var/log/cmdscribe.log
MARK=IT_PROBE
RCS="/etc/zshrc /etc/bashrc /etc/profile"
PRED='eventMessage CONTAINS "cmdscribe: login="'
# The README warns that `--level debug` returns zero rows where the plain form
# returns results. Deliberately NOT asserted here: that is macOS behaviour, not
# cmdscribe behaviour, and it was measured on one version. Asserting it would
# make this job depend on an OS detail that can change without anything of
# ours breaking. The correct form below is what gets enforced.

step() { printf '\n== %s\n' "$1"; }
die()  { printf '\nFAIL: %s\n' "$1" >&2; exit 1; }

count_unified() {
    # $1 = marker. The plain form, exactly as documented in the README.
    log show --last 5m --style compact --predicate "$PRED" 2>/dev/null \
        | grep -c "$1" || true
}

wait_unified() {
    # The unified log is asynchronous; a record is not queryable the instant it
    # is posted. Poll rather than sleep once, and fail with the count we did
    # get -- "0 records" and "query matched nothing" need distinguishing.
    i=1
    while [ "$i" -le 5 ]; do
        n=$(count_unified "$1")
        if [ "$n" -gt 0 ]; then
            printf '   %s record(s) matching "%s" in the unified log\n' "$n" "$1"
            return 0
        fi
        sleep 15
        i=$((i + 1))
    done
    return 1
}

[ "$(id -u)" = 0 ] || die "must run as root (it installs into /etc and /usr/local)"
[ "$(uname -s)" = "Darwin" ] || die "macOS only"
command -v python3 >/dev/null 2>&1 || die "python3 required (tests/drive-pty.py)"
command -v zsh     >/dev/null 2>&1 || die "zsh not found; the zsh half would be silently untested"

step "0. starting state"
[ ! -d "$PREFIX" ] || die "$PREFIX already exists; this test needs a clean host"
[ ! -e "$LOG" ]    || die "$LOG already exists; this test needs a clean host"
for f in $RCS; do
    cp "$f" "/tmp/pre-$(basename "$f")" || die "cannot back up $f"
    if grep -q cmdscribe "$f" 2>/dev/null; then
        die "$f already mentions cmdscribe; not a clean host"
    fi
done

step "1. install"
# The single most important assertion in this file: install.sh exits 0 on macOS.
./install.sh || die "install.sh exited non-zero on macOS"

step "2. the runtime is where macOS requires it"
[ -f "$PREFIX/entry.bash" ] || die "missing $PREFIX/entry.bash"
[ -f "$PREFIX/entry.zsh" ]  || die "missing $PREFIX/entry.zsh"
if [ -d /usr/share/cmdscribe ]; then
    die "/usr/share/cmdscribe exists; /usr is read-only on macOS (SIP) and this \
path is the one that fails with EPERM as root"
fi
installed=$(cat "$PREFIX/VERSION" 2>/dev/null || echo none)
want=$(cat VERSION)
[ "$installed" = "$want" ] || die "installed VERSION is $installed, repo says $want"
printf '   %s (VERSION %s); /usr/share/cmdscribe correctly absent\n' "$PREFIX" "$installed"

step "3. hooks landed, exactly once each"
for f in $RCS; do
    n=$(grep -c 'cmdscribe/entry\.' "$f" 2>/dev/null || true)
    [ "$n" = "1" ] || die "$f has $n cmdscribe hook line(s), expected exactly 1"
done
printf '   one hook line in each of: %s\n' "$RCS"

step "4. capture reaches the unified log (bash, then zsh)"
# Warm-up session first. ci/install-smoke.sh found that the first record into a
# freshly created log file can be dropped; that is a Linux/rsyslog finding, but
# paying the same cost here keeps the probe measuring the steady state.
env -i PATH="$PATH" HOME="$HOME" TERM=xterm \
    python3 tests/drive-pty.py bash system 30 /tmp/smoke-mac-warm.log >/dev/null 2>&1 || true

for sh in bash zsh; do
    env -i PATH="$PATH" HOME="$HOME" TERM=xterm \
        python3 tests/drive-pty.py "$sh" system 30 "/tmp/smoke-mac-$sh.log" >/dev/null 2>&1 \
        || die "drive-pty.py failed for $sh (transcript: /tmp/smoke-mac-$sh.log)"
    wait_unified "$MARK" || die "no unified-log record matching $MARK after a $sh login shell.\
 Either capture is broken or the README's documented predicate no longer matches."
done

step "5. --logfile writes a file, at the mode install.sh promises"
./install.sh --logfile || die "install.sh --logfile exited non-zero"
[ -e "$LOG" ] || die "--logfile did not create $LOG"
perms=$(stat -f "%Lp %Su %Sg" "$LOG")
[ "$perms" = "660 root admin" ] || die "$LOG is '$perms', expected '660 root admin'"

env -i PATH="$PATH" HOME="$HOME" TERM=xterm \
    python3 tests/drive-pty.py bash system 30 /tmp/smoke-mac-file.log >/dev/null 2>&1 \
    || die "drive-pty.py failed"
sleep 2
grep -q "$MARK" "$LOG" || die "$MARK absent from $LOG; the shell is not appending to it"
printf '   %s has the marker at %s\n' "$LOG" "$perms"

step "6. re-install is idempotent"
./install.sh >/dev/null || die "second install exited non-zero"
for f in $RCS; do
    n=$(grep -c 'cmdscribe/entry\.' "$f")
    [ "$n" = "1" ] || die "$f has $n hook lines after re-install; expected 1 (hooks are stacking)"
done
printf '   still exactly one hook line per file after a second install\n'

step "7. uninstall removes the software and keeps the record"
./uninstall.sh || die "uninstall.sh exited non-zero"

for f in $RCS; do
    if grep -q cmdscribe "$f" 2>/dev/null; then
        die "$f still mentions cmdscribe after uninstall"
    fi
    cmp -s "$f" "/tmp/pre-$(basename "$f")" \
        || die "$f was not restored byte-identically by uninstall"
done
[ ! -d "$PREFIX" ] || die "$PREFIX still present after uninstall"
[ -e "$LOG" ] || die "$LOG was deleted by uninstall; an uninstall that removes the\
 audit trail lets anyone erase their own history"
grep -q "$MARK" "$LOG" || die "$LOG survived but lost its records"
printf '   rc files byte-identical to the backups this script took, runtime gone,\
 log kept\n'

step "8. after uninstall a new shell records nothing"
./install.sh --logfile >/dev/null 2>&1 || die "re-install failed"
before=$(wc -l < "$LOG")
./uninstall.sh >/dev/null || die "second uninstall failed"
env -i PATH="$PATH" HOME="$HOME" TERM=xterm \
    python3 tests/drive-pty.py bash system 30 /tmp/smoke-mac-after.log >/dev/null 2>&1 || true
sleep 2
after=$(wc -l < "$LOG")
[ "$before" = "$after" ] || die "log grew from $before to $after lines after uninstall"
printf '   log still at %s line(s) after a post-uninstall session\n' "$after"

printf '\nok\n'
