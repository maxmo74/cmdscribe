# Security policy

## Threat model

cmdscribe is an **accountability** tool. It answers "who did what on this machine, and can I defend that answer?" It prevents nothing. Assume the attacker already has a shell.

**Defeats:**

| Adversary | Why it fails |
|---|---|
| Casual local user poking at things they shouldn't | recorded, with attribution |
| Someone who runs `history -c` and leaves | the record was already written; auditd has it independently |
| Someone who unsets `PROMPT_COMMAND` mid-session | auditd still records every `execve` with an immutable `auid` |
| Someone who edits the hook to hide future sessions | auditd watches on `/usr/share/cmdscribe`, `/etc/rsyslog.d/`, `/etc/audit/rules.d` |

**Does not defeat:**

| Adversary | Why |
|---|---|
| root, today | root can `auditctl -e 0` or truncate the log. `-e 2` freezes rules until reboot — the only real mitigation, and it costs you live rule changes |
| root with physical access or reboot rights | can boot with `audit=0`, or take the disk |
| a kernel exploit | nothing here helps |
| a container or host you do not control | the shell layer may work; auditd almost certainly will not |

**In short:** this raises the cost of misuse by people with legitimate accounts and gives you a defensible record afterwards. It does not contain a determined root. Anyone telling you otherwise is selling something.

## Report a vulnerability

- **GitHub issue** for anything already visible in the design (e.g. "the shell layer can be disabled").
- **Private security advisory** for anything that would help an attacker before a fix ships.

Pre-1.0, maintained by one person: no embargo process, no bounty, no SLA. If you need a support commitment, this is not that project.

## Handling of secrets

**Both layers record argv.** There is no redaction, deliberately: patterns like `--password=.*` also match legitimate SQL and internal tokens, and a redactor that silently over-matches produces an audit log with holes in it — worse than one that is honest about containing secrets.

```
mysql -pHunter2 prod        # recorded, both layers
cat /root/.ssh/id_rsa       # recorded (the command, not the key)
mysql -p                    # not recorded; typed at a prompt
```

Policy, not code: **never put secrets in argv.** Use `--defaults-extra-file`, `--password-from-stdin`, a vault CLI, or a `0600` env file.

If you do need redaction, make it fail loudly: log the match, keep the original in a `0600` file, alert.

## File permissions

> A log of typed commands contains **credentials, private keys and pasted secrets** — people run `cat id_rsa`, `cat auth.json`, and `mysql -pSecret` in interactive shells. A world-readable command log is a credential disclosure on every host that has one.

Enforced wherever the log can be created:

- rsyslog: `fileCreateMode="0600"`, `dirCreateMode="0700"`
- logrotate, if you opt in with `--rotate`: `create 0600`, owner derived from the host
- newsyslog (BSD): mode field `0600`

The mode is asserted in CI on every push, on Linux and macOS.

**The log's owner is derived from the host, not hardcoded.** The installer determines the account rsyslog actually runs as (running process → unit `User=` → `$PrivDropToUser` → root) and the group that owns `/var/log`. Hardcoding `root:root` breaks on any distro where rsyslog drops privileges: on Ubuntu that means logrotate creates a rotated file rsyslog cannot reopen, and logging stops at the first rotation with no error anywhere.

Consequence, narrow but real: **on Ubuntu the rsyslog service account can read your command log.** On Debian it cannot. Mode stays `0600` either way, so the group carries no access. If that matters in your environment, ship the log off-box.

### macOS has none of this protection

On macOS the records go into the **unified log**, which any local user can read — verified from an ordinary unprivileged account. There is no `0600` to set because there is no file.

macOS cmdscribe therefore gives you attribution and a record of what ran, **not secrecy**. Do not put it on a shared Mac and assume the command history is private. `--logfile` does not fix this: the shell appends that file itself, so the subject of the log can truncate it, and it is `0660 root:admin` — every administrator can read and erase it. Treat it as a convenience copy; the unified log is the record of authority.

## Ship it off-box, or the log is not evidence

A local-only log is the first thing anyone with a shell deletes. The rsyslog config has a commented `omfwd` block in `platform/linux/10-cmdscribe.conf` — uncomment it. Use TLS, and put the collector on a separate trust boundary from the fleet: an attacker who owns one box may otherwise own the collector too.

## Known limitations

1. **`cmdscribe-reconcile` is not implemented.** Until it exists the two layers do not actually cross-check each other, so do not cite this project as evidence of verified coverage.
2. **`cmdscribe --check` does not exist yet.** Nothing currently tells you whether capture is still working on a host you installed weeks ago. Config-management changes, distro upgrades and package updates can break capture silently. This is the top item on the roadmap.
3. **A command typed in the first milliseconds of a session can be missed.** The hook is installed by the rc files, so anything run while they are still being read predates it. The window is normally milliseconds; a slow `ssh` connect or a hung `sssd` behind `pam_loginuid` widens it. The kernel layer sees the `execve` regardless.
4. **The first record written into a newly created log file can be dropped.** Observed on Ubuntu, not on Debian. rsyslog opens the file lazily on first write and the record that triggers the open does not always land, with nothing in the log marking a gap. Not fixed.
5. **Anyone with a shell can disable the shell layer** (`PROMPT_COMMAND=`). Intended design: that is why the auditd layer exists.
6. **On macOS there is no tamper-resistant second layer.** Apple's EndpointSecurity API requires an entitlement granted only to approved organisations, so macOS cmdscribe is single-layer.
7. **`sudo su -` attribution is a heuristic.** It walks `/proc` (or `ps`) for the nearest non-root ancestor uid. It has been verified by hand and is not measured — nobody has counted how often it is right.
8. **BSD is untested.** `lib/os/bsd.sh` shares the `ps(1)` attribution that passes on macOS and contains nothing Linux-specific, but no BSD has ever executed it.
9. **Non-interactive shells are not captured** — by design. Cron, `ssh host cmd`, scripts and daemons are invisible to the shell layer. Use `--auditd` on Linux if you need them.
10. **Rotation is opt-in because its failure mode is silent.** Without a `postrotate` that sends rsyslog `HUP`, rsyslog keeps writing to the rotated inode and the live log stays empty permanently while the host looks instrumented. The default install writes no logrotate config at all. If another config on your host — a distro baseline or a config-management glob — starts matching `/var/log/cmdscribe.log`, it can reintroduce that silent failure, so check after changing anything that touches logrotate.
11. **`--auditd` requires the `audit` package.** If it is missing the installer now fails and says so; earlier versions reported success without installing any kernel-layer rules. Verify with `sudo auditctl -l | grep cmd` after installing.

## Verified platforms

| | bash | zsh |
|---|---|---|
| Debian 13 | tested | tested |
| Ubuntu 24.04 | tested | tested |
| Rocky Linux 9 (RHEL family) | tested | tested |
| macOS | tested (bash 3.2) | tested |
| other Linux (Fedora, openSUSE) | should work, untested | should work, untested |
| BSD | should work, untested | should work, untested |

macOS install paths are covered by their own CI job, which runs the installer as root, checks the runtime lands in `/usr/local/share` rather than the SIP-sealed `/usr/share`, asserts records reach the unified log via the query this project documents, and verifies uninstall restores the rc files byte-identically while keeping the log.

If you deploy on an unlisted distribution and it works — or doesn't — please open an issue either way. That is currently the only way this table improves.
