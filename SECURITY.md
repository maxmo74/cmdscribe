# Security policy

## Threat model

cmdscribe is an **accountability** tool. It answers "who did what on this
machine, and can I defend that answer?" It is not an intrusion prevention
tool and it does not stop anything.

Assume the attacker already has a shell.

### Who this does defeat

| Adversary | Why it fails |
|---|---|
| Casual local user poking at `/root` | recorded, with attribution |
| Someone who `history -c` and leaves | the shell layer already shipped the record; auditd has it independently |
| Someone who unsets `PROMPT_COMMAND` mid-session | auditd still records every `execve` with an immutable `auid`; the gap shows up as a `silent-shell` discrepancy |
| Someone who edits the hook to hide future sessions | `cmdscribe_tamper` watches on `/usr/share/cmdscribe`, `/etc/rsyslog.d/`, `/etc/audit/rules.d` |

### Who this does not defeat

| Adversary | Why |
|---|---|
| root, today | root can `auditctl -e 0`, `> /var/log/cmdscribe.log`, unload modules. `-e 2` freezes rules until reboot and is the only real mitigation — and it costs you live rule changes and fast incident response |
| root with physical access, or reboot rights | can boot with `audit=0`, or simply drop the disk |
| anyone, for a kernel exploit | no auditd on the planet helps |
| anything on a container/host you do not control | the shell layer may work; auditd almost certainly will not |

**The honest summary:** this raises the cost of misuse by people with
legitimate accounts, and gives you a defensible record after the fact. It
does not contain a determined root. Anyone telling you otherwise is
selling something.

## Ship it off-box, or the log is not evidence

A local-only log is the first thing anyone with a shell deletes. The
rsyslog config has a commented `omfwd` block — uncomment it. TLS, and a
collector you do not hand the attacker credentials to.

If the collector is on the same network as the fleet, an attacker who owns
one box may own the collector too. Put it on a separate trust boundary.

## File permissions

This is the most common real-world failure of this class of tool, and it
is worth stating bluntly:

> Logs of typed commands contain **credentials, private keys, and pasted
> secrets** — people run `cat id_rsa`, `cat auth.json`, and
> `mysql -pSecret` inside an interactive shell. A world-readable command
> log is a credential disclosure on every host you run it on.

Enforced in three places, all of which must stay:

- rsyslog: `fileCreateMode="0600"`, `dirCreateMode="0700"`
- logrotate: `create 0600 root root`
- newsyslog (BSD): mode field `0600`

`make check` does not cover this; `tests/integration.sh` asserts the mode
on an installed host. Verified on Debian 13: the log lands `0600
root:root`, and `sudo -u nobody cat` gets `Permission denied`.

### The log's owner is derived, not fixed

install.sh works out the account rsyslog actually runs as — the running process,
else the unit's `User=`, else `$PrivDropToUser` in `/etc/rsyslog.conf`, else
root — and the group that owns `/var/log`, then renders both the rsyslog rule and
the logrotate `create` line from them.

Hardcoding `root:root` was wrong on any distro where rsyslog drops privileges,
which includes Ubuntu. logrotate runs as root and would create the rotated file
`root:root 0600`; rsyslog, running as `syslog`, cannot reopen a file it does not
own, so **logging would stop at the first rotation** and nothing would report it.

On Ubuntu the log is therefore `syslog`-owned, and the consequence for you is
narrow but real: **the rsyslog service account can read your command log**, and on
Debian it cannot. Mode stays 0600 in every case, so the group carries no access at
all — the readers are the owner and root, and no confidentiality was traded to fix
the rotation bug. If the service account reading your log matters in your
environment, put the log on a group you control or ship it off-box; the collector
stanza is in `platform/linux/10-cmdscribe.conf`.

`ci/install-smoke.sh` asserts the mode unconditionally and asserts owner and group
against values it derives from the host itself, independently of install.sh, so the
test cannot simply agree with the installer's mistakes.

### macOS has none of this protection

On macOS the records go into the **unified log**, which any local user can
read. Verified from an ordinary uid-501 account: `log show --predicate
'eventMessage CONTAINS "cmdscribe: login="'` returned every record. There
is no `0600` to set because there is no file.

