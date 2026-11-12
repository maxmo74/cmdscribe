.POSIX:

# Copyright (C) 2026 Massimo Santoro <massimosantoro@gmail.com>
# SPDX-License-Identifier: GPL-3.0-or-later
# This program is free software under the GNU General Public License
# version 3 or later; see LICENSE in the top-level directory for the full text.

# SC_SEVERITY=style would also report cosmetic advice; warning is the level
# that corresponds to "this could actually go wrong on a host".
SC_SEVERITY ?= warning

.PHONY: all check lint syntax

all: check

# The acceptance matrix. Drives real ptys, so this is the target that proves
# behaviour rather than intent.
check:
	@sh tests/pty-matrix.sh

# Static analysis. Note what is NOT here: shellcheck has no zsh front end at
# all -- `shellcheck -s zsh` is "Unknown shell", exit 4 -- so the .zsh files
# cannot be statically analysed by it. An earlier revision of this file ran
# `shellcheck -s zsh ... 2>/dev/null || true`, which therefore failed every
# single time and reported success. A checker that cannot run must not be
# written so that it passes; the zsh files are covered by `make syntax` for
# parsing and by the pty matrix for behaviour, which is the honest version.
lint:
	@command -v shellcheck >/dev/null || { \
	  echo "shellcheck not installed:"; \
	  echo "  brew install shellcheck | dnf install shellcheck | apt-get install -y shellcheck"; \
	  exit 1; }
	@find . -path ./.git -prune -o -type f \( -name '*.sh' -o -name '*.bash' \) -print \
		| sort | xargs shellcheck --severity=$(SC_SEVERITY) -s bash
	@echo "lint ok (shellcheck --severity=$(SC_SEVERITY))"

# Parse-only, for every interpreter this project ships files for, plus the
# licence-header check. Cheaper than lint and works without shellcheck.
syntax:
	@sh ci/syntax-check.sh
