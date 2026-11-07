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
#    lines into history, so the first prompt can report a line of this
#    file rather than a typed command. Suppressed by a history-number
#    baseline (see __CMDSCRIBE_HISTBASE), NOT by dropping "the first
#    invocation".
# ------------------------------------------------------------------ #

__cmdscribe_bash_run() {
    local _cs_rc=$? _cs_line _cs_cmd _cs_trim _cs_num

    # SC1007: the space after `=` is deliberate. HISTTIMEFORMAT must be
    # empty for this one `history` call; `HISTTIMEFORMAT=history 1` would
    # instead assign the string "history". `history` is a plain builtin so
    # bash scopes the assignment to the call anyway, and the command
    # substitution is a subshell, so it cannot leak even where it would.
    # shellcheck disable=SC1007
    _cs_line=$(HISTTIMEFORMAT= history 1 2>/dev/null)

    # Nothing to report: first prompt of a session with no prior history.
    # Emitting here would write records with an empty command field.
    [ -n "$_cs_line" ] || return 0

    _cs_cmd=$(printf '%s\n' "$_cs_line" \
              | sed -E -e 's/^[[:space:]]*[0-9]+[[:space:]]*//')

    # The line that sourced us is not something anyone typed to be audited.
    # Match it by content so this works even when the baseline is unavailable.
    case "$_cs_cmd" in
        ". "*entry.bash*|"source "*entry.bash*) return 0 ;;
    esac

    # And by position: anything at or below the history number observed when
    # the hook went in predates the hook, so the hook cannot vouch for it.
    # Parsed with parameter expansion rather than another sed, because this
    # function runs after every single command and a fork per command is a
    # regression you pay for forever.
    if [ -n "$__CMDSCRIBE_HISTBASE" ]; then
        _cs_trim=${_cs_line#"${_cs_line%%[![:space:]]*}"}
        _cs_num=${_cs_trim%%[!0-9]*}
        case $_cs_num in
            ''|*[!0-9]*) ;;                       # unparseable: emit anyway
            *) [ "$_cs_num" -le "$__CMDSCRIBE_HISTBASE" ] && return 0 ;;
        esac
    fi

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

    # Where history stands right now. Everything at or below this number was
    # already in the list before the hook existed, so it is either the line
    # that sourced us or a previous session's last command -- neither is
    # something this hook can vouch for.
    #
    # This replaces an earlier `__CMDSCRIBE_ARMED` flag that discarded the
    # first PROMPT_COMMAND invocation outright. That was a guess dressed up as
    # a rule: it is correct only when the first invocation happens to land on
    # the sourcing artifact. CI found a host where the first invocation landed
    # on a real command instead -- a login shell that read buffered input
    # before drawing its first prompt -- and the hook silently threw that
    # command away. In an auditing tool, "sometimes we drop a command and do
    # not say so" is the worst defect available, and SECURITY.md limitation 6
    # describes how to widen that window deliberately. Compare numbers instead
    # of counting invocations: nothing typed is ever discarded, and nothing
    # untyped is ever attributed.
    # shellcheck disable=SC1007  # same deliberate empty HISTTIMEFORMAT as above
    __CMDSCRIBE_HISTBASE=$(HISTTIMEFORMAT= history 1 2>/dev/null \
                           | sed -E -e 's/^[[:space:]]*([0-9]+).*/\1/')

    export PROMPT_COMMAND=__cmdscribe_bash_run
}

__cmdscribe_bash_install
