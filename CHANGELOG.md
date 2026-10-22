# Changelog

## [1.3.0] - 2026-10-22
### Added
- Audit checks STO-001 (fstab validity), STO-002 (`nofail` on secondary mounts, fixable), STO-003 (software RAID health), STO-004 (LVM free space, snapshot and thin-pool fullness), CRN-001 (world-writable scripts run by system cron, fixable with rollback), CRN-002 (root cron running from /tmp or `curl|sh`), CRN-003 (cron.allow present, fixable).
- Monitor metrics: `raid_degraded`, `raid_failed`, `vg_used:VG`, `lv_snap:VG/LV`, `thin_data`, `thin_meta`, `lvm_missing_pv`, with recovery notices.
- Real drills (`tests/storage-live.sh`): md RAID1 degrade and rebuild, LVM snapshot overflow, VG 100% allocated, live `/etc/cron.d` hygiene including `hk fix` and rollback.
### Honest limits
- STO-003/004 only run on a live system with mdadm/lvm2; elsewhere they are skipped, not passed. Real LVM drills ran on Ubuntu and Debian 12 only; in the other distro containers device-mapper is not usable so they are skipped (RAID and cron drills still run).

## [1.2.0] - 2026-10-22
### Added
- Debian CI matrix: the full offline test-suite plus a live audit on Debian 12 (bookworm)
  and Debian 13 (trixie), alongside the existing Ubuntu and RHEL-family jobs.
- Real failure drills in the live-root CI job: a real filesystem (ext4 on a loop device)
  filled past 90% must trigger a CRIT disk alert (and no alert after cleanup), and a
  hand-broken sshd drop-in must trigger hk's config validation and automatic rollback.

## [1.1.0] - 2026-10-22
### Added
- Rocky Linux 9 CI job: full offline test-suite plus a live audit on a RHEL-family system.
- Alert-channel delivery tests: webhook, Telegram and mail channels are now proven against
  local mock servers (5 new tests, 37 total). `HK_TELEGRAM_API` env override added so the
  Telegram endpoint can be pointed at a mock in tests (production default unchanged).
- INTERVIEW.md: 60-second pitch, architecture, design choices, 10 interview Q&A.
- Demo GIF in the README (rendered from real command output).
- Release badges, 60-second tour section in the README.

## [1.0.0] - 2026-10-22
- Initial public release: 43-check audit with 0-100 score and grade, safe fixes (dry-run,
  transactions, byte-identical rollback, anti-lockout guard, drop-in configs), drift
  detection, flap-suppressed monitoring with Prometheus export, HTML/JSON reports.
- CI: ShellCheck, offline suite, real-root Ubuntu job.
