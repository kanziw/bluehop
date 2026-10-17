# bluehop: iMessage to Telegram relay, one bot per chat

**bluehop** forwards an iMessage conversation to a Telegram bot chat and sends your Telegram replies back to that same iMessage conversation. Link one chat, or several: each linked chat gets its own Telegram bot, and one process relays them all. It is a tiny, self-hosted **iMessage Telegram relay** for macOS: one Swift binary that you build and sign on your own Mac, zero third-party dependencies, no web UI, no open ports. **No bluehop-operated server. Runs on your Mac; relayed bot messages are stored by Telegram and are not end-to-end encrypted.** It runs on your own Mac that is signed in to Messages.

> Not affiliated with, endorsed by, or sponsored by Apple Inc. or Telegram. iMessage and Messages are trademarks of Apple Inc. Telegram is a trademark of its respective owner.

[한국어 README](README.ko.md) · [Agent guide: install, operate, verify, troubleshoot](docs/AGENT-GUIDE.md) · [Agent skill](skills/bluehop/SKILL.md) · [Security](SECURITY.md) · [Design spec (Korean)](SPEC.md) · [llms.txt](llms.txt)

```
iMessage contact ── Messages.app on your Mac ──┐
                                               │ chat.db (read-only)
                                 bluehop (this Mac) ──── https://api.telegram.org ──── one Telegram bot per linked chat, 1:1 with you
                                               │ AppleScript send (fixed script, values as argv)
                                               └── Messages.app → the same contact
```

## Why

Some conversations only exist in iMessage, for example an AI assistant that you can reach only over iMessage, or one family member. If the rest of your day (and your other agents) lives in Telegram, bluehop lets you read and answer that one conversation from Telegram. Because iMessage needs a Mac signed in to Messages, this is self-hosted on your Mac, not a hosted service.

## What it does

- **iMessage → Telegram:** text, reply threads (as real Telegram replies), tapback reactions (as real Telegram reactions when the bot is allowed to use that emoji, otherwise a short reply), photos (HEIC converted to JPEG), voice memos (.caf converted to .m4a), video and files.
- **Telegram → iMessage:** text, photos, voice (.ogg converted to .m4a), video and files up to 20 MB, sent only to the conversation linked to that bot. After sending, the relay looks for the message in the Messages database; only failures get a ⚠️ reply. A send that certainly never reached Messages (for example, Messages did not answer the pre-send chat check) is retried right away, up to twice, and a retry that goes through stays silent. A send whose outcome is unknown is resent once only when Messages answers again and nothing new from you appeared in the chat; otherwise it is reported, never guessed.
- **Several chats:** each link ("mapping") pairs one iMessage 1:1 chat with its own Telegram bot. Mappings run side by side in one process and are isolated: a revoked token, a network error or a safety halt in one mapping does not stop the others. Add, list, pause and remove them with `bluehop mapping …`.
- Messages you send from your iPhone or another Mac are mirrored to Telegram with a `🙋 나:` ("me") prefix so the thread stays readable (`mirrorOwnMessages`, on by default).
- **Language:** the bot's replies, logs and most CLI text are currently in Korean. `doctor`, `mapping test` and `status` print English with `--lang en` (or `BLUEHOP_LANG=en`), and their `--json` output has stable error codes. The relayed message text is passed through unchanged.

## What it does not do

