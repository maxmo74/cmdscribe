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
    local _cs_rc=$? _cs_line _cs_cmd

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

    # Nothing to report: first prompt of a session with no prior history.
    # Emitting here would write records with an empty command field.
    [ -n "$_cs_line" ] || return 0

    _cs_cmd=$(printf '%s\n' "$_cs_line" \
              | sed -E -e 's/^[[:space:]]*[0-9]+[[:space:]]*//')

    # The line that sourced us is not something anyone typed to be audited.
    # Matched by content, deliberately: an earlier revision also skipped any
    # entry at or below the history number seen at install time, which sounds
    # tighter but silently discarded real commands whenever history was short
    # by one. A logger that drops records to avoid one cosmetic artefact has
    # the trade backwards, so the artefact is handled here and nowhere else.
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
