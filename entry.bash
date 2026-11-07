# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# entry.bash -- single file the system shell init sources.
#
# Picks the OS layer at runtime so the same install works across
# Linux distributions and macOS without per-OS packages.

[ -n "$BASH_VERSION" ] || return 0

# Locate ourselves. A hardcoded /usr/share/cmdscribe default is wrong on
# macOS, where SIP keeps /usr on a sealed read-only volume and the runtime
# has to live under /usr/local. ${BASH_SOURCE} is this file's own path.
_cs_self=${BASH_SOURCE[0]:-$0}
: "${CMDSCRIBE_HOME:=${_cs_self%/*}}"

case "$(uname -s)" in
    Linux)               . "$CMDSCRIBE_HOME/lib/os/linux.sh"  ;;
    Darwin)              . "$CMDSCRIBE_HOME/lib/os/darwin.sh" ;;
    FreeBSD|OpenBSD|NetBSD|DragonFly)
                         . "$CMDSCRIBE_HOME/lib/os/bsd.sh"    ;;
    *)                   return 0 ;;
esac

. "$CMDSCRIBE_HOME/lib/emit.sh"
. "$CMDSCRIBE_HOME/lib/capture/bash.sh"
