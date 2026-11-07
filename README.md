# Command Scribe (`cmdscribe`)

Self-verifying command auditing for Unix shells.

Two independent capture layers record what was run and by whom, and
**cross-check each other**. The shell layer sees what you actually typed
(including things the kernel never sees). The kernel layer carries
attribution you cannot argue with. Neither alone is trustworthy; the
disagreement between them is the product.

```
login=massimo actas=root pid=4127 ppid=4125 tty=pts/0 rc=1 :: ansible-vault view secrets.yml
```

**Status: pre-1.0.** The shell layer is verified on Linux and macOS. The
reconciliation tool — the actual differentiator — is a specification, not
code. Read [SECURITY.md](SECURITY.md) before putting this on anything.

---

## Why two layers

Each one covers the other's blind spot.

| | shell layer | auditd |
|---|---|---|
| `cd`, `export`, redirections | **yes** — no `execve` happens, so auditd structurally cannot see these | no |
| The line as typed, incl. `FOO=bar cmd`, aliases | **yes** | argv only |
| Exit status | **yes**, real `$?` | no |
| `sudo su -` → who was it really | heuristic (see below) | **yes**, `auid` is stamped at login and immutable |
| Survives `PROMPT_COMMAND=` | no | **yes** |
| Survives kernel/root tampering | yes | no (`-e 2` is reboot-only) |

Comparing them per session converts "we hope the shell hook was loaded"
into a measured number. That comparison is what `cmdscribe-reconcile`
will do; today it is a documented spec.

## Architecture: two orthogonal axes

Capture depends on the **shell**. Attribution and shipping depend on the
**OS**. These are independent, so they are separate directories:

```
lib/
  capture/          one file per SHELL  (how to intercept a command line)
    bash.sh           PROMPT_COMMAND + history 1
    zsh.zsh           preexec + precmd
  os/               one file per OS     (how to answer "who am I really")
    linux.sh          /proc ancestor walk
    darwin.sh         ps(1) ancestor walk (no /proc)
    bsd.sh            ps(1), UNTESTED
  emit.sh           record format, shared by everything
entry.bash          picks the OS layer, then wires up the bash hook
entry.zsh           picks the OS layer, then wires up the zsh hook
```

So the answer to "does the Linux code work on a Mac running bash?" is:
**yes** — bash on macOS reuses `capture/bash.sh` and swaps in
`os/darwin.sh`. Adding FreeBSD is one new `os/` file. Adding fish is one
new `capture/` file. Nothing is duplicated across the axes.

This separation is not cosmetic. `sed -e 's/[0-9]\+//'` is correct on GNU
and **silently does nothing** on BSD sed — it parses fine and leaves the
history number in every record. That bug is only reachable if you assume
"Linux" and forget that bash also runs elsewhere, which is exactly what
the first draft of this did.

## Support matrix

| | bash | zsh |
|---|---|---|
| **Linux** | verified — Debian 13, bash 5.2, installed + login shell | verified — Debian 13, zsh 5.9, installed + login shell |
| **macOS** | verified — macOS 27.2, bash 3.2, installed + login shell | verified — macOS 27.2, zsh 5.9, installed + login shell |
| **BSD** | should work, untested | should work, untested |

"Installed" is doing real work in that table. Every macOS result earlier in
this project's history came from sourcing the entry file out of a checkout,
which never exercises where the runtime actually lives — and that is exactly
where macOS bites. `/usr` sits on the SIP-sealed read-only system volume, so
`mkdir /usr/share/cmdscribe` fails with `EPERM` **as root**. The runtime
installs to `/usr/local/share/cmdscribe` there, and the entry files now
locate themselves from their own path instead of trusting a hardcoded
default.

`make check` runs the acceptance matrix against whatever shells are
installed locally. `tests/integration.sh` runs against a real host over
ssh and skips shells that are not installed rather than reporting them as
failures.

The BSD cells say *should work* rather than *works*: `lib/os/bsd.sh` uses
the same `ps(1)`-based attribution as the macOS layer that passes, and
nothing in it is Linux-specific, so there is no reason to expect trouble.
But no BSD has ever executed it, and "there is no reason to expect
trouble" is exactly the kind of sentence that has been wrong about
portability all the way through this project. Treat it as untested until
someone runs `tests/integration.sh` on a BSD box.

One thing the automated suite does **not** cover: attribution through
`sudo su -`. It was verified by hand (see below) but reproducing it
automatically needs a non-root account with passwordless sudo, which is
not a reasonable thing to assume about someone else's host. It reports
`SKIP` rather than pretending.

