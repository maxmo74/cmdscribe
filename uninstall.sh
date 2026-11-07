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

# install.sh picks the prefix per platform, because macOS keeps /usr on the
# sealed read-only volume. Hardcoding one path here made uninstall remove a
# directory that did not exist, report "removed" anyway (rm -rf on a missing
# path exits 0), and leave the real runtime installed. Both candidates are
# offered; only the ones that exist are claimed as removed.
case "$(uname -s)" in
    Darwin) PREFIXES="/usr/local/share/cmdscribe /usr/share/cmdscribe" ;;
    *)      PREFIXES="/usr/share/cmdscribe" ;;
esac
STATE=/var/lib/cmdscribe
_REMOVED_RULE=""
MANIFEST=$STATE/installed.manifest
_manual=0
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
                    case "$path" in
                        /etc/rsyslog.d/*) _REMOVED_RULE=1 ;;
                    esac
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
            W)
                say "WARNING: $path has a cmdscribe hook and no backup."
                say "         Leaving it untouched. Remove it by hand:"
                say "           grep -n -A1 '^# cmdscribe$' $path"
                say "         then delete those two lines."
                _manual=1
                ;;
            *) say "ignoring unrecognised manifest entry: $kind $path" ;;
        esac
    done < "$MANIFEST"
    rm -rf "$STATE"
fi

for _p in $PREFIXES; do
    if [ -e "$_p" ]; then
        rm -rf "$_p" && say "removed $_p"
    fi
done

# If we removed the rsyslog rule, rsyslog is still running with it loaded
# and will keep writing to a file nothing expects. Reload it so the system
# returns to its own configuration. Failure is not fatal: the rule file is
# already gone, so it will not come back on the next restart.
if [ "$(uname -s)" = Linux ] && [ -d /etc/rsyslog.d ] \
   && ! [ -f /etc/rsyslog.d/10-cmdscribe.conf ]; then
    if [ -n "${_REMOVED_RULE:-}" ]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl restart rsyslog 2>/dev/null; then
            say "restarted rsyslog"
        elif service rsyslog restart >/dev/null 2>&1; then
            say "restarted rsyslog"
        else
            say "NOTE: restart rsyslog yourself; it still holds the removed rule in memory"
        fi
    fi
fi

# The log is evidence, and removing the tool that produced it must not
# remove what it recorded. uninstall.sh therefore never deletes it, on any
# platform, whatever the manifest says -- install.sh does not record it as
# removable in the first place, and this is the second line of defence.
_found=0
for l in /var/log/cmdscribe.log; do
    if [ -e "$l" ]; then
        _n=$(wc -l < "$l" 2>/dev/null | tr -d " " || echo "?")
        say "left $l in place ($_n records). It is evidence."
        say "  delete it yourself if that is what you want: rm $l"
        _found=1
    fi
done
[ "$_found" = 1 ] || say "no log file found on this host"

say "uninstall complete. A shell opened before this still has the hook loaded."
if [ "$_manual" = 1 ]; then
    say "NOTE: at least one file was left hooked -- see the WARNING above."
fi
