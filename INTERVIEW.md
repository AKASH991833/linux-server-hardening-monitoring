# INTERVIEW.md - how to explain this project (hk)

The 60-second pitch, the architecture, the design choices a hiring manager will ask about,
and 10 questions with strong answers. Everything here matches the code and the test suite.

## The 60-second pitch

"hk is a Bash tool that audits a Linux server against 43 security checks and gives it a
0-100 score, fixes the failures *safely* - dry-run first, every change backed up, one-command
rollback, and an anti-lockout guard for SSH - remembers a known-good baseline and tells you
when the server drifts from it, and monitors health with alert flap-suppression. It also runs
offline against a mounted disk image, which is how the test-suite checks everything without
root. CI proves it on Ubuntu (including a real-root run that applies and rolls back fixes)
and on Rocky Linux 9."

## Architecture

```
hk (the only entry point, ~150 lines of dispatch)
 |- checks/10-ssh.sh 20-accounts.sh 30-files.sh 40-kernel.sh 50-services.sh
 |     each check = one register() line + chk_<ID>() [+ optional fix_<ID>()]
 |- lib/common.sh    colors, rp() (root-prefix path resolver), config loading, JSON escaping
 |- lib/tx.sh        fix transactions: backup -> apply -> sshd -t validation -> rollback
 |- lib/report.sh    text / JSON / self-contained HTML report + score history
 |- lib/baseline.sh  sha256 snapshots + SUID list + users + listening ports -> drift diff
 |- lib/monitor.sh   metric collection, threshold state machine, alert channels, Prom export
tests/               fixture builder ("insecure" and "hardened" fake servers) + 37 tests
.github/workflows    Ubuntu suite, real-root Ubuntu run, Rocky Linux 9 suite + live audit
```

The one idea everything hangs on: **every path goes through `rp()`** (`--root DIR` support).
A check never touches `/etc/...` directly; it touches `"$R/etc/..."`. That single decision gives
offline audits of disk images *and* a test-suite that needs no root, no VM, no Docker.

## Design choices (and why)

1. **Pure Bash, zero dependencies.** The target is a freshly installed minimal server where you
   cannot assume Python. Everything is bash + coreutils.
2. **Fixes as drop-ins, not edits.** SSH and sysctl hardening go into `99-hk-hardening.conf`
   drop-ins. The vendor file stays untouched: package upgrades never conflict, and rollback is
   "remove the drop-in" instead of "hope the edit reverses".
3. **Transactions with real backups.** Before a file is changed, its content + mode + owner are
   saved under `$STATE/tx/<id>/`. Rollback replays them. The test proves the tree is
   *byte-identical* after rollback (content, permissions, owner).
4. **Anti-lockout as a hard refusal, not a warning.** Disabling password auth without any user
   `authorized_keys` is the classic way admins lock themselves out. hk refuses, and on a live
   host it validates with `sshd -t` before reloading and auto-rolls-back if sshd rejects it.
5. **sshd config parsed the way sshd parses it.** First value wins, `Include` expanded in place,
   `Match` blocks skipped for the global value - otherwise the audit answers about a config
   sshd would not actually use.
6. **Weighted scoring.** critical=10, high=6, medium=3, low=1, normalized to 100 with a grade.
   JSON + `--min-score` makes it a CI/CD gate, not just a report.
7. **Flap-suppression state machine.** A metric must breach N consecutive times before the first
   alert; while the level is unchanged it stays silent; CRIT re-reminds only after a cooldown;
   recovery sends one RECOVERED message. State lives in a small TSV so restarts don't reset it.
8. **Secrets out of config.** The Telegram token is read from a root-only file path, never from
   `hk.conf` or the environment of a process list.

## 10 interview Q&A

**1. What happens, step by step, when I run `hk fix --apply --all`?**
All 43 checks run. For each FAIL with a `fix_` function: a transaction starts, the target file is
backed up (content/mode/owner), the fix is applied - drop-in for sshd/sysctl, direct edit for
things like shadow permissions - and if sshd was touched on a live host, `sshd -t` must pass or
the whole transaction rolls back automatically. It prints the transaction id for `hk rollback`.