## Install

```sh
./install.sh              # shell layer + system log sink
./install.sh --auditd     # also the auditd rules (Linux)
./install.sh --logfile    # also a plain file to tail (macOS)
```

Then open a **new** shell and:

```sh
tail -f /var/log/cmdscribe.log
```

On macOS there is no rsyslog; records go to the unified log via
`logger(1)`. Note the predicate:

```sh
log stream --style compact \
  --predicate 'eventMessage CONTAINS "cmdscribe: login="'
```

Or after the fact: `log show --last 1h --style compact --predicate '...'`.

Do **not** add `--level debug` to `log show`. Measured on macOS 27.2, that
variant returns **zero rows** where the same command without it returns 26.
`--debug` is fine, plain is fine, `--level debug` is not. It fails by
looking like an idle machine, which is the worst way for a query to fail.

Also note that on macOS these records are readable by **any** local user,
because the unified log is not access-controlled the way a `0600` file is.
See [SECURITY.md](SECURITY.md).

### Getting a file to tail on macOS

There is no `/var/log/cmdscribe.log` on a default macOS install, and no
syslog configuration will create one: `logger(1)` posts to the unified log
and never reaches syslogd's asl file routing. (A rule matching
`Facility local0` captured 41 unrelated lines and none of cmdscribe's.)

`./install.sh --logfile` makes the shell append a plain file itself:

```sh
sudo tail -f /var/log/cmdscribe.log
```

Read the caveat before using it: the shell writes that file directly, so
anyone who can type can also truncate it. It is a convenience copy for
eyeballing, not the record of authority — the unified log is. On Linux this
option is ignored on purpose, because rsyslog already writes the same path
as root at `0600`, which is strictly better than a file the subject of the
log appends to themselves.

Not `process == "cmdscribe"`. macOS `logger(1)` **discards the `-t` tag**,
so the record is filed under `process=/usr/bin/logger` and that predicate
matches nothing — which reads as "nobody ran anything" rather than "your
query is wrong". The marker is therefore carried in the message body, and
on Linux rsyslog already puts the tag in the line, so the same search
string works on both.

## What it does not capture

Deliberately, and worth knowing before you rely on it:

- **Keystrokes.** auditd's `CONFIG_TTY`/`AUDIT_TTY` records `write()` to
  the tty, not reads, so it cannot reconstruct a password prompt.
- **Passwords typed at prompts.** Same reason. `mysql -pSecret` in argv is
  captured; `mysql -p` then typing it is not.
- **Environment variables.** The kernel does not store `envp` in an exec
  record — there is no `envp` field in `kernel/auditsc.c` at all.
- **Non-interactive shells.** By design: cron, `ssh host cmd`, pipes,
  scripts. auditd covers those via `auid`; the shell layer does not.

## Attribution through `sudo su -`

`whoami` says `root`. `$SUDO_USER` is gone — `su -` wipes the environment.
`logname` *also* says `root`, because sudo's `use_pty` allocates a fresh
pts and `su -` writes its own utmp entry.

So the shell layer walks `/proc` (or `ps` where there is no `/proc`) to
find the nearest non-root ancestor uid. It is a heuristic, and it is
presented as one: `cmdscribe-reconcile` exists to measure how often it
agrees with auditd's `auid`, which is the answer that is actually
defensible.

## Limits you must accept

1. **Secrets in argv are recorded.** `mysql -pHunter2 prod` lands in the
   log verbatim, in both layers. There is no redaction in v1 — patterns
   like `--password=.*` also eat legitimate SQL and produce a log that
   silently misses. The policy is: never put secrets in argv.
2. **The shell layer is disableable by anyone with a shell**
   (`PROMPT_COMMAND=`). That is what the auditd layer and the
   `cmdscribe_tamper` watches are for.
3. **`fileCreateMode="0600"` is not optional.** Without it rsyslog creates
   the log world-readable and hands every command typed on the box to
   every local user. Same trap for logrotate, which needs
   `create 0600 root root`.

## Uninstall

```sh
./uninstall.sh
```

Removes the hooks (restoring the `.bak` taken before editing) and the
runtime. Leaves `/var/log/cmdscribe.log` alone, because that log is
evidence.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).

Chosen so that a cloud vendor cannot take this, add a hosted dashboard,
and ship it back as a closed product. The trade-off is honest and worth
knowing before you adopt it: some enterprise open-source policies refuse
GPL outright, more readily than they refuse GPL. For a tool whose whole
purpose is being installed inside other people's servers, that is a real
cost of the protection.
