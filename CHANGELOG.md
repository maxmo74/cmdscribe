# Changelog

All notable changes to cmdscribe. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This project is pre-1.0. The log format may change before 1.0; anything that changes it will be called out here.

## [Unreleased]

- `cmdscribe --check`: report whether capture is actually working on this host.
- DEB and RPM packages; OBS project for openSUSE.
- Ansible roles.
- `cmdscribe-reconcile`: shell ↔ auditd cross-check.

## [0.0.6] - 2026-11-08

### Fixed
- **auditd rules excluded every user with uid < 1000.** `-F auid>=1000` matched nothing on hosts where human accounts sit below 1000 (macOS-mapped uids, NFS, LDAP, RHEL ≤6 convention). The rule loaded and auditd ran; the output was simply empty, which reads as "nobody did anything". The uid floor is removed.
- **`execveat` was not covered**, so anything reaching a binary by file descriptor produced records no rule matched. Added for both arch variants.
- **`--auditd` reported success when the `audit` package was absent.** It now fails with the install command for your distro and states that only the shell layer is active. `augenrules --load` failing is now an error rather than a note — rules on disk that are not loaded are not protection.

### Known issues
- `ausearch` proved unreliable as a query interface during testing (returns "no matches" for records that are present in the raw log). `cmdscribe-reconcile` will parse `/var/log/audit/audit.log` directly rather than depend on it.

## [0.0.5] - 2026-11-08

### Changed
- **The command log is no longer rotated by default.** Rotation is now opt-in via `--rotate`. The previous default (`weekly`, `rotate 12`) deleted the audit trail after about three months, against the rule that uninstall removes the software and keeps the log.
- When rotation *is* enabled, segments are never deleted (the count is effectively unbounded).

### Added
- `install.sh` treats flags as desired state: installing without `--rotate` removes a rotation stanza an earlier version installed.

## [0.0.4] - 2026-11-08

### Fixed
- **Logging stopped permanently after the first rotation, on every distribution.** The logrotate stanza had no `postrotate`, so rsyslog kept writing to the rotated inode and the live log stayed empty while the host still looked instrumented. With a weekly stanza, that meant auditing died seven days after install on every installed host, with no error anywhere. Added the `postrotate` that sends rsyslog `HUP`, plus a rotation test that reproduces the production command line and a negative control confirming the test detects the regression.

## [0.0.3] - 2026-11-08

### Fixed
- **The log's owner and group are derived from the host** instead of hardcoded to `root:root`. On distributions where rsyslog drops privileges (Ubuntu: `syslog`), a rotated file owned by root cannot be reopened by rsyslog, which would stop logging at the first rotation. Derived from the running process, else the unit's `User=`, else `$PrivDropToUser`, else root.

## [0.0.2] - 2026-11-07

### Fixed
- **The first command of a bash session could be discarded.** The hook's arming logic dropped a record; replaced with a history-number baseline seeded at the first prompt.
- **A bash session could record a command it never ran.** `history 1` at a session's first prompt can still hold the last line of `HISTFILE` from an *earlier* session, which got written out with the current pid, tty and timestamp. Fixed by the baseline above; a regression test plants a canary in `HISTFILE` and fails if it ever appears.
- **`HISTCONTROL` and `HISTIGNORE` were set once and then overwritten** by `~/.bashrc`, which could silently suppress records. They are now re-asserted per prompt.
- **`rm -rf "$PREFIX/lib"`** expanded to `rm -rf /lib` when `PREFIX` was unset. Guarded.
- **`shellcheck -s zsh` never actually ran** — it is "Unknown shell", exit 4, and `|| true` masked it.

### Added
- CI installer smoke test that runs `install.sh` as root on a real distro, captures through a real login shell, uninstalls, and asserts the log survived. This exists because an installer that aborted on every Linux host was passing the entire acceptance matrix.

## [0.0.1] - 2026-11-07

### Added
- Initial release. Shell-layer capture for bash (`PROMPT_COMMAND` + history) and zsh (`preexec` + `precmd`), OS attribution layers for Linux (`/proc`) and macOS (`ps`), rsyslog sink on Linux and the unified log on macOS, auditd rules, idempotent install/uninstall with byte-identical backups, and a pty-driven acceptance matrix.
