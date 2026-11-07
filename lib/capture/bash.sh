# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# lib/capture/bash.sh -- bash capture hook. OS-agnostic.
#
# Sourced by the per-OS loader. Requires lib/emit.sh and one lib/os/*.sh
# to have been sourced first.
#
# Verified on: Debian 13 / bash 5.2 (real pty, real sudo/su),
#              macOS 27.2 / bash 3.2 (syntax + BSD sed).

[ -n "$BASH_VERSION" ] || return 0

# ------------------------------------------------------------------ #
# Why this looks convoluted. Each clause defuses a measured failure.
#
#  * PROMPT_COMMAND runs AFTER the command, so $? is its real status.
#  * history(1) is the only way to get the typed line in bash -- which
#    means HISTIGNORE and HISTCONTROL=ignoredups actively corrupt the
#    record (excluded commands never enter history, so history(1)
#    re-reports the PREVIOUS command with the WRONG exit status).
#    We therefore refuse to inherit HISTIGNORE.
#  * HISTTIMEFORMAT must be empty or bash splices a timestamp in front
#    of the command text.
#  * sed needs -E: BSD sed silently ignores GNU '\+' and would leave the
#    history number in every record.
#  * Sourcing this file from an interactive login shell pushes its own
#    lines into history, so the first prompt reports a line of this
#    file rather than a typed command. Exactly one invocation is dropped.
# ------------------------------------------------------------------ #

__cmdscribe_bash_run() {
    local _cs_rc=$? _cs_line _cs_cmd

    if [ -z "$__CMDSCRIBE_ARMED" ]; then
        __CMDSCRIBE_ARMED=1
        return 0
    fi

    # SC1007: the space after `=` is deliberate. HISTTIMEFORMAT must be
    # empty for this one `history` call; `HISTTIMEFORMAT=history 1` would
    # instead assign the string "history". `history` is a plain builtin so
    # bash scopes the assignment to the call anyway, and the command
    # substitution is a subshell, so it cannot leak even where it would.
    # shellcheck disable=SC1007
    _cs_line=$(HISTTIMEFORMAT= history 1 2>/dev/null)
    _cs_cmd=$(printf '%s\n' "$_cs_line" \
              | sed -E -e 's/^[[:space:]]*[0-9]+[[:space:]]*//')

    cmdscribe_emit "$_cs_cmd" "$_cs_rc"
}

__cmdscribe_bash_install() {
    # interactive shells only
    case $- in *i*) ;; *) return 0 ;; esac

    # Skip accounts that legitimately spam a shell. EXACT match on
    # purpose: a glob such as *backup* also silences backupadmin and
    # nightly_backups. Override with a space-separated list, e.g.
    #   CMDSCRIBE_SKIP_USERS="orion nebula_bkps torrent_bkps"
    case " ${CMDSCRIBE_SKIP_USERS:-} " in
        *" $(id -un) "*) return 0 ;;
    esac

    shopt -s histappend 2>/dev/null
    set -o history 2>/dev/null

    unset HISTIGNORE
    export HISTCONTROL=ignoredups

    export PROMPT_COMMAND=__cmdscribe_bash_run
}

__cmdscribe_bash_install