So the confidentiality this project has on Linux **does not exist on
macOS**, and no `fileCreateMode` will fix it. What macOS gets is
attribution and a record of what ran, not secrecy. Do not put cmdscribe on
a shared Mac and tell yourself the command history is private.

There is no asl mitigation, and an earlier version of this document
recommended one. It does not work -- see below.

**That mitigation does not work, and was removed as an option.** Tested on
macOS 27.2: `logger(1)` posts to the unified log and never reaches syslogd's
asl file routing at all. A rule matching `Facility local0` wrote 41 lines to
the target file and not one of them was ours. There is no asl
configuration that produces a cmdscribe file on this macOS.

`./install.sh --logfile` is the alternative, and it is weaker in a specific
way: the shell appends the file itself, so the subject of the log can
truncate it. It is created `0660 root:admin`, which on a Mac means every
administrator can read **and erase** it. Treat it as a convenience copy for
looking at output. The unified log stays the record of authority — which,
again, is already world-readable, so the file adds no new exposure, it just
adds no new protection either.

## Secrets in argv are recorded. This is not a bug you can fix.

Both layers capture argv. Therefore:

```
mysql -pHunter2 prod          # recorded, both layers
ansible-vault view secrets    # recorded (the filename, not the contents)
cat /root/.ssh/id_rsa         # recorded (the command, not the key)
mysql -p                      # nothing recorded; typed at a prompt
```

There is **no redaction in v1**, deliberately. Patterns such as
`--password=.*` also match legitimate SQL and internal tokens, and a
redactor that silently over-matches produces an audit log with holes in
it — worse than one that is honest about containing secrets.

Policy instead of code: **never put secrets in argv.** Use
`--defaults-extra-file`, `--password-from-stdin`, vault CLI, env files
with `0600`.

If you need redaction, make it fail *loudly*: log the match, keep the
original in a `0600` file, and alert.

## Reporting a vulnerability

Open a GitHub issue for anything that is already publicly visible in the
design (e.g. "the shell layer can be disabled"). For anything that would
help an attacker before the fix ships, use a private security advisory.

No embargo, no bounty, no formal SLA — this is a pre-1.0 project by one
person. If you need a support commitment, this is not that.

## Known limitations, stated plainly

1. `cmdscribe-reconcile` is a **specification, not code**. Until it
   exists, the two layers do not actually cross-check each other and the
   "self-verifying" claim is aspirational. Do not cite this project as
   evidence of coverage until that tool ships.
2. `lib/os/bsd.sh` **should work and has never been run**. It shares the
   `ps(1)` attribution approach that passes on macOS and contains nothing
   Linux-specific, but "should" is doing all the work in that sentence.
3. Attribution through `sudo su -` is **verified by hand, not by the
   automated suite**. `capture/zsh.zsh` and `capture/bash.sh` are each
   verified on Linux and macOS; `os/bsd.sh` is verified on nothing.
4. On macOS there is **no tamper-resistant second layer**. Apple's
   EndpointSecurity API requires an entitlement granted only to approved
   organisations. macOS cmdscribe is single-layer and therefore weaker
   than the Linux version, whatever the platform marketing says.
5. The `sudo su -` attribution heuristic is unmeasured. It has been
   observed to work; nobody has counted how often it is right.
6. A command typed **before the shell finishes starting up can be missed**.
   The hook is installed by the rc files, so anything executed while they are
   still being read predates the hook. This is not hypothetical: the test
   harness slept a fixed 0.5s after forking and then typed, and on a loaded
   GitHub Actions runner the first command of the session was lost every time
   while a quiet Debian box never showed it — the signature of a race, not of
   a product defect, but the product defect is the same one. A human typing
   during a slow `ssh` connect is in exactly this window. It is milliseconds
   wide and not zero, and anyone who can slow shell startup — a hung `sssd`
   behind `pam_loginuid`, a dead NFS mount holding up `/etc/profile` — can
   widen it at will. The shell layer cannot close this by construction; the
   kernel layer sees the `execve` regardless, which is the honest argument for
   running both.
