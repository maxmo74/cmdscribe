#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# cmdscribe installer. Idempotent. Run as root.
#
#   ./install.sh              shell layer + system log sink
#   ./install.sh --auditd     also the auditd rules (Linux)
#
# Uninstall with ./uninstall.sh, which replays the manifest written here.
#
# The manifest records one line per change, typed:
#   R <path>   file we created; uninstall deletes it
#   B <path>   file we appended to; uninstall restores <path>.cmdscribe.bak
# Using a backup copy for restores rather than sed means uninstall does
# not depend on BSD and GNU sed agreeing on -i, which they do not.

set -eu

STATE=/var/lib/cmdscribe
MANIFEST=$STATE/installed.manifest
SRC=$(cd "$(dirname "$0")" && pwd)
MARK='# cmdscribe'
WITH_AUDITD=0
[ "${1:-}" = "--auditd" ] && WITH_AUDITD=1

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

OS=$(uname -s)

# macOS keeps /usr on the sealed system volume: `mkdir /usr/share/...`
# fails with EPERM even as root. Third-party runtime data belongs under
# /usr/local, which lives on the writable data volume.
case "$OS" in
    Darwin) PREFIX=/usr/local/share/cmdscribe ;;
    *)      PREFIX=/usr/share/cmdscribe ;;
esac

say() { printf 'cmdscribe: %s\n' "$1"; }
rec() { printf '%s %s\n' "$1" "$2" >> "$MANIFEST"; }

# ---- 1. files ------------------------------------------------------ #
# The manifest is a FILE in a directory. Creating it with `mkdir -p
# "$MANIFEST"` makes a directory and every later `>>` fails.
mkdir -p "$STATE" "$PREFIX"
: > "$MANIFEST"

# Deterministic: drop the old runtime so a removed file cannot linger.
rm -rf "$PREFIX/lib" "$PREFIX/entry.bash" "$PREFIX/entry.zsh"
cp -R "$SRC/lib"      "$PREFIX/lib"
cp    "$SRC/entry.bash" "$PREFIX/entry.bash"
cp    "$SRC/entry.zsh"  "$PREFIX/entry.zsh"
chmod -R a+rX "$PREFIX"
say "installed runtime to $PREFIX"

# ---- 2. shell hooks ------------------------------------------------ #
# hook_into <file> <line> [create]
#   existing file  -> back up, append one marked line
#   missing file   -> only touched if "create" was passed (used for the
#                     profile.d drop-in, which is ours to create). Without
#                     this, an installer that only ever appends silently
#                     installs nothing on a host with no profile.d file.
hook_into() {
    _hi_f=$1; _hi_line=$2; _hi_mode=${3:-}

    if [ ! -f "$_hi_f" ]; then
        [ "$_hi_mode" = "create" ] || return 0
        printf '%s\n%s\n' "$MARK" "$_hi_line" > "$_hi_f"
        chmod 0644 "$_hi_f"
        rec R "$_hi_f"
        say "created $_hi_f"
        return 0
    fi

    if grep -qF "$MARK" "$_hi_f" 2>/dev/null; then
        say "hook already present in $_hi_f"
        return 0
    fi

    cp -p "$_hi_f" "$_hi_f.cmdscribe.bak"
    printf '\n%s\n%s\n' "$MARK" "$_hi_line" >> "$_hi_f"
    rec B "$_hi_f"
    say "hooked $_hi_f"
}

case "$OS" in
    Linux)
        if [ -d /etc/profile.d ]; then
            hook_into /etc/profile.d/zz-cmdscribe.sh \
                      ". $PREFIX/entry.bash" create
        else
            say "/etc/profile.d absent; hooking /etc/profile instead"
            hook_into /etc/profile ". $PREFIX/entry.bash"
        fi

        # Deliberately an if, not `[ -f x ] && hook && break`: as the last
        # command of the loop body that returns non-zero and set -e kills
        # the install on any host without zsh installed.
        for z in /etc/zsh/zshrc /etc/Zsh/zshrc /etc/zshrc; do
            if [ -f "$z" ]; then
                hook_into "$z" ". $PREFIX/entry.zsh"
                break
            fi
        done
        ;;
    Darwin)
        hook_into /etc/zshrc   ". $PREFIX/entry.zsh"
        hook_into /etc/bashrc  ". $PREFIX/entry.bash"
        hook_into /etc/profile ". $PREFIX/entry.bash"
        ;;
    *)
        say "unsupported OS: $OS"
        say "lib/os/bsd.sh should work on FreeBSD/OpenBSD/NetBSD -- same"
        say "ps(1)-based attribution as macOS -- but no BSD has run it."
        ;;
