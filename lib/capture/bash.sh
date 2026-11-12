# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# lib/capture/bash.sh -- bash capture hook. OS-agnostic.
#
# Sourced by the per-OS loader, after lib/emit.sh and one lib/os/*.sh.

[ -n "$BASH_VERSION" ] || return 0

# ------------------------------------------------------------------ #
# Each clause below defuses a real failure. In short:
#
#   * PROMPT_COMMAND runs AFTER the command, so $? is its real status.
#   * `history 1` is the only way to get the typed line in bash, so HISTIGNORE
#     and HISTCONTROL actively corrupt the record: an excluded command never
#     enters history and `history 1` re-reports the PREVIOUS command with a
#     borrowed exit status. Both are re-asserted per prompt, below.
#   * HISTTIMEFORMAT must be empty or bash splices a timestamp into the text.
#   * sed needs -E: BSD sed silently ignores GNU '\+' and would leave the
#     history number in every record.
#   * Sourcing this file from a login shell pushes its own lines into history,
#     so the first prompt can report a line of this file rather than a typed
#     command. Suppressed by the history-number baseline, not by dropping the
#     first invocation.
# ------------------------------------------------------------------ #

__cmdscribe_bash_run() {
    local _cs_rc=$? _cs_line _cs_cmd _cs_trim _cs_num

    # Re-asserted every prompt rather than once at install: ~/.bashrc runs after
    # /etc/profile.d and routinely overwrites both. `ignorespace` lets a leading
    # space keep a command out of history, so `history 1` returns the PREVIOUS
    # command -- a false attribution with a borrowed exit status, and a
    # one-keystroke evasion for anyone who knows the hook exists. `ignoredups` is
    # the same failure by different means, and can fire on a session's first
    # command because the previous entry came out of HISTFILE. HISTIGNORE is
    # worse, being a glob list: `HISTIGNORE='ls *'` erases every ls while
    # leaving the log otherwise full and convincing.
    #
    # Anything settable after /etc/profile.d has to be re-asserted at every
    # prompt or it is not a guarantee at all. Empty HISTCONTROL means "store
    # everything": for a logger, history fidelity beats the dotfile preference.
    HISTCONTROL=
    unset HISTIGNORE

    # SC1007: the space after `=` is deliberate. `HISTTIMEFORMAT=history 1`
    # would assign the string "history" instead of clearing the variable.
    # shellcheck disable=SC1007
    _cs_line=$(HISTTIMEFORMAT= history 1 2>/dev/null)

    # Split number from command text without a fork -- this runs after every
    # command on every shell on every host it is installed on.
    _cs_trim=${_cs_line#"${_cs_line%%[![:space:]]*}"}
    _cs_num=${_cs_trim%%[!0-9]*}
    case $_cs_num in ''|*[!0-9]*) _cs_num='' ;; esac

    # Seed the baseline once, at the first invocation, and emit nothing then.
    # `history 1` at a session's first prompt is not necessarily something this
    # session typed: bash loads HISTFILE before drawing the prompt, so the last
    # entry can belong to an earlier session -- and emitting it writes a record
    # carrying THIS session's pid, tty and timestamp for a command nobody here
    # ran. CI caught exactly that: a session logged `exit`, which it cannot have
    # run, because `exit` ends the shell before PROMPT_COMMAND fires.
    # Manufacturing a record is worse than missing one.
    #
    # Seeded here rather than at install because install runs inside
    # /etc/profile.d, before bash has read HISTFILE -- so an install-time
    # baseline is always 0 and suppresses nothing.
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

    # HISTIGNORE and HISTCONTROL are handled in the run function instead, which
    # executes after every prompt and therefore after any ~/.bashrc has had its
    # say. Set once here they are overwritten by the first user rc file that
    # assigns them, which is most of them -- and unlike a missing record, a
    # HISTIGNORE pattern produces a log that looks complete while quietly
    # omitting a whole class of commands.
    export PROMPT_COMMAND=__cmdscribe_bash_run
}

__cmdscribe_bash_install