It is deliberately small. It is **not** an all-chats bridge (you pick each chat and give it its own bot), not a group-chat bridge, not a hosted service, and not a general iMessage API. It never asks you to disable System Integrity Protection (SIP). See [Limits](#limits).

## How it compares

All four run on a Mac signed in to Messages and read `chat.db`. Facts below come from each project's own README or docs (checked 2026-10-15; sources linked in the cells).

| | bluehop | [chatwire](https://github.com/allenbina/chatwire) | [BlueBubbles](https://bluebubbles.app/) | [mautrix-imessage](https://github.com/mautrix/imessage) |
|---|---|---|---|---|
| What you use it from | One Telegram bot chat per linked chat | Web UI, Telegram (plugin), push, other plugins | BlueBubbles apps for Android, Windows, Linux, web | Any Matrix client |
| Chats | The 1:1 chats you pick, one bot each | All chats, including groups | All chats, including groups | All chats, including groups |
| Listens on a port | No (outbound HTTPS to Telegram only) | Yes, web UI: no auth by default, gate it at the network layer; an optional shared password can be set ([README](https://github.com/allenbina/chatwire#web-ui-access)) | Yes, server; reached via a built-in proxy (ngrok, Cloudflare) or port forwarding | Normal-Mac connector: needs a Matrix homeserver plus a websocket proxy ([setup](https://docs.mau.fi/bridges/go/imessage/mac/setup.html)). With a Beeper account, `bbctl` self-hosts the bridge without your own homeserver ([docs](https://docs.mau.fi/bridges/go/imessage/)) |
| Stack | Swift, 0 third-party packages | Python + React | TypeScript (Node) | Go |
| Real replies/tapbacks sent to iMessage | No (quoted text instead) | See its docs | Yes, with its Private API; SIP must be disabled only for Private API features, the rest runs with SIP on ([docs](https://docs.bluebubbles.app/private-api/installation)) | Not on the normal-Mac connector (sends with AppleScript); yes with the Mac-without-SIP connector (SIP and AMFI disabled) or the [BlueBubbles connector](https://github.com/mautrix/imessage/tree/master/imessage/bluebubbles) ([docs](https://docs.mau.fi/bridges/go/imessage/)) |
| License | MIT | MIT | Apache-2.0 (server) | AGPL-3.0 |

Choose a full bridge if you want every conversation or a rich client. Choose bluehop if you want a few chosen conversations in Telegram with the smallest possible attack surface.

## Requirements

- A Mac that stays on and logged in, signed in to Messages. The package targets macOS 14 or newer; it has been built and run on macOS 26.0.1 only.
- Xcode (for `swift build` and `swift test`; tested with Xcode 26.2, Swift 6.2.3).
- A Telegram account and a bot token from @BotFather.
- A person who can grant **Full Disk Access** and **Automation (Messages)** to the relay binary in System Settings.
- Recommended: an Apple Development or Developer ID signing certificate in your keychain. Without one the binary is ad-hoc signed and macOS asks for both permissions again after every reinstall.

## Install

Plan on about fifteen minutes once the prerequisites are in place: full Xcode installed (several GB; the Command Line Tools alone cannot run `swift test`), ideally an Apple Development or Developer ID signing certificate in your keychain, and a person at the Mac to grant Full Disk Access and the Messages Automation prompt and to create the bot with @BotFather. There is no prebuilt download yet; the install script builds and signs the binary on your Mac.

Step-by-step with a check after each step: **[docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md)**. Short version:

0. `git clone https://github.com/kanziw/bluehop && cd bluehop`
1. Create a bot with @BotFather (`/newbot`) and keep its token. One bot per chat you want to link.
2. `bash scripts/install.sh --no-load`: runs the local gate, builds and signs the binary, installs it to `~/Library/Application Support/bluehop/bin/bluehop` and writes the LaunchAgent plist. Does not start anything.
3. System Settings → Privacy & Security → Full Disk Access → `+` → ⌘⇧G → `~/Library/Application Support/bluehop/bin/bluehop`. Grant it to that binary only, not to your terminal.
4. Add the first chat:
   ```bash
   B="$HOME/Library/Application Support/bluehop/bin/bluehop"
   "$B" mapping add
   ```
   It asks for the bot token (hidden), checks it with Telegram, lets you pick the iMessage chat with the arrow keys, asks you to send any message to the bot to learn your Telegram ids, stores the token in the Keychain and runs a check. Your terminal does not need Full Disk Access: when it cannot read the Messages database, bluehop runs the installed binary once through launchd to list the chats.
5. `bash scripts/agent-run.sh doctor --messages --telegram`. Click **Allow** when macOS asks whether bluehop may control Messages. When every line shows ✔, run `bash scripts/install.sh` to start the LaunchAgent.
6. Send `/status` in the bot's Telegram chat.

To link another chat later, create another bot and run `mapping add` again. A running relay starts the new mapping within about five seconds; no restart.

For agents and scripts, every value can be given as a flag and the token read from stdin (never from the command line):

```bash
printf '%s\n' "$TOKEN" | "$B" mapping add --token-stdin --chat '+15555550123' --id family --json
```

## CLI

Every command has `--help`; read commands take `--json`; unknown flags are errors.

| Command | What it does |
|---|---|
| `bluehop chats [--search TEXT] [--limit N] [--json]` | Local iMessage 1:1 chats: guid, handle, service, last activity, which mapping uses it. No message content |
| `bluehop mapping list [--json]` | Configured mappings (never the token) |
| `bluehop mapping add [--id ID] [--chat GUID\|HANDLE] [--token-stdin \| --token-file PATH] [--telegram-chat ID --allowed-user ID] [--wait SEC] [--dry-run] [--json]` | Link a chat to a new bot. Interactive in a terminal, flag-driven otherwise |
| `bluehop mapping remove ID [--keep-token] [--purge-state]` | Remove a mapping and its Keychain token |
| `bluehop mapping pause ID` / `resume ID` | Stop or restart one mapping without touching the others |
| `bluehop mapping test ID [--messages] [--json]` | Check one mapping (token, chat, `getMe`). Sends nothing |
| `bluehop doctor [--mapping ID] [--messages] [--telegram] [--json] [--lang en]` | Check all mappings or one. Sends nothing; `--messages` triggers the macOS Automation prompt the first time, `--telegram` calls `getMe` |
| `bluehop status [--json] [--lang en]` | Per mapping: last Telegram poll, last error, safety halt; whether the LaunchAgent runs |
| `bluehop resume [--mapping ID] [--skip-backlog]` | Clear a safety halt |
| `bluehop telegram-ids [--mapping ID \| --token-stdin]` | Chat and user ids of recent senders to a bot |
| `bluehop notify [--mapping ID \| --all] (--text TEXT \| --text-stdin) [--json]` | Send one Telegram message to a mapping's chat (or all mappings) with that mapping's own token. Does not touch iMessage |

Exit codes: `0` ok, `1` failure (a check failed, network, Keychain), `2` usage error, `3` conflict (same chat, same bot or same id), `4` not found, `5` timed out waiting for a Telegram message, `130` cancelled.

### Machine-readable checks

Human-readable output is Korean by default. `doctor`, `mapping test` and `status` take `--lang en` (or the environment variable `BLUEHOP_LANG=en`) for English. Other commands, error messages on stderr and the bot's replies stay Korean; agents should use `--json` and branch on the codes below, not on text.

- `doctor --json` / `mapping test --json`: `{"schemaVersion": 1, "ok", "codes": [...], "config": CHECK, "mappings": [{"id", "enabled", "ok", "codes", "checks": [CHECK]}]}`. Each `CHECK` is `{"id", "ok", "code", "name", "detail", "title", "message"}`: `id` is one of `config`, `token`, `chatdb`, `messages`, `telegram`; `code` is from the table; `name` and `detail` are Korean, `title` and `message` English. `codes` lists the failing codes in order. Run through launchd (no Full Disk Access in the terminal), the object also has `"via": "launchd"`.
- `status --json`: `{"schemaVersion": 1, "service": {"label", "loaded", "running", "pid"}, "mappings": [{"id", "enabled", "verdict", "workerState", "halted", "lastTelegramPollAt", "lastIMessageScanAt", "lastError", "lastErrorAt", "lastErrorCode"}]}`. `verdict` is `ok`, `paused`, `halted`, `error`, `stale` or `unknown`; `lastErrorCode` is from the table (`null` when there is no error).
- Error on any command with `--json`: `{"ok": false, "error": {"kind", "message", "exitCode"}}`, `kind` one of `failure`, `usage`, `conflict`, `not_found`, `timeout`, `cancelled`.

Codes are stable: renaming or removing one, or changing its meaning, is a breaking change (and bumps `schemaVersion`); new codes may be added, so treat an unknown code like `UNKNOWN`.

| Code | Meaning |
|---|---|
| `OK` | Check passed. |
| `CONFIG_MISSING` | Config file does not exist |
| `CONFIG_PERMISSIONS` | Config, token file or folder readable by others (needs 0600 / 0700) |
| `CONFIG_INVALID` | Config not valid (JSON shape, unknown version, empty ids, group chat guid) |
| `CONFIG_CONFLICT` | One iMessage chat or one bot linked twice |
| `MAPPING_NOT_FOUND` | No mapping with that id |
| `TOKEN_UNREADABLE` | Keychain item or token file missing or unreadable |
| `TOKEN_FORMAT` | Not a Telegram bot token |
| `TOKEN_BOT_MISMATCH` | Token belongs to a different bot than the config records |
| `CHATDB_UNREADABLE` | Messages database cannot be opened (Full Disk Access missing) |
| `CHAT_NOT_FOUND` | Configured chat guid not in the Messages database |
| `CHAT_NOT_ONE_TO_ONE` | Configured chat is a group chat |
| `CHAT_HANDLE_MISMATCH` | Chat participant differs from the configured handle |
| `MESSAGES_AUTOMATION_DENIED` | Automation permission for Messages missing (osascript -1743) |
| `MESSAGES_CHAT_NOT_FOUND` | Messages.app does not know the chat |
| `MESSAGES_ERROR` | Other osascript failure |
| `TELEGRAM_UNAUTHORIZED` | Token rejected (HTTP 401/404) |
| `TELEGRAM_CONFLICT` | Another poller or a webhook on the same bot (HTTP 409) |
| `TELEGRAM_RATE_LIMITED` | Telegram asked to retry later |
| `TELEGRAM_NETWORK` | api.telegram.org unreachable |
| `TELEGRAM_ERROR` | Other Telegram API error |
| `TELEGRAM_SKIPPED` | getMe skipped because the token could not be read |
| `UNKNOWN` | Anything else; read `detail` |

## Configuration

`~/Library/Application Support/bluehop/config.json` (mode 0600, folder 0700; the relay refuses to start if they are wider). `bluehop mapping add` writes it; you rarely need to edit it by hand.

```json
{
  "version": 2,
  "mappings": [
    { "id": "family", "enabled": true,
      "telegram": { "chatId": 123456789, "allowedUserId": 123456789, "botId": 111111, "botUsername": "family_relay_bot",
                    "tokenSource": "keychain", "tokenAccount": "bot-token:family", "tokenFile": null },
      "imessage": { "chatGuid": "any;-;+15555550123", "handle": "+15555550123" },
      "relay": { "mirrorOwnMessages": true, "telegramReactionMode": "ignore", "outboxDirectory": null } }
  ]
}
```

| Key | Meaning |
|---|---|
| `id` | Mapping name: starts with a lowercase letter; lowercase letters, digits and `-`; up to 32 characters. |
| `enabled` | `false` pauses the mapping (no polling at all). Default `true`. |
| `telegram.chatId` | Your 1:1 chat with this mapping's bot. Must not be 0. |
| `telegram.allowedUserId` | The only Telegram user whose messages are accepted. Must be positive. |
| `telegram.botId`, `botUsername` | Recorded from `getMe` when the mapping is added. Used to refuse a bot that is already linked. |
| `telegram.tokenSource` | `"keychain"` (service `dev.kanziw.bluehop`, account `tokenAccount`, default `bot-token:<id>`) or `"file"`. |
| `telegram.tokenFile` | Required when `tokenSource` is `"file"`. `~` is expanded. The file must be owned by you and mode 0600. |
| `imessage.chatGuid` | A 1:1 chat guid containing `;-;` (group guids `;+;` are rejected). Copy it from `bluehop chats`. |
| `imessage.handle` | The chat's only participant (phone number or email). Checked against chat.db at startup. |
| `relay.mirrorOwnMessages` | Mirror messages you send from other devices (default `true`). |
| `relay.telegramReactionMode` | `"ignore"` (default): Telegram reactions are not sent. `"text"`: sent as a short text such as `❤ ↪ "start of message…"`. |
| `relay.outboxDirectory` | Where Telegram attachments are staged before sending (each mapping uses its own subfolder). Default `~/Library/Caches/com.apple.MobileSMS/bluehop-outbox`. It must be a folder the sandboxed Messages app can read; leave it `null` unless you know why. |

Rules checked on every load and write: ids are unique, an iMessage chat (guid or handle) is linked at most once, and a bot token is used by at most one mapping (Telegram allows only one `getUpdates` consumer per bot). A 0.4 config (top-level `telegram` and `imessage`) is still read, as one mapping named `default` that keeps the old Keychain account `telegram-bot-token`; the first `bluehop mapping` command that changes something rewrites it in the new shape and keeps `config.json.v1-backup`.

## Telegram commands

Each bot answers for its own mapping only: `/status`, `/pause`, `/resume`. If more than 50 iMessages are waiting, `/resume` asks you to choose `/resume skip` (drop the backlog) or `/resume all` (send it). To send a message that starts with `/`, start it with `//`.

## Limits

| Feature | iMessage → Telegram | Telegram → iMessage |
|---|---|---|
| Text | Yes; longer than 4000 characters is split | Yes, up to 4000 characters |
| Replies | Real Telegram reply when the original is known, otherwise a `↪ "quote…"` prefix | No public API for iMessage threaded replies; sent with a `↪ "start of original…"` prefix |
| Reactions | Real Telegram reaction for emoji a bot may use directly, or mapped to the closest one (❤️ 👍 👎, 😂/😆/😅/💀 as 🤣, ❓/❔ as 🤔, ✅/☑️/✔️ as 👌, ‼️/❗/❕ as ⚡, some custom emoji); genuinely unmapped emoji as a short reply. Changing a tapback replaces the reaction (or clears it before falling back to a reply if the new emoji has no mapping); removing a tapback removes the reaction | No public API; ignored by default, or sent as text in `"text"` mode (needs Telegram to deliver reaction updates for private chats; not yet verified) |
| Attachments | Photos, voice, video, files up to 50 MB (larger ones become a notice); GIFs and photos over 10 MB as files | Photos, voice, video, files up to 20 MB (Telegram bot download limit) |
| Your messages from other devices | Shown with `🙋 나:` | n/a |
| Edits and unsend | Not mirrored | Not mirrored (editing in Telegram gets a "not applied" notice) |
| Telegram stickers | n/a | Not sent (⚠️ notice) |
| Group chats | Not supported | Not supported |
| Several chats | Yes, one Telegram bot per chat | Yes, each bot sends only to its own chat |

Safety rules, per mapping: the relay sends at most 20 messages a minute to Telegram and 10 a minute to iMessage (it waits, it does not drop). It halts both directions when it would exceed 120 messages to Telegram or 40 to iMessage within 10 minutes, or when more than 50 iMessages are waiting at startup. Telegram messages older than 10 minutes when processed are not sent (you get a ⚠️). Messages sent to the bot before the very first start are skipped once, with a notice. Why some things are impossible: [docs/imessage-limits.md](docs/imessage-limits.md) (Korean).

## Security model in short

No listening sockets or web server. One outbound host, `https://api.telegram.org`, hard-coded and not configurable. chat.db is opened read-only (`SQLITE_OPEN_READONLY` plus `query_only`), and every query is limited to the configured chats. Only the signed binary gets Full Disk Access; no Python, shell, or plugins. osascript gets a fixed script with values as argv. Config, state and token files must be 0600. Both logs (`~/Library/Logs/bluehop.log` and the structured `bluehop-events.jsonl`, see "Logs" below) contain row ids, counts, kinds and durations, never message text, phone numbers, or the token, except for a couple of events that can carry text when a debug-only opt-in (`BLUEHOP_LOG_BODIES=1`) is explicitly set. Residual risk: there is no bluehop-operated server, but Telegram bot chats are not end-to-end encrypted, so relayed messages are stored on Telegram's servers. Details: [SECURITY.md](SECURITY.md).

## Operate

| Task | Command |
|---|---|
| Health check (sends nothing) | `bash scripts/agent-run.sh doctor --messages --telegram` |
| Status of every mapping | `bluehop status` (or `/status` in a bot chat) |
| Add, pause, remove a chat | `bluehop mapping add`, `bluehop mapping pause ID`, `bluehop mapping remove ID` |
| Restart | `launchctl kickstart -k "gui/$(id -u)/dev.kanziw.bluehop"` |
| Update | `git pull && bash scripts/install.sh` |
| Logs | `~/Library/Logs/bluehop.log` (human-readable) and `~/Library/Logs/bluehop-events.jsonl` (structured, see below) |
| Bundle logs for a bug report | `bash scripts/collect-logs.sh` (read-only; prints the path to a `.tar.gz`) |
| Uninstall | `bash scripts/uninstall.sh` (keeps config and state) or `bash scripts/uninstall.sh --purge` (also removes config, state and every mapping's Keychain token) |

### Logs

`bluehop.log` is the human-readable line the LaunchAgent redirects (one line per notable thing, no rotation — macOS/launchd does not roll it). `bluehop-events.jsonl` is a second, structured log: one JSON object per line (`ts`, `level`, `mapping`, `event`, plus whatever correlation ids apply — a Telegram update/message id, a chat.db row id), covering every step of a request: received, send start/end (with its duration in `ms`), send retries (`im_send_retry` with the attempt number and reason) and skipped resends, echo wait/match/give-up, warning sent, reaction/attachment handling, `getUpdates` errors and their retry backoff, and start/halt/resume. It rotates itself by size (10 MB × 5 files by default, oldest dropped) — nothing else needs to logrotate it. Both paths (and the active level) are printed by `bluehop status` and `bluehop doctor`.

Levels are `info` (default) and `debug`. Set `BLUEHOP_LOG_LEVEL=debug` in the LaunchAgent's `EnvironmentVariables` for more detail (still no message bodies). Message text, phone numbers, Apple IDs and the bot token are never written at any level by default — only lengths, hashes, counts and durations. A couple of "received" events can additionally carry the actual text, but only when `BLUEHOP_LOG_BODIES=1` is set *together with* `debug`; turn it on for a short, deliberate debugging window and back off afterward, and strip it before sharing the log (`scripts/collect-logs.sh` does this for you, as a second line of defense, by dropping any line with a `"text"` field).

## Develop

```bash
bash scripts/setup-dev.sh      # once per clone: enable the git hooks in .githooks/
bash scripts/check.sh          # forbidden-pattern scan + swift build + swift test
bash scripts/build-release.sh  # signed dist/bluehop
```

Rules for contributors and coding agents: [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md). Changes: [CHANGELOG.md](CHANGELOG.md). The identifier `dev.kanziw.bluehop` (Keychain service, LaunchAgent label, signing and bundle identifier) is shared by the code and all scripts; change all or none.

## License

[MIT](LICENSE)
