# bluehop: iMessage to Telegram relay for one chat

**bluehop** forwards one iMessage conversation to a Telegram bot chat and sends your Telegram replies back to that same iMessage conversation. It is a tiny, self-hosted **iMessage Telegram relay** for macOS: one signed Swift binary, zero third-party dependencies, no web UI, no open ports, no cloud service. It runs on your own Mac that is signed in to Messages.

> **Name note:** the project is called bluehop, but the binary and its install paths are still named `imsg-relay` (`~/Library/Application Support/imsg-relay/bin/imsg-relay`, LaunchAgent `dev.kanziw.imsg-relay`, Keychain service `dev.kanziw.imsg-relay`). Commands below use those real names. Renaming them is a later, separate step because macOS ties Full Disk Access to the binary's identity, so every install would have to grant it again.

> Not affiliated with, endorsed by, or sponsored by Apple Inc. or Telegram. iMessage and Messages are trademarks of Apple Inc. Telegram is a trademark of its respective owner.

[한국어 README](README.ko.md) · [Agent guide: install, operate, verify, troubleshoot](docs/AGENT-GUIDE.md) · [Security](SECURITY.md) · [Design spec (Korean)](SPEC.md) · [llms.txt](llms.txt)

```
iMessage contact ── Messages.app on your Mac ──┐
                                               │ chat.db (read-only)
                                 bluehop (this Mac) ──── https://api.telegram.org ──── your Telegram bot, 1:1 chat with you
                                               │ AppleScript send (fixed script, values as argv)
                                               └── Messages.app → the same contact
```

## Why

Some conversations only exist in iMessage, for example an AI assistant that you can reach only over iMessage, or one family member. If the rest of your day (and your other agents) lives in Telegram, bluehop lets you read and answer that one conversation from Telegram. Because iMessage needs a Mac signed in to Messages, this is self-hosted on your Mac, not a hosted service.

## What it does

- **iMessage → Telegram:** text, reply threads (as real Telegram replies), tapback reactions (as real Telegram reactions when the bot is allowed to use that emoji, otherwise a short reply), photos (HEIC converted to JPEG), voice memos (.caf converted to .m4a), video and files.
- **Telegram → iMessage:** text, photos, voice (.ogg converted to .m4a), video and files up to 20 MB, sent only to the one configured conversation. After sending, the relay looks for the message in the Messages database; only failures get a ⚠️ reply. Nothing is resent automatically, and the same Telegram message is never sent twice.
- Messages you send from your iPhone or another Mac are mirrored to Telegram with a `🙋 나:` ("me") prefix so the thread stays readable (`mirrorOwnMessages`, on by default).
- **Language:** the bot's replies, `doctor` output and logs are currently in Korean. The relayed message text is passed through unchanged.

## What it does not do

