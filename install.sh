#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# cmdscribe installer. Idempotent. Run as root.
#
#   ./install.sh              shell layer + system log sink
#   ./install.sh --auditd     also the auditd rules (Linux)
#   ./install.sh --logfile    also a plain text file to tail (macOS)
#   ./install.sh --rotate     rotate the log weekly (default: never rotated)
#
# The flags are the desired state, not a one-time setup. Installing without
# --rotate removes a rotation stanza a previous install put there, and installing
# without --auditd leaves the auditd rules alone but says so.
#
# Uninstall with ./uninstall.sh, which replays the manifest written here.
#
# The manifest records one line per change, typed:
#   R <path>   file we created; uninstall deletes it
#   B <path>   file we appended to; uninstall restores <path>.cmdscribe.bak
# Using a backup copy for restores rather than sed means uninstall does
# not depend on BSD and GNU sed agreeing on -i, which they do not.

set -eu

STATE=/var/lib/cmdscribe
MANIFEST=$STATE/installed.manifest
SRC=$(cd "$(dirname "$0")" && pwd)

# Single source of truth, shipped with the runtime so a running install can
# be identified later. A version that exists only in a git tag is useless
# for answering "which build is on this box" three months from now.
VERSION=$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)
MARK='# cmdscribe'
WITH_AUDITD=0
WITH_LOGFILE=0
WITH_ROTATE=0
LOGFILE_PATH=/var/log/cmdscribe.log
for _arg in "$@"; do
    case "$_arg" in
        --auditd)  WITH_AUDITD=1 ;;
        --logfile) WITH_LOGFILE=1 ;;
        --rotate)  WITH_ROTATE=1 ;;
        *) echo "unknown option: $_arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

OS=$(uname -s)

# macOS keeps /usr on the sealed system volume: `mkdir /usr/share/...`
# fails with EPERM even as root. Third-party runtime data belongs under
# /usr/local, which lives on the writable data volume.
case "$OS" in
    Darwin) PREFIX=/usr/local/share/cmdscribe ;;
    *)      PREFIX=/usr/share/cmdscribe ;;
esac
# Every path below hangs off PREFIX, including an rm -rf. `set -u` catches an
# unset variable but not an empty one, and an empty PREFIX would turn
# "$PREFIX/lib" into /lib. Refuse loudly instead of finding out later.
: "${PREFIX:?PREFIX is empty; refusing to continue}"

note() { printf 'cmdscribe: %s\n' "$1"; }
note "version $VERSION, installing on $OS"
rec() { printf '%s %s\n' "$1" "$2" >> "$MANIFEST"; }

# ---- 1. files ------------------------------------------------------ #
# The manifest is a FILE in a directory. Creating it with `mkdir -p
# "$MANIFEST"` makes a directory and every later `>>` fails.
mkdir -p "$STATE" "$PREFIX"
: > "$MANIFEST"

# Deterministic: drop the old runtime so a removed file cannot linger.
rm -rf "${PREFIX:?}/lib" "${PREFIX:?}/entry.bash" "${PREFIX:?}/entry.zsh"
cp -R "$SRC/lib"      "$PREFIX/lib"
cp    "$SRC/entry.bash" "$PREFIX/entry.bash"
cp    "$SRC/entry.zsh"  "$PREFIX/entry.zsh"
cp    "$SRC/VERSION"    "$PREFIX/VERSION"
chmod -R a+rX "$PREFIX"
note "installed runtime to $PREFIX"

# ---- 2. shell hooks ------------------------------------------------ #
# Optional env prefix for the hook line, so the shell that sources the
# entry file also learns where the convenience log is.
LOGVAR=""

