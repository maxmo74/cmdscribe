# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# lib/os/darwin.sh -- macOS primitives.
#
# macOS has NO /proc, so the ancestor walk uses ps(1). Verified on
# macOS 27.2 / bash 3.2 and zsh 5.9.
#
# NOT YET IMPLEMENTED on this platform: kernel-level corroboration.
# Apple's EndpointSecurity API requires com.apple.developer.endpoint-
# security.client, granted only to approved organisations; without it
# there is no tamper-resistant second layer, so cmdscribe-reconcile
# degrades to the single shell layer and says so.

# logger(1) on macOS silently DROPS the -t tag: the record is filed under
# process=/usr/bin/logger and the tag appears nowhere in it. Verified on
# macOS 27.2 -- `log show --predicate 'process == "cmdscribe"'` returns
# nothing at all, which reads as "no commands were run" rather than "your
# query is wrong". Carrying the marker in the message body is the fix.
CMDSCRIBE_MSG_PREFIX="cmdscribe: "

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
