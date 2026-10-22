# Changelog

## [1.2.0] - 2026-10-22
### Added
- Debian CI matrix: the full offline test-suite plus a live audit on Debian 12 (bookworm)
  and Debian 13 (trixie), alongside the existing Ubuntu and RHEL-family jobs.

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
