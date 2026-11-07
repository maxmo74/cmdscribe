# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# entry.zsh -- single file the system zsh init sources.
[ -n "$ZSH_VERSION" ] || return 0
[ -n "$CMDSCRIBE_HOME" ] || CMDSCRIBE_HOME=/usr/share/cmdscribe

case "$(uname -s)" in
    Linux)               . "$CMDSCRIBE_HOME/lib/os/linux.sh"  ;;
    Darwin)              . "$CMDSCRIBE_HOME/lib/os/darwin.sh" ;;
    FreeBSD|OpenBSD|NetBSD|DragonFly)
                         . "$CMDSCRIBE_HOME/lib/os/bsd.sh"    ;;
    *)                   return 0 ;;
esac

. "$CMDSCRIBE_HOME/lib/emit.sh"
. "$CMDSCRIBE_HOME/lib/capture/zsh.zsh"
