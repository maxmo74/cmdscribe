#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# Undo install.sh by replaying its manifest.
#
# Restores use the backup copy install.sh took, not sed. Editing system
# rc files in place means shipping a regex that has to match whatever the
# distribution wrote, and BSD and GNU sed disagree on `-i`. Restoring a
# byte-identical copy cannot get that wrong.

set -eu

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

PREFIX=/usr/share/cmdscribe
STATE=/var/lib/cmdscribe
MANIFEST=$STATE/installed.manifest
say() { printf 'cmdscribe: %s\n' "$1"; }

if [ ! -f "$MANIFEST" ]; then
    say "no manifest at $MANIFEST; removing runtime only"
    say "if install.sh edited rc files, restore them from *.cmdscribe.bak by hand"
else
    while read -r kind path; do
        [ -n "${path:-}" ] || continue
        case "$kind" in
            R)
                if [ -e "$path" ]; then
                    rm -f "$path" && say "removed $path"
                fi
                ;;
            B)
                if [ -f "$path.cmdscribe.bak" ]; then
                    mv -f "$path.cmdscribe.bak" "$path" && say "restored $path"
                else
                    say "WARNING: no backup for $path; leaving it alone"
                    say "         look for a line reading: $ "
                fi
                ;;
            *) say "ignoring unrecognised manifest entry: $kind $path" ;;
        esac
    done < "$MANIFEST"
    rm -rf "$STATE"
fi

rm -rf "$PREFIX"
say "removed $PREFIX"

# The log is evidence. Deleting the tool that produced it must not delete
# what it recorded, so this is left in place deliberately and announced.
for l in /var/log/cmdscribe.log; do
    [ -e "$l" ] && say "left $l in place (it is evidence; remove it yourself if you want)"
done

say "uninstall complete. A shell opened before this still has the hook loaded."
