# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# lib/os/bsd.sh -- FreeBSD/OpenBSD/NetBSD primitives.
#
# UNTESTED. Same shape as darwin.sh (no /proc on the BSDs either, so the
# ancestor walk uses ps(1)). Needs a real BSD to verify before you trust
# it; `make check` does not cover this file.
#
# Sink differs from Linux: base systems use syslogd + newsyslog, not
# rsyslog + logrotate. Install platform/*/newsyslog instead, or install
# rsyslog from ports if you want the Linux rules verbatim.

cmdscribe_origin() {
    if [ -n "$SUDO_USER" ]; then
        printf '%s' "$SUDO_USER"
        return 0
    fi
    local _cs_pid=$$ _cs_depth=0 _cs_uid _cs_ppid
    while [ -n "$_cs_pid" ] && [ "$_cs_pid" -gt 1 ] && [ "$_cs_depth" -lt 20 ]; do
        read -r _cs_uid _cs_ppid <<EOF2
$(ps -o uid= -o ppid= -p "$_cs_pid" 2>/dev/null)
EOF2
        [ -n "$_cs_uid" ] || break
        if [ "$_cs_uid" -ne 0 ] && [ "$_cs_uid" != "$(id -u)" ]; then
            id -nu "$_cs_uid" 2>/dev/null || printf 'uid=%s' "$_cs_uid"
            return 0
        fi
        [ "$_cs_ppid" = "$_cs_pid" ] && break
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