**2. How do you guarantee I can't lock myself out of SSH?**
Two independent guards. Before: SSH-002 (disable password auth) refuses unless at least one
real user has an `authorized_keys` file. After: on a live host the new drop-in is validated with
`sshd -t`; a rejection triggers automatic rollback and sshd is never reloaded with a bad config.

**3. How exact is the rollback?**
Byte-identical. The test suite snapshots the fixture tree (paths, modes, owners, sha256 of every
file) before `fix --apply` and after `rollback` and compares them. The live-root CI job does the
same on a real Ubuntu VM, comparing the full audit result before and after rollback.

**4. How does drift detection work, and what are its limits?**
`hk baseline create` stores sha256 of security-critical files, the SUID/SGID list, login users
and listening ports. `hk drift` diffs and prints CHANGED/ADDED/REMOVED with exit code 1.
Limits: it's user-space - a rootkit can lie to it; the baseline must be protected (read-only,
off-host copy) to be trustworthy.

**5. Why drop-in files instead of editing `/etc/ssh/sshd_config`?**
Because "first value wins" in sshd - a drop-in in `sshd_config.d/` can win without touching the
vendor file. Package upgrades that rewrite `sshd_config` never destroy your hardening, and
rollback is deletion, not a risky reverse-edit.

**6. How is the score computed and why weight it?**
Each check has a severity with a weight (10/6/3/1). Score = passed weight / total weight x 100,
grade A-F. A flat count would treat "telnet installed" and "banner missing" as equal; they are
not. `--min-score 80` exits 1 below threshold so CI can gate a deploy on it.

**7. How do alerts avoid spamming?**
A three-state machine per metric (OK -> Pending -> Alerted) plus a cooldown. First breach only
increments a counter; N consecutive breaches fire once. While still CRIT it re-fires at most
once per `HK_COOLDOWN_MIN`. One RECOVERED message when it clears. The tests cover blips
(no alert), duplicates (suppressed), cooldown and recovery.

**8. How is it tested?**
37 automated tests over offline fixtures: scoring, JSON validity, sshd first-match/Match
handling, dry-run changes nothing, anti-lockout refusal, apply raises the score, drop-in wins,
byte-identical rollback, drift on a changed key/new SUID/new user, the full alert state machine,
Prometheus output, and mock HTTP servers proving the webhook, Telegram and mail channels really
deliver. ShellCheck is clean. CI runs the suite on Ubuntu and Rocky 9, plus a real-root Ubuntu
job that applies and rolls back fixes on a live VM.

**9. What are the honest limits?**
It is not a CIS/OpenSCAP replacement: 43 opinionated checks, not 300 benchmark rules. Live
fix/rollback is CI-verified on Ubuntu; on Rocky the audit and full suite are verified, the live
apply path is the same code but the CI live-root run is Ubuntu. User-space drift detection can be
defeated by a rootkit.

**10. What would you build next?**
Map each check to CIS benchmark IDs and emit a compliance matrix; OpenSCAP content import;
per-check `HK_SKIP` policy file; signed baselines; an agent mode that ships drift + metrics to a
central collector (the Prometheus textfile export is the first step).

## Storage and cron checks (v1.3.0)
**Why audit fstab and cron in a hardening tool?** A typo in fstab or a missing disk without `nofail` stops boot; a world-writable script run by root cron is a privilege escalation. Both are cheap to find.

**How is it tested without trusting fixtures?** Fixtures prove parsing. The real drill builds md RAID1 and LVM on loop devices, breaks them, and asserts the audit and the monitor alert, then recovers and asserts the RECOVERED notice.

**What does it not do?** STO-003/004 skip rather than pass when mdadm/lvm2 are absent. Container runs share the runner kernel, so real LVM drills ran on Ubuntu and Debian 12 only, other container distros skip them.

## Honest test status
See the README "Honest test report" - it is kept in sync with CI and names exactly what ran where.
