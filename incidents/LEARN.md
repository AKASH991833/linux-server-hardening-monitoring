# An incident from zero

An incident is a security problem with evidence, a timeline, an impact and a recovery plan. A log is evidence, not a complete report.

Run `./incidents/run.sh incident-output`. Open report.md, drift.txt and detected.json. This safe demo creates a disposable root filesystem, adds a fake key and harmless SUID file, detects them, removes privilege, demonstrates rollback, then removes the injected artifacts. SSH failures are synthetic log lines, not a real attack on a server. No credentials or real customer logs are included.

Rollback means undo our change. Recovery means return to a safe state. Those are different: rollback restores the SUID permission and would be unsafe during a real compromise. The demo checks that explicitly and then eradicates the fixture artifacts.

Exercise: explain which evidence came from audit, drift and monitoring. Write the missing real-world items: affected host, owner, business impact, first-seen time, confirmed access, evidence hashes and approval for recovery. Never scan or attack hosts without permission.
