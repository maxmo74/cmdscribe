# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# lib/os/linux.sh -- Linux primitives.
#
# Selected by install.sh on Linux only. Everything here may use
# Linux-specific facilities (/proc, GNU coreutils).

# Empty on purpose: rsyslog already writes the tag into the line via
# %syslogtag%, so the rendered record contains "cmdscribe: login=" with no
# help from us. Adding a prefix here would double it.
CMDSCRIBE_MSG_PREFIX=""

# Best-effort recovery of who ORIGINALLY logged in, even across
# `sudo su -`. Preference order:
#   1. $SUDO_USER  -- set by sudo, but LOST across `su -`
#   2. nearest non-root ancestor process with a real uid
#   3. ourselves     -- covers a genuine direct root login
#
# Verified on Debian 13: `massimo -> sudo su -` yields login=massimo.
# Note that `logname` is NOT usable here: with sudo's `use_pty` option a
# fresh pts is allocated and `su -` writes a new utmp entry owned by
# root, so logname returns "root".
cmdscribe_origin() {
    if [ -n "$SUDO_USER" ]; then
        printf '%s' "$SUDO_USER"
        return 0
    fi

    local _cs_pid=$$ _cs_depth=0 _cs_uid _cs_ppid _cs_k _cs_v
    while [ -n "$_cs_pid" ] && [ "$_cs_pid" -gt 0 ] && [ "$_cs_depth" -lt 20 ]; do
        [ -r "/proc/$_cs_pid/status" ] || break
        _cs_uid=""; _cs_ppid=""
        while read -r _cs_k _cs_v _; do
            case "$_cs_k" in
                Uid:)  _cs_uid="$_cs_v" ;;
                PPid:) _cs_ppid="$_cs_v" ;;
            esac
        done < "/proc/$_cs_pid/status"
        [ -n "$_cs_uid" ] || break
        if [ "$_cs_uid" -ne 0 ] && [ "$_cs_uid" != "$(id -u)" ]; then
            id -nu "$_cs_uid" 2>/dev/null || printf 'uid=%s' "$_cs_uid"
            return 0
        fi
        _cs_pid="$_cs_ppid"
        _cs_depth=$((_cs_depth + 1))
    done

    id -un
}

cmdscribe_tty() {
    local _cs_t
    _cs_t=$(tty 2>/dev/null)
    _cs_t=${_cs_t#/dev/}
    printf '%s' "${_cs_t:-notty}"
}
