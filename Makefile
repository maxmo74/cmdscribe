.POSIX:
.PHONY: all check lint

all: check

check:
	@sh tests/pty-matrix.sh

lint:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
	@shellcheck -s bash lib/emit.sh lib/os/*.sh lib/capture/bash.sh entry.bash install.sh
	@shellcheck -s zsh  lib/capture/zsh.zsh entry.zsh 2>/dev/null || true
	@echo "lint ok"
