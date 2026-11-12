# cmdscribe

**Log every command typed in an interactive shell on your servers — who ran it, as whom, and whether it worked.**

```
login=massimo actas=root pid=4127 ppid=4125 tty=pts/0 rc=1 :: ansible-vault view secrets.yml
```

[![ci](https://github.com/maxmo74/cmdscribe/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/maxmo74/cmdscribe/actions/workflows/ci.yml)
![license](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)

## Status

**Pre-1.0.** The shell layer is solid and does one job well.

**Tested:** Debian 13, Ubuntu 24.04 and Rocky Linux 9 (real hosts and CI, bash + zsh, install through uninstall), and macOS (bash 3.2 and zsh 5.9).

**Should work, not tested:** other Linux distributions, BSDs. cmdscribe uses `PROMPT_COMMAND`/`preexec`, `/etc/profile.d`, rsyslog and `/proc` — nothing distribution-specific — but if you are on Fedora or openSUSE and hit a problem, please open an issue.

**Not built yet:** DEB/RPM packages, Ansible roles, and the cross-checking tool (see [Roadmap](#roadmap)).

**Docs:** [SECURITY.md](SECURITY.md) · [CHANGELOG](CHANGELOG.md) · [Contributing](CONTRIBUTING.md)

## Quick start

```sh
git clone https://github.com/maxmo74/cmdscribe
cd cmdscribe
sudo ./install.sh
```

Open a **new** shell, run something, then:

```sh
sudo tail -f /var/log/cmdscribe.log
```

That is the whole thing. One file, one rsyslog rule, no daemon, no dependencies beyond the shell.

### Rolling it out to several hosts

```sh
for h in web1 web2 db1; do
  scp -r cmdscribe "$h:/tmp/" && ssh "$h" 'sudo sh /tmp/cmdscribe/install.sh'
done
```

Re-running the installer is safe: it is idempotent, and it will not stack duplicate hooks.

## What gets recorded

Each interactive command, one line:

| field | meaning |
|---|---|
| `login=` | who was logged in (the real login uid, resolved by walking the process tree) |
| `actas=` | who the command ran as |
| `pid=` `ppid=` `tty=` | process and terminal |
| `rc=` | exit status of the command |
| `::` | the command line, exactly as typed |

### What is deliberately *not* recorded

- **Non-interactive shells** — cron jobs, `ssh host cmd`, scripts, CI runners, daemons. This logs humans at terminals. If you want everything that executes, that is `auditd` (`sudo ./install.sh --auditd` adds the rules on Linux).
- **Passwords typed at prompts.** `mysql -pSecret` is recorded; `mysql -p` followed by typing it is not. The kernel does not capture keystrokes.
- **Environment variables.** Not stored in kernel exec records at all.

## Options

```sh
sudo ./install.sh              # shell layer + rsyslog rule (Linux) / unified log (macOS)
sudo ./install.sh --auditd     # also install auditd rules (Linux; requires the audit package)
sudo ./install.sh --logfile    # also a plain file to tail (macOS only)
sudo ./install.sh --rotate     # rotate weekly (default: never rotate)
```

Flags are the **desired state**, not one-time setup: running `install.sh` without `--rotate` removes a rotation stanza an earlier version may have installed.

## Reading the log

**Linux** — `/var/log/cmdscribe.log`, mode `0600`, written by rsyslog.

**macOS** — records go to the unified log via `logger(1)`:

```sh
log stream --style compact --predicate 'eventMessage CONTAINS "cmdscribe: login="'
log show   --last 1h --style compact --predicate 'eventMessage CONTAINS "cmdscribe: login="'
```

Two macOS gotchas, both verified:

- Do **not** add `--level debug` to `log show` — it returns zero rows where the same command without it returns results. `--debug` is fine.
- Do **not** filter on `process == "cmdscribe"` — macOS `logger(1)` discards the `-t` tag, so records are filed under `/usr/bin/logger`. That is why the marker is in the message body.

## Log retention

**The log is never rotated, expired, or deleted by default.**

An interactive command record is about 200 bytes, and non-interactive shells are not captured at all, so volume is small:

| interactive commands/day | per year |
|---|---|
| 100 — a normal server | ~7 MB |
| 1,000 — busy multi-user host | ~73 MB |
| 10,000 — heavy jump box | ~730 MB |

If you want rotation anyway, `--rotate` adds it. Segments are still never deleted, and the stanza sends rsyslog `HUP` after rotating — without that, rsyslog keeps writing to the rotated inode and the live log silently stops receiving records.

To keep volume down for real, ship the log off-box instead of deleting it: there is a commented `omfwd` collector stanza in `platform/linux/10-cmdscribe.conf`.

## Uninstall

```sh
sudo ./uninstall.sh
```

Removes exactly what the installer recorded: drop-ins it created, appended lines it added (restored from byte-identical backups), the rsyslog rule, and restarts rsyslog.

**It never deletes the log.** An auditing tool whose uninstall destroyed the audit trail would let anyone erase their own history with an uninstall/reinstall pair. Delete the log yourself if that is what you want.

Shells that were already open keep their hook until they exit.

## Requirements

- bash or zsh, interactive
- Linux: rsyslog (standard on Debian, Ubuntu, and most distros)
- macOS: nothing extra
- `--auditd`: the `audit` package (`apt install auditd`, `dnf install audit`, `zypper install audit`)

## How it works

Two independent capture layers, so that one can vouch for the other.

| | shell layer | auditd |
|---|---|---|
| `cd`, `export`, redirections | **yes** — no `execve` happens, so auditd cannot see these | no |
| The line as typed, incl. `FOO=bar cmd`, aliases | **yes** | argv only |
| Exit status | **yes** | no |
| Who it really was after `sudo su -` | heuristic (process-tree walk) | **yes** — `auid` is stamped at login and immutable |
| Survives someone unsetting `PROMPT_COMMAND` | no | **yes** |

The shell layer is what you use day to day. The auditd layer is the independent record that survives someone disabling the shell layer. Comparing them per session is what `cmdscribe-reconcile` will do; **it is not implemented yet** ([#1](https://github.com/maxmo74/cmdscribe/issues/1)), so today the two layers run side by side without cross-checking.

Code layout follows two independent axes — capture depends on the *shell*, attribution depends on the *OS*:

```
lib/capture/bash.sh   PROMPT_COMMAND + history     lib/os/linux.sh   /proc ancestor walk
lib/capture/zsh.zsh   preexec + precmd             lib/os/darwin.sh  ps(1) ancestor walk
```

So bash on macOS reuses `capture/bash.sh` with `os/darwin.sh`. Adding fish is one `capture/` file; adding FreeBSD is one `os/` file.

## Security — read before deploying

Full detail in **[SECURITY.md](SECURITY.md)**. The three that matter operationally:

1. **Secrets in argv are recorded, verbatim, in both layers.** `mysql -pHunter2 prod` goes to the log as typed. There is no redaction, deliberately — patterns like `--password=.*` also match legitimate SQL and produce an audit log with silent holes. The policy is: never put secrets in argv.
2. **The log must stay `0600`.** Command logs contain `cat id_rsa` and pasted tokens. A world-readable command log is a credential leak on every host that has one. The installer enforces this; check after any config-management change.
3. **Anyone with a shell can disable the shell layer** (`PROMPT_COMMAND=`). That is what the auditd layer is for. It does not stop root, and it is not meant to.

## Roadmap

In order of what users need first:

- **`cmdscribe --check`** — a doctor mode that reports whether capture is actually working on this host right now, instead of assuming the install is still intact.
- **DEB and RPM packages**, plus an OBS project for openSUSE.
- **Ansible roles** for fleet deployment.
- **`cmdscribe-reconcile`** — the shell↔auditd cross-check, which turns "we hope the hook was loaded" into a measured number ([#1](https://github.com/maxmo74/cmdscribe/issues/1)).
- BSD verification on real hardware.

## Development

```sh
make check     # behaviour, through real ptys (bash + zsh)
make syntax    # every file parses; shebangs, mode bits, licence headers
make lint      # shellcheck --severity=warning
```

CI runs those on `ubuntu-latest` and `macos-latest`, plus **two installer smoke tests** — one per platform — that run `install.sh` as root, capture through a real login shell, uninstall, and assert the log survived. Set `REQUIRE_SHELLS="bash zsh"` to make a missing shell fail the run instead of silently shrinking it.

`tests/integration.sh` runs the same checks against a real host over SSH:

```sh
HOST=root@yourserver sudo -E ./tests/integration.sh
```

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).

Copyleft, because a hosted-auditing vendor taking this, bolting a dashboard onto it and shipping it closed is the obvious move, and you should be able to say no.
