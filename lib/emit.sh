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
# Set by the OS layer. See lib/os/darwin.sh: on macOS logger(1) DISCARDS
# the -t tag, so the only way to make a record findable is to put the
# marker in the message body. On Linux rsyslog already writes the tag via
# %syslogtag%, so the prefix stays empty there. Either way the rendered
# line contains "cmdscribe: login=", which is the one search string that
# works on every platform.
: "${CMDSCRIBE_MSG_PREFIX:=}"

cmdscribe_emit() {
    # $1 = command text, $2 = exit status
    local _cs_cmd="$1" _cs_rc="$2" _cs_rec

    # A command typed with a literal newline would otherwise let a user
    # forge arbitrary syslog records. Collapse, do not reject.
    _cs_cmd=${_cs_cmd//$'\n'/ }
    _cs_cmd=${_cs_cmd//$'\r'/ }
    _cs_cmd=${_cs_cmd//$'\t'/ }

    [ -n "$_cs_cmd" ] || return 0
    [ "${#_cs_cmd}" -gt "$CMDSCRIBE_MAX" ] \
        && _cs_cmd="${_cs_cmd:0:$CMDSCRIBE_MAX}...[truncated]"

    _cs_rec="login=$(cmdscribe_origin) actas=$(id -un) pid=$$ ppid=$PPID tty=$(cmdscribe_tty) rc=$_cs_rc :: $_cs_cmd"

    logger -p "$CMDSCRIBE_FACILITY" -t "$CMDSCRIBE_TAG" -- \
        "${CMDSCRIBE_MSG_PREFIX}$_cs_rec"

    # Optional plain-file copy, for platforms whose logger cannot be told
    # to write one. On macOS that is not laziness: logger(1) posts to the
    # unified log and does NOT traverse syslogd's asl file routing, so no
    # /etc/asl.conf rule can produce this file. Measured -- a rule matching
    # Facility local0 captured 41 unrelated lines and none of ours.
    #
    # The tradeoff, stated because it is real: the shell appends here
    # directly, so whoever can type can also truncate this file. It is a
    # convenience copy for eyeballing, NOT the record of authority. On
    # Linux that is rsyslog's file, written by root with 0600 and outside
    # the typing user's reach; keep using that where you have it.
    if [ -n "${CMDSCRIBE_LOGFILE:-}" ]; then
        printf '%s %s %s\n' \
            "$(date '+%b %e %H:%M:%S')" "${CMDSCRIBE_HOSTNAME:-$(hostname)}" \
            "${CMDSCRIBE_MSG_PREFIX}$_cs_rec" \
            >> "$CMDSCRIBE_LOGFILE" 2>/dev/null || true
    fi
}
