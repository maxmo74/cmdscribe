#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# cmdscribe installer. Idempotent. Run as root.
#
#   ./install.sh              shell layer only
#   ./install.sh --auditd     also install the auditd rules (Linux)
#
# Uninstall with ./uninstall.sh (uses the manifest written here).

set -eu

PREFIX=/usr/share/cmdscribe
MANIFEST=/var/lib/cmdscribe/installed.manifest
SRC=$(cd "$(dirname "$0")" && pwd)
MARK='# cmdscribe'
WITH_AUDITD=0
[ "${1:-}" = "--auditd" ] && WITH_AUDITD=1

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

OS=$(uname -s)
say() { printf 'cmdscribe: %s\n' "$1"; }

# ---- 1. files ------------------------------------------------------ #
mkdir -p "$PREFIX" "$MANIFEST" 2>/dev/null || mkdir -p "$(dirname "$MANIFEST")"
cp -R "$SRC/lib" "$SRC/entry.bash" "$SRC/entry.zsh" "$PREFIX/"
say "installed runtime to $PREFIX"

# ---- 2. shell hooks ------------------------------------------------ #
# Idempotent append guarded by a marker, so repeated runs and
# distribution updates of these files do not stack duplicates.
hook_into() {
    f=$1; line=$2
    [ -f "$f" ] || return 0
    if grep -qF "$MARK" "$f" 2>/dev/null; then
        say "hook already present in $f"
        return 0
    fi
    cp -p "$f" "$f.cmdscribe.bak"
    printf '\n%s\n%s\n' "$MARK" "$line" >> "$f"
    printf '%s\n' "$f" >> "$MANIFEST"
    say "hooked $f"
}

case "$OS" in
    Linux)
        [ -d /etc/profile.d ] \
            && hook_into /etc/profile.d/zz-cmdscribe.sh \
               '. '"$PREFIX"'/entry.bash'
        for z in /etc/zsh/zshrc /etc/Zsh/zshrc /etc/zshrc; do
            [ -f "$z" ] && hook_into "$z" '. '"$PREFIX"'/entry.zsh' && break
        done
        ;;
    Darwin)
        hook_into /etc/zshrc   '. '"$PREFIX"'/entry.zsh'
        hook_into /etc/bashrc  '. '"$PREFIX"'/entry.bash'
        hook_into /etc/profile '. '"$PREFIX"'/entry.bash'
        ;;
    *)
        say "unsupported OS: $OS (see lib/os/bsd.sh -- untested)"
        ;;
esac

# ---- 3. sink ------------------------------------------------------- #
case "$OS" in
    Linux)
        if [ -d /etc/rsyslog.d ]; then
            install -m 0644 -o root -g root \
                "$SRC/platform/linux/10-cmdscribe.conf" /etc/rsyslog.d/
            printf '%s\n' /etc/rsyslog.d/10-cmdscribe.conf >> "$MANIFEST"
            say "installed rsyslog rule"
            if command -v rsyslogd >/dev/null 2>&1; then
                rsyslogd -N1 >/dev/null || {
                    say "WARNING: rsyslog config does not validate; not restarting"
                    exit 1; }
                (command -v systemctl >/dev/null \
                    && systemctl restart rsyslog) \
                  || service rsyslog restart
                say "restarted rsyslog"
            fi
        fi
        [ -d /etc/logrotate.d ] \
            && install -m 0644 -o root -g root \
                 "$SRC/platform/linux/cmdscribe.logrotate" \
                 /etc/logrotate.d/cmdscribe \
            && printf '%s\n' /etc/logrotate.d/cmdscribe >> "$MANIFEST"
        ;;
    Darwin)
        say "no rsyslog on macOS; records go to the unified log via logger(1)"
        say "read them with:  log show --predicate 'process == \"cmdscribe\"' --last 1h"
        ;;
esac

# ---- 4. optional auditd -------------------------------------------- #
if [ "$WITH_AUDITD" = 1 ] && [ "$OS" = Linux ] && command -v augenrules >/dev/null 2>&1; then
    install -m 0640 -o root -g root \
        "$SRC/platform/linux/cmdscribe.rules" /etc/audit/rules.d/cmdscribe.rules
    printf '%s\n' /etc/audit/rules.d/cmdscribe.rules >> "$MANIFEST"
    augenrules --load
    say "loaded auditd rules"
    say "NOTE: verify pam_loginuid is enabled or auid is useless:"
    say "      grep -l pam_loginuid /etc/pam.d/sshd /etc/pam.d/login"
fi

say "done. Open a NEW shell, then: tail -f /var/log/cmdscribe.log"
