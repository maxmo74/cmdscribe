# Contributing

Thanks. This is a small tool that runs on servers, so the bar is "prove it works on a real host", not "the tests are green".

## Getting set up

```sh
git clone https://github.com/maxmo74/cmdscribe
cd cmdscribe
make check     # behaviour, through real ptys (needs bash, zsh, python3)
make syntax    # parses, shebangs, mode bits, licence headers
make lint      # shellcheck --severity=warning
```

`make check` skips a shell that isn't installed — right for a laptop, wrong for a gate. Set `REQUIRE_SHELLS="bash zsh"` and a missing shell fails the run instead of quietly shrinking it. CI always sets it.

## Verifying against a real host

The suite can drive an actual server over SSH, which is the only way to test rsyslog, log rotation, file ownership and login shells honestly:

```sh
HOST=root@yourserver sudo -E ./tests/integration.sh
```

It skips shells that aren't installed rather than reporting them as failures.

## Layout

Two independent axes, kept separate on purpose:

```
lib/capture/   one file per SHELL — how to intercept a command line
lib/os/        one file per OS    — how to answer "who am I really"
lib/emit.sh    the record format, shared by everything
```

- **Adding a shell** (fish, dash): one file in `lib/capture/`, plus a case in `entry.*` and an entry in the pty matrix.
- **Adding an OS** (FreeBSD, Solaris): one file in `lib/os/`, answering the same few questions the others do.

Bash on macOS reuses `capture/bash.sh` with `os/darwin.sh`, so don't put OS-specific logic in `capture/` or shell-specific logic in `os/`.

## What we care about

**A silent failure is a bug, even when nothing errors.** This project's worst defect was a rotation stanza that stopped all logging a week after install, on every host, with no error anywhere. So: if a failure mode exists where the tool looks like it's working and isn't, that's a defect worth fixing even if nobody has hit it.

**Verify the thing you're actually shipping.** Testing by sourcing `entry.bash` out of a checkout once let an installer that aborted on every Linux host pass the entire acceptance matrix. Where install paths matter, run the installer.

**Show the negative control.** When you fix something, remove the fix and confirm a test fails. Several fixes in this project passed review while doing nothing.

**Untested means untested.** Say so in the docs rather than implying coverage that doesn't exist. `lib/os/bsd.sh` is documented as never executed, and that's correct.

**Prefer deleting the failure class over patching the instance.** Rotation used to be on by default with an expiring count; the fix was to stop rotating at all.

## Style

- POSIX sh where it isn't bash-specific; `set -eu` in the scripts.
- `make lint` must pass (`shellcheck --severity=warning`). Note that shellcheck has no zsh front end, so `.zsh` files are covered by `make syntax` and the pty matrix instead — a real gap, not a covered one.
- Every file keeps the SPDX header and copyright line.
- No CRLF; `.editorconfig` covers it.

## Changes to the log format

The record format is the interface that matters — people grep it and script against it. Open an issue before changing it; it will need a version bump and a CHANGELOG entry.

## License

By submitting a contribution you confirm you may license it under GPL-3.0-or-later and you do.
