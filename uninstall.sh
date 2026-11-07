#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

set -eu
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
MANIFEST=/var/lib/cmdscribe/installed.manifest
MARK='# cmdscribe'

if [ -f "$MANIFEST" ]; then
    while read -r f; do
        case "$f" in
            /etc/profile.d/*|/etc/zsh*|/etc/Zsh*|/etc/bashrc|/etc/profile)
                sed -i "/$MARK/d;|entry\.\(bash\|zsh\)|d" "$f" 2>/dev/null \
                    || sed -i '' "/$MARK/d" "$f"
                [ -f "$f.cmdscribe.bak" ] && mv "$f.cmdscribe.bak" "$f"
                echo "cmdscribe: unhooked $f" ;;
            *)  rm -f "$f" && echo "cmdscribe: removed $f" ;;
        esac
    done < "$MANIFEST"
    rm -rf "$(dirname "$MANIFEST")"
fi
rm -rf /usr/share/cmdscribe
echo "cmdscribe: removed runtime. /var/log/cmdscribe.log left in place."