# hook_into <file> <line> [create]
#   existing file  -> back up, append one marked line
#   missing file   -> only touched if "create" was passed (used for the
#                     profile.d drop-in, which is ours to create). Without
#                     this, an installer that only ever appends silently
#                     installs nothing on a host with no profile.d file.
hook_into() {
    _hi_f=$1; _hi_line=$2; _hi_mode=${3:-}

    if [ ! -f "$_hi_f" ]; then
        [ "$_hi_mode" = "create" ] || return 0
        printf '%s\n%s\n' "$MARK" "$_hi_line" > "$_hi_f"
        chmod 0644 "$_hi_f"
        rec R "$_hi_f"
        note "created $_hi_f"
        return 0
    fi

    if grep -qF "$MARK" "$_hi_f" 2>/dev/null; then
        # Already hooked. It MUST still be recorded, or a re-install wipes
        # the manifest entry and a later uninstall leaves the hook live --
        # which for an auditing tool means logging quietly continues after
        # someone believes they turned it off. Measured on Debian 13.
        if [ "$_hi_mode" = "create" ]; then
            # A file we created is ours outright: uninstall deletes it, no
            # backup involved. Treating it as an appended-to file is what
            # made a re-install+uninstall leave /etc/profile.d/zz-cmdscribe.sh
            # behind with its hook intact.
            rec R "$_hi_f"
            note "hook already present in $_hi_f (ours; uninstall will remove it)"
        elif [ -f "$_hi_f.cmdscribe.bak" ]; then
            rec B "$_hi_f"
            note "hook already present in $_hi_f (recorded for uninstall)"
        else
            # No backup means the hook was not placed here by this
            # installer, or the backup was removed. There is nothing safe
            # to restore, so say so instead of pretending otherwise.
            rec W "$_hi_f"
            note "WARNING: $_hi_f already contains a cmdscribe hook but has"
            note "  no backup; uninstall will not be able to restore it"
        fi
        return 0
    fi

    cp -p "$_hi_f" "$_hi_f.cmdscribe.bak"
    printf '\n%s\n%s\n' "$MARK" "$_hi_line" >> "$_hi_f"
    rec B "$_hi_f"
    note "hooked $_hi_f"
}

case "$OS" in
    Linux)
        if [ -d /etc/profile.d ]; then
            hook_into /etc/profile.d/zz-cmdscribe.sh \
                      ". $PREFIX/entry.bash" create
        else
            note "/etc/profile.d absent; hooking /etc/profile instead"
            hook_into /etc/profile ". $PREFIX/entry.bash"
        fi

        # Deliberately an if, not `[ -f x ] && hook && break`: as the last
        # command of the loop body that returns non-zero and set -e kills
        # the install on any host without zsh installed.
        for z in /etc/zsh/zshrc /etc/Zsh/zshrc /etc/zshrc; do
            if [ -f "$z" ]; then
                hook_into "$z" ". $PREFIX/entry.zsh"
                break
            fi
        done
        ;;
    Darwin)
        if [ "$WITH_LOGFILE" = 1 ]; then
            # logger(1) cannot do this on macOS: it posts to the unified log
            # and never reaches syslogd's asl file routing. Verified, after a
            # first attempt at an asl rule captured 41 unrelated lines and
            # none of ours.
            if [ ! -e "$LOGFILE_PATH" ]; then
                # Deliberately NOT recorded in the manifest. An auditing
                # tool whose uninstall deletes the audit trail lets anyone
                # erase their own history with an uninstall/reinstall pair.
                install -o root -g admin -m 0660 /dev/null "$LOGFILE_PATH"
            fi
            LOGVAR="CMDSCRIBE_LOGFILE=$LOGFILE_PATH; "
            note "also writing $LOGFILE_PATH (0660 root:admin)"
            note "  WARNING: the shell appends this file itself, so anyone who"
            note "  can type here can also truncate it. It is for eyeballing."
            note "  The unified log remains the record of authority."
        fi
        hook_into /etc/zshrc   "${LOGVAR}. $PREFIX/entry.zsh"
        hook_into /etc/bashrc  "${LOGVAR}. $PREFIX/entry.bash"
        hook_into /etc/profile "${LOGVAR}. $PREFIX/entry.bash"
        ;;
    *)
        note "unsupported OS: $OS"
        note "lib/os/bsd.sh should work on FreeBSD/OpenBSD/NetBSD -- same"
        note "ps(1)-based attribution as macOS -- but no BSD has run it."
        ;;
esac

