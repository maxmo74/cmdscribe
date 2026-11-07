# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# lib/emit.sh -- record formatting. Shell-agnostic and OS-agnostic.
#
# Depends on two functions supplied by the OS layer (lib/os/<os>.sh):
#   cmdscribe_origin   -> who originally logged in
#   cmdscribe_tty      -> controlling terminal, short form
#
# This file must stay valid in BOTH bash (incl. 3.2 on macOS) and zsh.

: "${CMDSCRIBE_FACILITY:=local0.notice}"
: "${CMDSCRIBE_TAG:=cmdscribe}"
: "${CMDSCRIBE_MAX:=4000}"

cmdscribe_emit() {
    # $1 = command text, $2 = exit status
    local _cs_cmd="$1" _cs_rc="$2"

    # A command typed with a literal newline would otherwise let a user
    # forge arbitrary syslog records. Collapse, do not reject.
    _cs_cmd=${_cs_cmd//$'\n'/ }
    _cs_cmd=${_cs_cmd//$'\r'/ }
    _cs_cmd=${_cs_cmd//$'\t'/ }

    [ -n "$_cs_cmd" ] || return 0
    [ "${#_cs_cmd}" -gt "$CMDSCRIBE_MAX" ] \
        && _cs_cmd="${_cs_cmd:0:$CMDSCRIBE_MAX}...[truncated]"

    logger -p "$CMDSCRIBE_FACILITY" -t "$CMDSCRIBE_TAG" -- \
        "login=$(cmdscribe_origin) actas=$(id -un) pid=$$ ppid=$PPID tty=$(cmdscribe_tty) rc=$_cs_rc :: $_cs_cmd"
}
