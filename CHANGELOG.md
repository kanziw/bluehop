# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). Before 1.0.0, minor versions may contain breaking changes.

## [Unreleased]

## [0.4.0] - 2026-10-15

First public release, under the project name **bluehop**. Versions before 0.4.0 were developed privately as imsg-relay and have no public tags.

### Changed
- The project is now called bluehop. The binary, Swift targets, install paths, log file, LaunchAgent label and Keychain service keep the `imsg-relay` / `dev.kanziw.imsg-relay` names for now; renaming them needs a migration that re-grants Full Disk Access, so it is a later, separate step.

### Added
- English README (primary) and Korean README, agent guide, security policy, llms.txt, MIT license.
- Contribution rules, changelog, issue and pull request templates.
- Versioned git hooks (`scripts/setup-dev.sh`): staged-change checks for secrets and personal data, Conventional Commits check, and build plus tests before push. A hosted CI template is kept disabled in `docs/ci-template/`.

### Changed
- `/pause` records the halt reason as `/pause 로 멈춤` instead of a personal form of address.
- `packaging/Info.plist` version now matches the CLI version.

## 0.3.2 - 2026-10-15

### Added
- `diag-audio` command to inspect audio attachment rows (metadata only). Relayed Telegram voice stays a plain audio attachment in iMessage.

## 0.3.1 - 2026-10-14

### Fixed
- Photos and files sent from Telegram failed with Messages error 25 because they were staged outside the Messages sandbox. They are now staged in `~/Library/Caches/com.apple.MobileSMS/imsg-relay-outbox`.

### Added
- `diag-send-file` command (really sends; for diagnosis only).

## 0.3.0 - 2026-10-14

### Fixed
- Echo matching failed for Korean text because Messages stores it in NFD; both sides are now normalized the same way.

### Removed
- The success reaction on relayed Telegram messages; only failures are reported.

## 0.2.0 - 2026-10-14

### Fixed
- Telegram messages sent before the first start were relayed; they are now skipped once with a notice.
- Telegram messages older than 10 minutes when processed are no longer sent.
- Multi-line text sent from Telegram was mirrored back as a duplicate because Messages stores line breaks as U+2028/U+2029; line breaks are now normalized, and a short grace period applies while a send is still unconfirmed.

## 0.1.0 - 2026-10-14

### Added
- First version: one iMessage 1:1 chat ↔ one Telegram chat, read-only chat.db reader, Telegram client, CLI (`run`, `doctor`, `telegram-ids`, `list-chats`, `resume`), signed build, LaunchAgent install scripts.

[Unreleased]: https://github.com/kanziw/bluehop/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/kanziw/bluehop/releases/tag/v0.4.0
