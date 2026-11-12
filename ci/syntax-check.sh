#!/bin/sh

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# Parse-only checks plus a licence-header check, for every interpreter this
# project ships files for. Runs without shellcheck, so it works on a bare
# host and on a runner before anything is installed.
#
# Deliberate design rule for this file and for the Makefile: a check that
# cannot run must FAIL, or say so in a way that is impossible to miss. It must
# never be wrapped in `|| true`. That is how `shellcheck -s zsh` sat in this
# project reporting success while exiting 4 on every invocation.

set -u

cd "$(dirname "$0")/.." || exit 1

fail=0
note() { printf '  %s\n' "$1"; }
die() { printf 'FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); }

# git ls-files when we are in a checkout; a fixed list otherwise, because a
# tarball install has no git.
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
    files=$(git ls-files)
else
    files=$(find . -path ./.git -prune -o -type f -print | sed 's|^\./||' | sort)
fi

printf 'syntax: parse checks\n'

# --- sh: every .sh file -----------------------------------------------------
# stderr is left connected on purpose: if a parse check fails, the reason has
# to be in the log next to the failure, not swallowed into a temp file.
for f in $(printf '%s\n' "$files" | grep '\.sh$'); do
    sh -n "$f" || die "sh -n $f"
done
note "sh -n: $(printf '%s\n' "$files" | grep -c '\.sh$') files"

# --- bash: the two files that ARE bash, and must survive bash 3.2 ----------
# macOS ships bash 3.2 from 2007 and always will, so this is not a legacy
# courtesy; it is the interpreter real macOS users have.
if command -v bash >/dev/null 2>&1; then
    for f in entry.bash lib/capture/bash.sh; do
        [ -f "$f" ] && { bash -n "$f" || die "bash -n $f"; }
    done
    note "bash -n: entry.bash lib/capture/bash.sh ($(bash --version 2>/dev/null | head -1))"
else
    note "bash: not present -- SKIPPED, and that is a gap"
fi

# --- zsh: the macOS default shell and the modern Linux one -----------------
if command -v zsh >/dev/null 2>&1; then
    for f in entry.zsh lib/capture/zsh.zsh; do
        [ -f "$f" ] && { zsh -n "$f" || die "zsh -n $f"; }
    done
    note "zsh -n: entry.zsh lib/capture/zsh.zsh ($(zsh --version 2>/dev/null))"
else
    die "zsh is required to check the zsh entry points; install it or the zsh files go unverified"
fi

# --- python ----------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
    pys=""
    for f in $(printf '%s\n' "$files" | grep -E '\.py$'); do
        head -1 "$f" | grep -q 'python' && pys="$pys $f"
    done
    if [ -n "$pys" ]; then
        # shellcheck disable=SC2086
        python3 -m py_compile $pys || die "python3 -m py_compile$pys"
        rm -rf __pycache__ tests/__pycache__ ci/__pycache__
        note "py_compile:$pys"
    fi
else
    die "python3 is required (tests/drive-pty.py is python)"
fi

# --- executable files need a shebang, and the entry points need to be loadable
# Only files marked executable by git are required to carry a shebang. The
# entry.* and lib/ files are SOURCED by a login shell, so giving them one
# would be wrong -- it is the sourced files that must not have one, because a
# shebang in a sourced file is a comment anyway but invites someone to run it
# directly and wonder why nothing is logged.
sb_fail=0
for f in $(printf '%s\n' "$files"); do
    [ -f "$f" ] || continue
    [ -x "$f" ] || continue
    head -c2 "$f" | grep -q '#!' && continue
    die "executable but no shebang: $f"
    sb_fail=1
done
[ "$sb_fail" -eq 0 ] && note "shebangs: every executable file has one"

# The inverse: these are invoked by hand or by CI, so losing the mode bit
# breaks the run with "Permission denied" on someone's first attempt.
mode_fail=0
for f in install.sh uninstall.sh ci/syntax-check.sh ci/install-smoke.sh \
         ci/install-smoke-macos.sh tests/integration.sh tests/pty-matrix.sh; do
    [ -f "$f" ] || continue
    [ -x "$f" ] && continue
    die "should be executable but is not: $f"
    mode_fail=1
done
[ "$mode_fail" -eq 0 ] && note "mode bits: entry points executable"

# --- no CRLF ---------------------------------------------------------------
# A .sh file committed from Windows parses as garbage on every target, and
# the failure looks like a syntax error in an unrelated line.
#
# Written as a plain loop rather than `crlf=$(... while ... done)`: a `case`
# inside a command substitution makes bash 3.2 mis-match the `)` in a pattern
# and report a syntax error on a line that is perfectly valid on its own.
crlf=""
for f in $(printf '%s\n' "$files"); do
    [ -f "$f" ] || continue
    LC_ALL=C grep -q "$(printf '\r')" "$f" 2>/dev/null && crlf="$crlf $f"
done
if [ -n "$crlf" ]; then
    die "CRLF line endings in:$crlf"
else
    note "line endings: LF everywhere"
fi

# --- licence header on every code file ------------------------------------
# Cheap, and it is the kind of thing a new file quietly forgets. The rule is
# by extension, so adding lib/capture/fish.fish without a header fails here
# rather than in review.
missing=""
for f in $(printf '%s\n' "$files" | grep -E '\.(sh|bash|zsh|py)$'); do
    [ -f "$f" ] || continue
    grep -q 'SPDX-License-Identifier: GPL-3.0-or-later' "$f" || missing="$missing $f"
done
if [ -n "$missing" ]; then
    die "missing SPDX header (GPL-3.0-or-later):$missing"
else
    note "SPDX headers: present on all code files"
fi

printf '\n'
if [ "$fail" -ne 0 ]; then
    printf 'syntax: %d problem(s)\n' "$fail"
    exit 1
fi
printf 'syntax ok\n'
