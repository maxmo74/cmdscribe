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
- newsyslog (BSD/macOS): mode field `0600`

`make check` does not cover this; `tests/integration.sh` asserts the mode
on an installed host.

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
2. `lib/os/bsd.sh` is **untested**. No BSD has been used to run it.
3. Attribution through `sudo su -` is **verified by hand, not by the
   automated suite**. `capture/zsh.zsh` and `capture/bash.sh` are each
   verified on Linux and macOS; `os/bsd.sh` is verified on nothing.
4. On macOS there is **no tamper-resistant second layer**. Apple's
   EndpointSecurity API requires an entitlement granted only to approved
   organisations. macOS cmdscribe is single-layer and therefore weaker
   than the Linux version, whatever the platform marketing says.
5. The `sudo su -` attribution heuristic is unmeasured. It has been
   observed to work; nobody has counted how often it is right.