It is deliberately small. It is **not** a multi-chat bridge, not a group-chat bridge, not a hosted service, and not a general iMessage API. It never asks you to disable System Integrity Protection (SIP). See [Limits](#limits).

## How it compares

All four run on a Mac signed in to Messages and read `chat.db`. Facts below come from each project's own README or docs (checked 2026-10-15).

| | bluehop | [chatwire](https://github.com/allenbina/chatwire) | [BlueBubbles](https://bluebubbles.app/) | [mautrix-imessage](https://github.com/mautrix/imessage) |
|---|---|---|---|---|
| What you use it from | One Telegram bot chat | Web UI, Telegram (plugin), push, other plugins | BlueBubbles apps for Android, Windows, Linux, web | Any Matrix client |
| Chats | Exactly one 1:1 chat | All chats, including groups | All chats, including groups | All chats, including groups |
| Listens on a port | No (outbound HTTPS to Telegram only) | Yes, web UI; its README says it has no auth by default and should be gated at the network layer | Yes, server; reached via a built-in proxy (ngrok, Cloudflare) or port forwarding | Needs a Matrix homeserver plus a websocket proxy |
| Stack | Swift, 0 third-party packages | Python + React | TypeScript (Node) | Go |
| Real replies/tapbacks sent to iMessage | No (quoted text instead) | See its docs | Yes with its Private API, which requires disabling SIP | Not on the standard macOS connector; yes on connectors that need SIP disabled or BlueBubbles |
| License | MIT | MIT | Apache-2.0 (server) | AGPL-3.0 |

Choose a full bridge if you want every conversation or a rich client. Choose bluehop if you want one conversation in Telegram with the smallest possible attack surface.

## Requirements

- A Mac that stays on and logged in, signed in to Messages. The package targets macOS 14 or newer; it has been built and run on macOS 26.0.1 only.
- Xcode (for `swift build` and `swift test`; tested with Xcode 26.2, Swift 6.2.3).
- A Telegram account and a bot token from @BotFather.
- A person who can grant **Full Disk Access** and **Automation (Messages)** to the relay binary in System Settings.
- Recommended: an Apple Development or Developer ID signing certificate in your keychain. Without one the binary is ad-hoc signed and macOS asks for both permissions again after every reinstall.

## Install

Step-by-step with a check after each step: **[docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md)**. Short version:

0. `git clone https://github.com/kanziw/bluehop && cd bluehop`
1. Create a bot with @BotFather (`/newbot`), open a chat with it, and send it any message.
2. `bash scripts/install.sh --no-load`: runs the local gate, builds and signs the binary, installs it to `~/Library/Application Support/imsg-relay/bin/imsg-relay`, writes the LaunchAgent plist and a config template. Does not start anything.
3. Store the bot token in the Keychain (you are prompted for it, so it stays out of shell history):
   ```bash
   security add-generic-password -s dev.kanziw.imsg-relay -a telegram-bot-token \
     -T "$HOME/Library/Application Support/imsg-relay/bin/imsg-relay" -w
   ```
4. System Settings → Privacy & Security → Full Disk Access → `+` → ⌘⇧G → `~/Library/Application Support/imsg-relay/bin/imsg-relay`. Grant it to that binary only, not to your terminal.
5. `bash scripts/agent-run.sh telegram-ids` prints `chatId` and `allowedUserId` (run it before the relay is started). `bash scripts/agent-run.sh list-chats` prints `chatGuid` and `handle` for recent 1:1 chats.
6. Put those values in `~/Library/Application Support/imsg-relay/config.json` (keep it mode 0600).
7. `bash scripts/agent-run.sh doctor --messages --telegram`. Click **Allow** when macOS asks whether imsg-relay (the binary) may control Messages. When every line shows ✔, run `bash scripts/install.sh` to start the LaunchAgent.
8. Send `/status` in the Telegram chat.

`scripts/agent-run.sh` runs the installed binary through launchd, so it uses the binary's own permissions and your terminal never needs Full Disk Access.

## Configuration

`~/Library/Application Support/imsg-relay/config.json` (mode 0600, folder 0700; the relay refuses to start if they are wider):

```json
{
  "telegram": { "chatId": 123456789, "allowedUserId": 123456789,
                "tokenSource": "keychain", "tokenFile": null },
  "imessage": { "chatGuid": "any;-;+15555550123", "handle": "+15555550123" },
  "relay": { "mirrorOwnMessages": true, "telegramReactionMode": "ignore",
             "outboxDirectory": null }
}
```

| Key | Meaning |
|---|---|
| `telegram.chatId` | Your 1:1 chat with the bot. Must not be 0. |
| `telegram.allowedUserId` | The only Telegram user whose messages are accepted. Must be positive. |
| `telegram.tokenSource` | `"keychain"` (service `dev.kanziw.imsg-relay`, account `telegram-bot-token`) or `"file"`. |
| `telegram.tokenFile` | Required when `tokenSource` is `"file"`. `~` is expanded. The file must be owned by you and mode 0600. |
| `imessage.chatGuid` | A 1:1 chat guid containing `;-;` (group guids `;+;` are rejected). Copy it from `list-chats`. |
| `imessage.handle` | The chat's only participant (phone number or email). Checked against chat.db at startup. |
| `relay.mirrorOwnMessages` | Mirror messages you send from other devices (default `true`). |
| `relay.telegramReactionMode` | `"ignore"` (default): Telegram reactions are not sent. `"text"`: sent as a short text such as `❤ ↪ "start of message…"`. |
| `relay.outboxDirectory` | Where Telegram attachments are staged before sending. Default `~/Library/Caches/com.apple.MobileSMS/imsg-relay-outbox`. It must be a folder the sandboxed Messages app can read; leave it `null` unless you know why. |

The `relay` block may be omitted.

## Telegram commands

`/status`, `/pause`, `/resume`. If more than 50 iMessages are waiting, `/resume` asks you to choose `/resume skip` (drop the backlog) or `/resume all` (send it). To send a message that starts with `/`, start it with `//`.

## Limits

| Feature | iMessage → Telegram | Telegram → iMessage |
|---|---|---|
| Text | Yes; longer than 4000 characters is split | Yes, up to 4000 characters |
| Replies | Real Telegram reply when the original is known, otherwise a `↪ "quote…"` prefix | No public API for iMessage threaded replies; sent with a `↪ "start of original…"` prefix |
| Reactions | Real Telegram reaction for emoji a bot may use (❤️ 👍 👎, 😂 as 🤣, ❓ as 🤔, some custom emoji); others such as ‼️ as a short reply. Removing a tapback removes the reaction | No public API; ignored by default, or sent as text in `"text"` mode (needs Telegram to deliver reaction updates for private chats; not yet verified) |
| Attachments | Photos, voice, video, files up to 50 MB (larger ones become a notice); GIFs and photos over 10 MB as files | Photos, voice, video, files up to 20 MB (Telegram bot download limit) |
| Your messages from other devices | Shown with `🙋 나:` | n/a |
| Edits and unsend | Not mirrored | Not mirrored (editing in Telegram gets a "not applied" notice) |
| Telegram stickers | n/a | Not sent (⚠️ notice) |
| Group chats, more than one chat | Not supported | Not supported |

Safety rules: the relay sends at most 20 messages a minute to Telegram and 10 a minute to iMessage (it waits, it does not drop). It halts both directions when it would exceed 120 messages to Telegram or 40 to iMessage within 10 minutes, or when more than 50 iMessages are waiting at startup. Telegram messages older than 10 minutes when processed are not sent (you get a ⚠️). Messages sent to the bot before the very first start are skipped once, with a notice. Why some things are impossible: [docs/imessage-limits.md](docs/imessage-limits.md) (Korean).

## Security model in short

No listening sockets or web server. One outbound host, `https://api.telegram.org`, hard-coded and not configurable. chat.db is opened read-only (`SQLITE_OPEN_READONLY` plus `query_only`), and every query is limited to the one configured chat. Only the signed binary gets Full Disk Access; no Python, shell, or plugins. osascript gets a fixed script with values as argv. Config, state and token files must be 0600. Logs contain row ids, counts and kinds, never message text, phone numbers, or the token. Residual risk: Telegram bot chats are not end-to-end encrypted, so relayed messages are stored on Telegram's servers. Details: [SECURITY.md](SECURITY.md).

## Operate

| Task | Command |
|---|---|
| Health check (sends nothing) | `bash scripts/agent-run.sh doctor --messages --telegram` |
| Status | `/status` in Telegram |
| Restart | `launchctl kickstart -k "gui/$(id -u)/dev.kanziw.imsg-relay"` |
| Update | `git pull && bash scripts/install.sh` |
| Logs | `~/Library/Logs/imsg-relay.log` (no message text) |
| Uninstall | `bash scripts/uninstall.sh` (keeps config and state) or `bash scripts/uninstall.sh --purge` (also removes config, state and the Keychain item) |

## Develop

```bash
bash scripts/setup-dev.sh      # once per clone: enable the git hooks in .githooks/
bash scripts/check.sh          # forbidden-pattern scan + swift build + swift test
bash scripts/build-release.sh  # signed dist/imsg-relay
```

Rules for contributors and coding agents: [AGENTS.md](AGENTS.md) and [CONTRIBUTING.md](CONTRIBUTING.md). Changes: [CHANGELOG.md](CHANGELOG.md). The identifier `dev.kanziw.imsg-relay` (Keychain service, LaunchAgent label, signing and bundle identifier) is shared by the code and all scripts; change all or none.

## License

[MIT](LICENSE)
