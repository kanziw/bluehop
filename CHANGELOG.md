# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/). Before 1.0.0, minor versions may contain breaking changes.

## [Unreleased]

## [0.5.6] - 2026-10-18

### Added
- `bluehop notify [--mapping ID|--all] (--text TEXT|--text-stdin) [--json]`: sends one Telegram message to a mapping's chat (or every mapping) with that mapping's own token, read from the Keychain or token file the same way every other command reads it. A trusted caller of the installed binary (for example a `launchd`-run watchdog) can now notify over Telegram without the Keychain's "always allow" prompt, which only the installed binary itself is trusted to skip. Touches nothing else: no iMessage, no state database, no event log. A mapping whose token cannot be read, or whose `sendMessage` fails, reports a failing result (`code` from the usual table) without stopping the other mappings. `--json` gives `{"ok", "results": [{"mapping", "ok", "messageId", "code", "detail"}]}`.

## [0.5.5] - 2026-10-16

### Changed
- Telegram → iMessage sends are retried when that is safe, and a retry that goes through no longer posts a ⚠️ warning. A send is now two osascript calls: a side-effect-free chat check (10 s limit), then the send. Failures are sorted by whether Messages could have run the send: (a) **certainly not sent** — anything failing in the chat check, including a time-out (a real case: Messages' Apple Event queue was stuck behind another process's permission prompt and the old single script died while looking up the chat), and send errors that happen before the send runs (-1728, -1743/-1744, -1708, -1700, -2740/-2741/-2753, -600); these are retried right away after 2 s and 5 s. (b) **unknown** — the send call itself timed out; this keeps the existing grace period, and if nothing matched by its end, the message is resent once only when Messages answers a chat check again and, after 3 more seconds, no message from you at all has appeared in that chat since the send (Messages records a row for every send it runs, so this also covers echoes whose text did not match). After a restart, for multi-part messages with skipped parts, or when Messages still does not answer, nothing is resent. (c) any other clear error is reported without a retry.
- Warnings now say what was tried ("3번 시도했지만 …", "… 1번 다시 보냈지만 …") and say plainly when the message certainly was not sent. When Messages has not answered twice or more in a row, the warning asks to quit and reopen Messages.
- osascript error text (which contains the chat id) is no longer copied into warnings and logs; only the AppleScript error number is kept.

### Added
- Structured events `im_send_retry` (`attempt`, `reason`, `delay_seconds`) and `im_resend_skipped` (`reason`); `im_send_ok`/`im_send_failed` carry `attempts`, and `im_send_failed` says whether the message `certainly_not_sent`.

## [0.5.4] - 2026-10-15

### Fixed
- When the other side changed their tapback on the same message (e.g. 👀 then ✅), the new reaction often fell back to a reply ("✅ 반응") because the Bot API's 73-emoji reaction list has no ✅, leaving the stale 👀 reaction on screen — it looked like reactions were simply broken. The alias table that maps common emoji to the nearest allowed one (previously just 😂→🤣, ❓→🤔) is now much wider, covering check marks (✅ ☑️ ✔️ → 👌), emphasis (‼️ ❗ ❕ → ⚡), smiling/laughing/sad faces and a few others (see the table in `Reactions.swift`), and skin-tone variants of an already-allowed emoji (e.g. 👍🏽) are recognized too. A genuinely unmapped emoji still falls back to a reply, but any reaction the bot had already set on that message is cleared first, since chat.db reports a changed tapback as a new row with no corresponding "removed" row for the old one.

### Added
- Structured events for the outcome of handling an iMessage tapback: `tg_reaction_set` (emoji actually used, what it was mapped from) on success, `tg_reaction_set_failed` when Telegram rejects it, `tg_reaction_fallback_text` when a reply is sent instead, and `tg_reaction_clear_failed` if clearing a stale reaction before the fallback did not go through.

## [0.5.3] - 2026-10-15

### Fixed
- Links from iMessage arrived in Telegram as a mess: every link preview bubble was relayed as one to three unopenable `<UUID>.pluginPayloadAttachment` files (the preview's icon and image) followed by a bare URL with no title. A link bubble is now one Telegram message, `🔗 <title>` and the original URL, with Telegram's link preview turned on for that URL only. The title comes from the bubble's `payload_data`; without it the URL alone is sent. Other messages keep previews off, so a text with several links no longer risks a preview of the wrong one. A link bubble no longer waits for its preview images to download. An iMessage app bubble with no text and only app data is reported in one line instead of as files.
- When the other side answered one message with several bubbles, every bubble quoted the same original in Telegram. Only the first bubble of such a run is a Telegram reply now; the rest follow it. A reply after any other message in between quotes the original again. The reply links are still stored, so reactions and replies keep working.
- Telegram → iMessage: a hidden link (text with a link behind it) lost its URL, because iMessage has no formatting. It is now sent as `text (URL)`.
- `bluehop status` reported a running service as "loaded, not running" (`service.running: false`, `pid: null`). It read `state = active` from the nested coalition blocks of `launchctl print`, which come after the service's own `state = running`. Only the service's own lines count now.

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

[Unreleased]: https://github.com/kanziw/bluehop/compare/v0.5.6...HEAD
[0.5.6]: https://github.com/kanziw/bluehop/compare/v0.5.5...v0.5.6
[0.5.5]: https://github.com/kanziw/bluehop/compare/v0.5.4...v0.5.5
[0.5.4]: https://github.com/kanziw/bluehop/compare/v0.5.3...v0.5.4
[0.5.3]: https://github.com/kanziw/bluehop/compare/v0.5.2...v0.5.3
[0.5.2]: https://github.com/kanziw/bluehop/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/kanziw/bluehop/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/kanziw/bluehop/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/kanziw/bluehop/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/kanziw/bluehop/releases/tag/v0.4.0
