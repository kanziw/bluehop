# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). Before 1.0.0, minor versions may contain breaking changes.

## [Unreleased]

## [0.5.2] - 2026-10-15

### Added
- A second, structured log: `~/Library/Logs/bluehop-events.jsonl`, one JSON object per line (timestamp, level, mapping, the relevant Telegram/chat.db correlation id), covering every step of a request — received, send start/end with its duration, echo wait/match/give-up, warning sent, reaction/attachment handling, `getUpdates` errors and retries, and start/halt/resume. It rotates itself by size (10 MB × 5 files). `bluehop status` and `doctor` now print both log paths and the active level. Levels are `info` (default) and `debug` (`BLUEHOP_LOG_LEVEL=debug`); message text, phone numbers, Apple IDs and the token are never written by default, and a couple of events can additionally carry text only when `BLUEHOP_LOG_BODIES=1` is set together with `debug`.
- `scripts/collect-logs.sh`: bundles both logs into a `.tar.gz` for a bug report (read-only, no Full Disk Access needed), dropping any line that the debug body opt-in may have added as a second line of defense.

### Fixed
- An osascript send that hit the internal time limit was treated as a definite failure right away. Killing osascript does not tell us whether Messages had already received and started acting on the request, so a send that actually went through could still get a false "couldn't send" warning. It is now held as unconfirmed for a grace period (`sendTimeoutGrace`, same length as the existing `confirmTimeout` by default) during which chat.db echo matching keeps trying; only if nothing matches by the end of the grace period does it fall back to the existing warning. No message is ever sent twice.

## [0.5.1] - 2026-10-15

### Fixed
- `--help` and `-h` win over everything else before `--`: after an unknown flag (`run --bogus --help`) and in the value slot of another flag (`run --config -h`), the command prints its help and exits 0 before doing anything. Before, `run --config -h` took `-h` as the config path and started the relay startup path.

## [0.5.0] - 2026-10-15

### Added
- **Several chats at once.** The config holds a list of mappings; each links one iMessage 1:1 chat to its own Telegram bot. One process runs one isolated worker per enabled mapping: own Telegram poller, rate limits, safety halt, cursors, echo matching and staging folder. A failing mapping (revoked token, network error, chat not found, safety halt) does not stop the others; it backs off and retries. chat.db changes for all mapped chats are detected with one grouped query.
- `bluehop mapping list|add|remove|pause|resume|test`. `mapping add` asks for the bot token with hidden input (or reads it from stdin with `--token-stdin`), checks it with `getMe`, lets you pick the iMessage chat with the arrow keys (numbered list on terminals without raw mode), detects your Telegram chat and user ids from a message to the bot, stores the token in the Keychain (`dev.kanziw.bluehop` / `bot-token:<id>`) and runs a check. Every value can also be passed as a flag for agents.
- `bluehop chats [--search] [--limit] [--json]`: local 1:1 chats with service, last activity and the mapping that uses them. No message content.
- `bluehop status [--json]`: per-mapping verdict (`ok`, `paused`, `halted`, `error`, `stale`, `unknown`), last Telegram poll, last error, and whether the LaunchAgent runs.
- `--help` on every command, `--json` on read commands, documented exit codes (0, 1, 2 usage, 3 conflict, 4 not found, 5 timeout, 130 cancelled), `--config PATH`.
- Config changes (add, pause, resume, remove) are picked up by the running relay within about five seconds.
- When the terminal has no Full Disk Access, `chats`, `doctor` and the chat picker re-run the read through a one-shot launchd job of the installed binary.
- Agent skill file `skills/bluehop/SKILL.md`, design note `docs/design-multi-mapping.md`.

### Changed
- **Breaking:** unknown flags and extra arguments are errors (exit 2) instead of being ignored.
- **Breaking:** `list-chats` is now an alias of `bluehop chats` and prints its table. Diagnostics (`resume`, `diag-*`, `selfcheck-attributed`, `telegram-ids`) take `--mapping ID`, required when there is more than one mapping.
- The state database keys every row by mapping. A 0.4 state database is migrated under the mapping `default` on first open, after a `state.sqlite.v1-backup` copy.
- Telegram attachments are staged in a per-mapping subfolder of the staging folder.
- `getUpdates` failures back off per mapping (3 s doubling to 60 s), including failures while taking the first Telegram baseline.
- `install.sh` no longer writes a single-chat config template; add the first chat with `bluehop mapping add`. `uninstall.sh --purge` removes every mapping's Keychain token.

### Compatibility
- A 0.4 config (top-level `telegram`, `imessage`, `relay`) works unchanged as the mapping `default`, still using the Keychain account `telegram-bot-token`. The first `bluehop mapping` command that changes something rewrites it in the version 2 shape and keeps `config.json.v1-backup`.


## [0.4.1] - 2026-10-15

### Changed
- **Breaking:** every runtime identifier now uses the project name. The binary is `bluehop` (Swift targets `BluehopCore` and `BluehopCLI`); it installs to `~/Library/Application Support/bluehop/bin/bluehop` and logs to `~/Library/Logs/bluehop.log`; attachments are staged in `~/Library/Caches/com.apple.MobileSMS/bluehop-outbox`; `dev.kanziw.bluehop` is the LaunchAgent label, Keychain service, signing identifier and bundle id. Script environment variables are `BLUEHOP_BIN` and `BLUEHOP_CODESIGN_IDENTITY`. macOS ties Full Disk Access and Automation to the binary's identity, so a 0.4.0 install has to be set up again with the new names (README "Install").

### Fixed
- The 0.4.0 changelog entry listed its "Changed" section twice.

## [0.4.0] - 2026-10-15

First public release of **bluehop**. Earlier versions were developed privately and have no public tags.

### Changed
- `/pause` records the halt reason as `/pause 로 멈춤`.
- `packaging/Info.plist` version now matches the CLI version.

### Added
- English README (primary) and Korean README, agent guide, security policy, llms.txt, MIT license.
- Contribution rules, changelog, issue and pull request templates.
- Versioned git hooks (`scripts/setup-dev.sh`): staged-change checks for secrets and personal data, Conventional Commits check, and build plus tests before push. A hosted CI template is kept disabled in `docs/ci-template/`.

## 0.3.2 - 2026-10-15

### Added
- `diag-audio` command to inspect audio attachment rows (metadata only). Relayed Telegram voice stays a plain audio attachment in iMessage.

## 0.3.1 - 2026-10-14

### Fixed
- Photos and files sent from Telegram failed with Messages error 25 because they were staged outside the Messages sandbox. They are now staged in a folder under `~/Library/Caches/com.apple.MobileSMS`, which Messages can read.

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

[Unreleased]: https://github.com/kanziw/bluehop/compare/v0.5.2...HEAD
[0.5.2]: https://github.com/kanziw/bluehop/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/kanziw/bluehop/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/kanziw/bluehop/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/kanziw/bluehop/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kanziw/bluehop/releases/tag/v0.4.0
