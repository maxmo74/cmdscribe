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

    # Re-assert HISTCONTROL on every prompt, not just at install.
    #
    # Setting it once from /etc/profile.d is not enough: ~/.bashrc runs after
    # profile.d and routinely overwrites it. Measured on the CI runner, where
    # the value in the live shell was `ignoredups:ignorespace` despite the hook
    # having set `ignoredups`. Both halves are bad here:
    #
    #   ignorespace  a leading space keeps a command out of history entirely,
    #                so `history 1` returns the PREVIOUS command and the record
    #                is a false attribution with a borrowed exit status. It is a
    #                one-keystroke evasion for anyone who knows the hook exists.
    #   ignoredups   a command equal to the previous history entry is not added,
    #                which is the same failure by different means -- and it can
    #                fire on the very first command of a session, because the
    #                previous entry came out of HISTFILE.
    #
    # Empty means "store everything". This is a logger; history fidelity beats
    # whatever the user's dotfiles wanted.
    HISTCONTROL=

    # SC1007: the space after `=` is deliberate. HISTTIMEFORMAT must be
    # empty for this one `history` call; `HISTTIMEFORMAT=history 1` would
    # instead assign the string "history". `history` is a plain builtin so
    # bash scopes the assignment to the call anyway, and the command
    # substitution is a subshell, so it cannot leak even where it would.
    # shellcheck disable=SC1007
    _cs_line=$(HISTTIMEFORMAT= history 1 2>/dev/null)

    # Split number from command text without a fork -- this runs after every
    # command on every shell on every host it is installed on.
    _cs_trim=${_cs_line#"${_cs_line%%[![:space:]]*}"}
    _cs_num=${_cs_trim%%[!0-9]*}
    case $_cs_num in ''|*[!0-9]*) _cs_num='' ;; esac

    # Seed the baseline once, at the FIRST invocation, and emit nothing then.
    #
    # This is the reason the function looks like this. `history 1` at a
    # session's first prompt is not necessarily something this session typed:
    # bash loads HISTFILE before drawing the first prompt, so the last entry can
    # belong to some earlier session entirely -- and emitting it writes a record
    # carrying THIS session's pid, tty and timestamp for a command nobody here
    # ran. CI caught exactly that: a session logged `exit`, which it cannot have
    # run, because `exit` ends the shell before PROMPT_COMMAND fires.
    # Manufacturing a record is worse than missing one. SECURITY.md, 7.
    #
    # Seeded here rather than at install because install runs inside
    # /etc/profile.d, BEFORE bash has read HISTFILE -- measured, `history 1` is
    # empty there -- so an install-time baseline is always 0 and suppresses
    # nothing. An install-time baseline is what was tried first, and letting it
    # be vacuous is what let the false record through.
    if [ -z "${__CMDSCRIBE_HISTBASE+set}" ]; then
        __CMDSCRIBE_HISTBASE=${_cs_num:-0}
        return 0
    fi

    # Anything at or below the baseline predates anything this session typed.
    if [ -n "$_cs_num" ] && [ "$_cs_num" -le "$__CMDSCRIBE_HISTBASE" ]; then
        return 0
    fi

    # First prompt of a session with no prior history at all.
    [ -n "$_cs_line" ] || return 0

    _cs_cmd=$(printf '%s\n' "$_cs_line" \
              | sed -E -e 's/^[[:space:]]*[0-9]+[[:space:]]*//')
    [ -n "$_cs_cmd" ] || return 0

    # Belt to the baseline's braces. The line that sourced us is never a
    # command, whatever its history number claims.
    case "$_cs_cmd" in
        ". "*entry.bash*|"source "*entry.bash*) return 0 ;;
    esac

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
    # Deliberately NOT exporting HISTCONTROL here. It belongs in the run
    # function, which executes after every prompt and therefore after any
    # ~/.bashrc has had its say; set once here it is simply overwritten by the
    # first user rc file that assigns it, which is most of them.
    export PROMPT_COMMAND=__cmdscribe_bash_run
}

__cmdscribe_bash_install
