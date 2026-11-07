# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# lib/capture/zsh.zsh -- zsh capture hook. OS-agnostic.
#
# Verified on macOS 27.2 / zsh 5.9 under a real pty: real exit codes,
# builtins such as `cd` captured, multi-line commands captured.
#
# zsh is the BETTER case. preexec hands us the command text directly,
# so none of the bash history machinery is involved and the entire
# HISTIGNORE / HISTCONTROL / HISTTIMEFORMAT / "history 1" bug class
# simply does not exist here.

[[ -o interactive ]] || return 0

case " ${CMDSCRIBE_SKIP_USERS:-} " in
    *" $(id -un) "*) return 0 ;;
esac

autoload -Uz add-zsh-hook 2>/dev/null || return 0

__CMDSCRIBE_ZSH_CMD=""

__cmdscribe_zsh_preexec() {
    # $1 is the line about to be executed, before execution.
    __CMDSCRIBE_ZSH_CMD="$1"
}

__cmdscribe_zsh_precmd() {
    # Runs before each prompt, so $? is the previous command's status.
    local _cs_rc=$?
    cmdscribe_emit "$__CMDSCRIBE_ZSH_CMD" "$_cs_rc"
    __CMDSCRIBE_ZSH_CMD=""
}

add-zsh-hook preexec __cmdscribe_zsh_preexec
add-zsh-hook precmd  __cmdscribe_zsh_precmd
