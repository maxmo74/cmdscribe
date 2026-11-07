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
8. zsh is not subject to 7 in the same way: `preexec` is event-driven rather
   than a poll of `history`. The bash layer's claim about its own **first**
   record of a session is the weakest thing it says, because that record is read
   out of a mutable list that anything in the shell can change between prompts.

   This is not hypothetical, and the honest version of what was observed: on the
   GitHub Actions runner, in the first bash session after install, the first
   command of every session went unrecorded while every later command was
   captured normally. **The cause is not established.** It does not reproduce on
   Debian or macOS, with `HISTFILE` present or absent; scrubbing the inherited
   environment does not change it; and it is confined to the first session, which
   is the one thing that ruled out in sequence was not. What the case
   demonstrates regardless of cause is the structural point: whatever the
   mechanism, the bash layer can lose a session's first command and the log will
   not mention that it did. The kernel layer sees the `execve` either way.