esac

# ---- 3. sink ------------------------------------------------------- #
case "$OS" in
    Linux)
        if [ -d /etc/rsyslog.d ]; then
            install -m 0644 -o root -g root \
                "$SRC/platform/linux/10-cmdscribe.conf" /etc/rsyslog.d/
            rec R /etc/rsyslog.d/10-cmdscribe.conf
            if command -v rsyslogd >/dev/null 2>&1; then
                # Validate with the file already in place (that is the only
                # way to test it in the context of the real config), but on
                # failure REMOVE it again. Leaving an unvalidated rule behind
                # and exiting can keep rsyslog from starting at all, which
                # takes the host's whole logging down, not just cmdscribe.
                if rsyslogd -N1 >/dev/null 2>&1; then
                    if command -v systemctl >/dev/null 2>&1; then
                        systemctl restart rsyslog && say "restarted rsyslog"
                    elif service rsyslog restart >/dev/null 2>&1; then
                        say "restarted rsyslog"
                    else
                        say "could not restart rsyslog; rule needs a manual restart"
                    fi
                else
                    rm -f /etc/rsyslog.d/10-cmdscribe.conf
                    say "ERROR: rsyslog rejected the rule; removed it, nothing restarted"
                    rsyslogd -N1 2>&1 | tail -5 | sed 's/^/    /'
                    exit 1
                fi
            else
                say "rsyslog not present; records will go wherever logger sends them"
            fi
        fi
        if [ -d /etc/logrotate.d ]; then
            install -m 0644 -o root -g root \
                "$SRC/platform/linux/cmdscribe.logrotate" \
                /etc/logrotate.d/cmdscribe
            rec R /etc/logrotate.d/cmdscribe
        fi
        ;;
    Darwin)
        say "no rsyslog on macOS; records go to the unified log via logger(1)"
        # NOT 'process == "cmdscribe"'. logger(1) drops -t on macOS, so that
        # predicate matches nothing and looks like an idle machine. The
        # marker lives in the message body instead (see lib/os/darwin.sh).
        #
        # And do NOT add --level debug to `log show`: measured on macOS
        # 27.2, `log show --level debug --predicate ...` returns ZERO rows
        # where the same command without it returns 26. `--debug` works,
        # plain works, `--level debug` does not. `log stream` accepts it
        # but does not need it.
        say "follow live with:  log stream --style compact \\"
        say "                     --predicate 'eventMessage CONTAINS \"cmdscribe: login=\"'"
        say "or after the fact: log show --last 1h \\"
        say "                     --predicate 'eventMessage CONTAINS \"cmdscribe: login=\"'"
        # platform/darwin/cmdscribe.newsyslog is deliberately NOT installed:
        # it rotates /var/log/cmdscribe.log, and on macOS nothing writes that
        # file. Shipping a rotation rule for a file that never appears is
        # how you end up believing logs are being kept when they are not.
        ;;
esac

# ---- 4. optional auditd -------------------------------------------- #
if [ "$WITH_AUDITD" = 1 ] && [ "$OS" = Linux ] && command -v augenrules >/dev/null 2>&1; then
    install -m 0640 -o root -g root \
        "$SRC/platform/linux/cmdscribe.rules" /etc/audit/rules.d/cmdscribe.rules
    rec R /etc/audit/rules.d/cmdscribe.rules
    if augenrules --load; then
        say "loaded auditd rules"
    else
        say "augenrules --load failed; rules installed but not active"
    fi
    say "check pam_loginuid or auid is worthless:"
    say "  grep -l pam_loginuid /etc/pam.d/sshd /etc/pam.d/login"
fi

say "done."
case "$OS" in
    Darwin) say "open a NEW shell, run a command, then: log stream --style compact --predicate 'eventMessage CONTAINS \"cmdscribe: login=\"'" ;;
    *)      say "open a NEW shell, run a command, then: sudo tail -f /var/log/cmdscribe.log" ;;
esac