# ---- 3. sink ------------------------------------------------------- #
case "$OS" in
    Linux)
        if [ "$WITH_LOGFILE" = 1 ]; then
            note "--logfile ignored on Linux: rsyslog already writes"
            note "$LOGFILE_PATH as root with 0600, which is strictly better"
            note "than a file the typing user appends to themselves"
        fi
        # ---- who may own the log ------------------------------------- #
        # The log's owner must be the account rsyslog actually runs as, and the
        # group must be the one that owns /var/log. Neither can be hardcoded:
        #
        #   Debian  rsyslog runs as root     /var/log 0755 root:root
        #   Ubuntu  rsyslog runs as syslog   /var/log 0775 root:adm
        #
        # Shipping `create 0600 root root` fails twice over on Ubuntu. logrotate
        # refuses to rotate inside a directory that is writable by a group other
        # than the one it is creating the file for, so it errors every week and
        # the log NEVER rotates: a file full of typed passwords growing without
        # bound, the only evidence a logrotate error nobody reads. And were it to
        # rotate, the fresh root:root 0600 file would be unwritable by the
        # unprivileged rsyslog, so logging would also silently stop.
        #
        # Mode stays 0600 throughout, so carrying the directory group grants that
        # group nothing at all -- the group bits are empty. The set of readers is
        # the file owner and root, which is the guarantee SECURITY.md makes.
        CS_LOG_USER=""
        # Ground truth when it exists: the account the running daemon actually
        # has. Ubuntu's unit carries no User= at all -- it drops privileges via
        # $PrivDropToUser in /etc/rsyslog.conf -- so reading only the unit answers
        # "root" on precisely the distro where the distinction matters. That was
        # measured here, not assumed.
        cs_p=$(ps -C rsyslogd -o user= 2>/dev/null | head -1 | tr -d ' ')
        [ -n "$cs_p" ] && CS_LOG_USER="$cs_p"

        # Not running yet -- fresh install, container, chroot -- so fall back to
        # configuration, unit first, then the directive Ubuntu actually uses.
        if [ -z "$CS_LOG_USER" ]; then
            for cs_unit in /lib/systemd/system/rsyslog.service \
                           /etc/systemd/system/rsyslog.service; do
                [ -r "$cs_unit" ] || continue
                cs_u=$(sed -n 's/^[[:space:]]*User=\([A-Za-z0-9_-]*\).*/\1/p' \
                        "$cs_unit" | tail -1)
                [ -n "$cs_u" ] && CS_LOG_USER="$cs_u"
            done
        fi
        if [ -z "$CS_LOG_USER" ] && [ -r /etc/rsyslog.conf ]; then
            cs_u=$(sed -n \
                's/^[[:space:]]*\$PrivDropToUser[[:space:]]\{1,\}\([A-Za-z0-9_-]*\).*/\1/p' \
                /etc/rsyslog.conf | tail -1)
            [ -n "$cs_u" ] && CS_LOG_USER="$cs_u"
        fi

        [ -n "$CS_LOG_USER" ] || CS_LOG_USER=root
        id -u "$CS_LOG_USER" >/dev/null 2>&1 || CS_LOG_USER=root

        CS_LOG_GROUP=$(stat -c '%G' /var/log 2>/dev/null || echo root)
        id -g "$CS_LOG_GROUP" >/dev/null 2>&1 || CS_LOG_GROUP=root

        note "log owner will be $CS_LOG_USER:$CS_LOG_GROUP, mode 0600"

        # An existing log owned by someone else would be unwritable by the
        # rsyslog account under this arrangement. Correct the owner rather than
        # leave a host that silently logs nothing. Contents are not touched --
        # uninstall keeps the evidence and so does this.
        if [ "$CS_LOG_USER" != root ] && [ -e /var/log/cmdscribe.log ]; then
            cs_cur=$(stat -c '%U' /var/log/cmdscribe.log 2>/dev/null || echo unknown)
            if [ "$cs_cur" != "$CS_LOG_USER" ]; then
                chown "$CS_LOG_USER:$CS_LOG_GROUP" /var/log/cmdscribe.log
                chmod 0600 /var/log/cmdscribe.log
                note "re-owned the log $cs_cur -> $CS_LOG_USER:$CS_LOG_GROUP so rsyslog can write it"
            fi
        fi

        if [ -d /etc/rsyslog.d ]; then
            sed -e "s/@CS_LOG_USER@/$CS_LOG_USER/g" \
                -e "s/@CS_LOG_GROUP@/$CS_LOG_GROUP/g" \
                "$SRC/platform/linux/10-cmdscribe.conf" \
                > /etc/rsyslog.d/10-cmdscribe.conf || {
                    note "ERROR: could not write the rsyslog rule"; exit 1; }
            chmod 0644 /etc/rsyslog.d/10-cmdscribe.conf
            chown root:root /etc/rsyslog.d/10-cmdscribe.conf
            rec R /etc/rsyslog.d/10-cmdscribe.conf
            if command -v rsyslogd >/dev/null 2>&1; then
                # Validate with the file already in place (that is the only
                # way to test it in the context of the real config), but on
                # failure REMOVE it again. Leaving an unvalidated rule behind
                # and exiting can keep rsyslog from starting at all, which
                # takes the host's whole logging down, not just cmdscribe.
                if rsyslogd -N1 >/dev/null 2>&1; then
                    if command -v systemctl >/dev/null 2>&1; then
                        systemctl restart rsyslog && note "restarted rsyslog"
                    elif service rsyslog restart >/dev/null 2>&1; then
                        note "restarted rsyslog"
                    else
                        note "could not restart rsyslog; rule needs a manual restart"
                    fi
                else
                    rm -f /etc/rsyslog.d/10-cmdscribe.conf
                    note "ERROR: rsyslog rejected the rule; removed it, nothing restarted"
                    rsyslogd -N1 2>&1 | tail -5 | sed 's/^/    /'
                    exit 1
                fi
            else
                note "rsyslog not present; records will go wherever logger sends them"
            fi
        fi
        # ---- rotation ------------------------------------------------ #
        # Default is never rotated, and that is a decision rather than an
        # omission. An interactive command log measured ~200 bytes a record, and
        # non-interactive shells are not captured at all, so cron, scripts, CI
        # runners and daemons add nothing. A very busy multi-user host lands under
        # a gigabyte a year. Rotation buys nothing that capacity would not, and it
        # costs three things:
        #
        #   - `rotate 12` with `weekly` deletes the audit trail after ~3 months,
        #     against the rule this tool otherwise keeps without exception:
        #     uninstall removes the tool and keeps the log.
        #   - its failure mode is silent. It did exactly that, on every host,
        #     for the whole life of this project. SECURITY.md limitation 9.
        #   - it fragments evidence across a compressed chain, which is worse for
        #     reconstruction rather than better.
        #
        # Measured on Debian 13 and Ubuntu 24.04: no baseline logrotate config
        # globs /var/log/*, so this log is rotated only if we ask for it. Declining
        # to ask is therefore a real guarantee and not a hope -- and --check must
        # keep asserting it, because a future distro baseline or a config-
        # management glob could take rotation back silently and reintroduce the
        # quiet death.
        if [ -d /etc/logrotate.d ]; then
            if [ "$WITH_ROTATE" = 1 ]; then
                sed -e "s/@CS_LOG_USER@/$CS_LOG_USER/g" \
                    -e "s/@CS_LOG_GROUP@/$CS_LOG_GROUP/g" \
                    "$SRC/platform/linux/cmdscribe.logrotate" \
                    > /etc/logrotate.d/cmdscribe || {
                        note "ERROR: could not write the logrotate config"; exit 1; }
                chmod 0644 /etc/logrotate.d/cmdscribe
                chown root:root /etc/logrotate.d/cmdscribe
                rec R /etc/logrotate.d/cmdscribe
                note "rotation enabled; segments are kept, never deleted"
            elif [ -e /etc/logrotate.d/cmdscribe ]; then
                # Removing this is the difference between "no rotation" and
                # "rotation you did not ask for", and on a host upgrading from an
                # earlier version that difference is the entire point.
                if grep -q "/var/log/cmdscribe.log" /etc/logrotate.d/cmdscribe; then
                    rm -f /etc/logrotate.d/cmdscribe
                    note "removed a rotation stanza left by an earlier version;"
                    note "the log is no longer rotated or deleted. Re-add with --rotate"
                else
                    note "WARNING: /etc/logrotate.d/cmdscribe is not ours; left in place"
                fi
            fi
        fi
        ;;
    Darwin)
        note "no rsyslog on macOS; records go to the unified log via logger(1)"
        # NOT 'process == "cmdscribe"'. logger(1) drops -t on macOS, so that
        # predicate matches nothing and looks like an idle machine. The
        # marker lives in the message body instead (see lib/os/darwin.sh).
        #
        # And do NOT add --level debug to `log show`: measured on macOS
        # 27.2, `log show --level debug --predicate ...` returns ZERO rows
        # where the same command without it returns 26. `--debug` works,
        # plain works, `--level debug` does not. `log stream` accepts it
        # but does not need it.
        note "follow live with:  log stream --style compact \\"
        note "                     --predicate 'eventMessage CONTAINS \"cmdscribe: login=\"'"
        note "or after the fact: log show --last 1h \\"
        note "                     --predicate 'eventMessage CONTAINS \"cmdscribe: login=\"'"
        # No rotation config is installed on macOS. platform/ holds one for
        # the BSDs only, because a rotation rule for a file nothing writes is
        # how a box ends up looking like it keeps logs when it keeps none.
        ;;
esac

# ---- 4. optional auditd -------------------------------------------- #
if [ "$WITH_AUDITD" = 1 ] && [ "$OS" = Linux ] && command -v augenrules >/dev/null 2>&1; then
    install -m 0640 -o root -g root \
        "$SRC/platform/linux/cmdscribe.rules" /etc/audit/rules.d/cmdscribe.rules
    rec R /etc/audit/rules.d/cmdscribe.rules
    if augenrules --load; then
        note "loaded auditd rules"
    else
        note "augenrules --load failed; rules installed but not active"
    fi
    note "check pam_loginuid or auid is worthless:"
    note "  grep -l pam_loginuid /etc/pam.d/sshd /etc/pam.d/login"
fi

note "done."
case "$OS" in
    Darwin) note "open a NEW shell, run a command, then: log stream --style compact --predicate 'eventMessage CONTAINS \"cmdscribe: login=\"'" ;;
    *)      note "open a NEW shell, run a command, then: sudo tail -f /var/log/cmdscribe.log" ;;
esac