7. **A bash session could previously record a command it never ran.** The hook
   read the typed line with `history 1`, and at a session's first prompt that
   can still be the last line loaded from `HISTFILE` — a command from some
   *earlier* session — written out with this session's pid, tty and timestamp.
   Observed directly in CI: a session recorded `exit`, which it cannot have
   run, because `exit` ends the shell before `PROMPT_COMMAND` fires. A missing
   record loses information; this one manufactured it.

   Fixed by seeding a history-number baseline at the first prompt and emitting
   nothing at it; entries at or below the baseline are not attributed to this
   session. `ci/install-smoke.sh` step 3c is the regression test — it plants a
   canary line in `HISTFILE` that the session never types and fails if that
   canary ever appears in the session's records. Note the earlier attempt at
   this seeded the baseline at *install* time, which is inside `/etc/profile.d`
   and therefore before bash has read `HISTFILE`: always 0, suppressing nothing.
   A fix that passes review and does nothing is still a fix that does nothing.
8. **The first record written into a newly created log file can be silently
   dropped.** Seen on Ubuntu runners; Debian does not show it. rsyslog opens the
   file lazily on first write and the record that triggers the open does not
   always land, so the first command after install — and the first command after
   anything recreates the file — may simply be absent, with nothing in the log
   marking a gap.

   `ci/install-smoke.sh` now warms the file before probing, which is why the
   suite is green; **the underlying behaviour is not fixed.** The mechanism is
   not fully established. What is known, because each of these was tested: it is
   not the shell hook (no change to it moved the behaviour, across four commits
   that assumed otherwise), not the inherited environment (scrubbing changed
   nothing), and not bash history state — creating the file first makes it
   disappear entirely, which is the only thing that has.

   The general lesson is in `history` anyway: the bash layer reads the typed line
   out of a mutable list and can lose a session's first command without the log
   saying so. The kernel layer sees the `execve` either way.

9. **Rotation silently killed logging on every distro, one week after install.
   Fixed, and verified with a negative control on two hosts.**

   The logrotate stanza had no `postrotate` and no `copytruncate`. Nothing ever
   told rsyslog to reopen the log, so after the first rotation rsyslog kept
   writing to the rotated inode and the live file stayed empty **permanently**.
   The stanza said `weekly`, so on every host that installed this before today,
   auditing stopped seven days later and nothing anywhere reported it. The host
   keeps looking instrumented. This is the most serious defect found in this
   project, and it survived every test that existed because no test rotated a log.

   Measured, not inferred. Ubuntu 24.04 LTS: after rotation, `rsyslogd` held fd 9
   pinned to `cmdscribe.log.1`, the post-rotation marker appeared in `.1`, and the
   live log held zero records. Debian 13: identical. Adding a `postrotate` that
   sends rsyslog `HUP` makes the marker land in the live log on both. Removing it
   again — the negative control, run on both hosts — reproduces the dead log. So
   the stanza is what fixes it and the test is what detects it.

   **Debian's earlier green was luck.** An earlier version of this suite reported
   "captured through rotation" on Debian while the same defect was present,
   because it asserted on a file rsyslog was still writing to rather than on the
   file that would exist next week. A test that passes on a broken system is worse
   than no test, and this one was shipped.

   Two things that looked like the bug and were not:

   - `fileOwner`/`create` set to `root:root` on Ubuntu, where rsyslog runs as
     `syslog`. Real, and separately fixed by deriving the owner — but rotation
     still died with the owner fixed and no `postrotate`.
   - logrotate's "parent directory has insecure permissions" refusal. On Ubuntu
     `/var/log` is `0775 root:syslog` and logrotate refuses every snippet invoked
     directly, **including the distro's own**, which is what a control in CI
     observed. The reason it is not a problem in production is that Ubuntu's
     `/etc/logrotate.conf` carries a global `su root adm` and the production
     command is `logrotate /etc/logrotate.conf`, which includes the snippets and
     applies it. Testing the snippet standalone tests the wrong command line; the
     suite now reproduces the real one. That control was run as root and reported
     accurately — the error was interpreting "the distro's own config fails too"
     as exoneration instead of as a sign the harness was invoking something the
     distro never invokes.