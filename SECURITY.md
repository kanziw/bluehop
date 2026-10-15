# Security

## Reporting a vulnerability

Please do not open a public issue for security problems. Report privately through GitHub's private vulnerability reporting: open the [Security tab](https://github.com/kanziw/bluehop/security) and choose **Report a vulnerability** (direct link: <https://github.com/kanziw/bluehop/security/advisories/new>). This is the only security contact channel.

Include the relay version (`bluehop version`), macOS version, and steps to reproduce. Remove bot tokens, phone numbers, email handles, chat guids and Telegram ids from anything you send. bluehop is maintained by one person in their spare time, so there is no guaranteed response time; reports are read and answered on a best-effort basis. The aim for a confirmed issue is a fix and a published advisory before details are discussed publicly.

Supported versions: only the latest release on `main` receives fixes.

## Threat model

bluehop needs Full Disk Access to read the Messages database, and it can send iMessages as you. The design keeps that power narrow:

| Risk | Control |
|---|---|
| Exposed web UI or open port | None exist: no listening sockets, no HTTP server. `scripts/check.sh` fails on `NWListener`, `bind(`, `listen(`, `HTTPServer`, `NSNetService`, `CFSocketCreate`. |
| Talking to an unexpected server | The only URL in the code is `https://api.telegram.org`; it cannot be changed from the config file. `check.sh` fails on any other hard-coded URL. |
| Sending to the wrong chat | Each mapping has one fixed chat and its own bot; a bot only ever sends to its own chat. Startup checks that the chat is 1:1 (style 45) and that its only participant is the configured handle. Every chat.db message query is limited to the configured chat ROWIDs. The config is refused if one iMessage chat or one bot token appears in two mappings. |
| Someone else controlling the bot | Telegram messages, edits and reactions are ignored unless they come from that mapping's chat id and `allowedUserId`, and not from a bot. While adding a mapping, the Telegram ids are taken only from a private message sent within 10 minutes, shown to the person for confirmation in a terminal, and several different senders are refused. |
| Shared interpreter with disk access | Only the single signed binary gets Full Disk Access. No Python, shell or plugins. `scripts/agent-run.sh`, and the CLI itself when it cannot read chat.db, run the installed binary through a one-shot launchd job, so your terminal never needs that permission. |
| Dependency supply chain | Zero third-party packages (Foundation, SQLite3, Security, AudioToolbox only). `check.sh` fails if `.package(` or `Package.resolved` appears. |
| Script injection through osascript | `osascript` is started without a shell, with one fixed script; message text, file path and chat guid are passed as argv only. |
| Writing to Messages data | chat.db is opened `SQLITE_OPEN_READONLY` with `PRAGMA query_only`. Nothing is written under `~/Library/Messages`. Outgoing attachments are staged in `~/Library/Caches/com.apple.MobileSMS/bluehop-outbox` (0700). |
| Secret leakage | Bot tokens in the Keychain, one item per mapping (or a file that must be 0600 and owned by you). The CLI never accepts a token as a command-line argument (stdin or a hidden prompt only), passes it to `security` on stdin rather than argv, and never prints it. Config, state database and their folder must be 0600/0700 and owned by you, or startup is refused. Network errors never include the request URL (which contains the token). Both logs (`bluehop.log` and the structured `bluehop-events.jsonl`) contain row ids, counts, kinds and durations, never message text, phone numbers or the token, at any level — except for a couple of events that can carry text when the debug-only opt-in `BLUEHOP_LOG_BODIES=1` is explicitly set alongside `BLUEHOP_LOG_LEVEL=debug`; `scripts/collect-logs.sh` strips those lines before bundling logs for a report. |
| Runaway sending | Per mapping: rate limits (20/min to Telegram, 10/min to iMessage) and a circuit breaker that halts both directions of that mapping above 120/40 messages in 10 minutes or a startup backlog above 50. |
| Late or replayed commands | Each Telegram message is sent at most once (recorded before sending). Messages older than 10 minutes when processed are not sent. Messages from before the first start are skipped. |
| Attachment path tricks | Only files whose real path (symlinks resolved) is under `~/Library/Messages/Attachments` are read. Telegram file names are sanitized before use. |

## Accepted risks

- Telegram bot chats are not end-to-end encrypted. Relayed text and files are stored on Telegram's servers. If that is not acceptable for a conversation, do not relay it.
- Anyone who controls your Telegram account (or the bot token plus your account) can send iMessages to the contact linked to that bot.
- The local state database briefly keeps a normalized copy of text you sent from Telegram, for echo matching. It is cleared when the send is confirmed, and at the latest after one hour.

## Operator checklist

- Keep the bot token private. If one leaks, revoke it in @BotFather (`/revoke`), then `bluehop mapping remove <id>` and `bluehop mapping add` with the new token.
- Keep Full Disk Access limited to the relay binary.
- Use a stable signing identity so you are not trained to click through permission prompts.
- Check `~/Library/Logs/bluehop.log` and `~/Library/Logs/bluehop-events.jsonl` if behavior looks wrong; neither contains message text by default. Only turn on `BLUEHOP_LOG_BODIES=1` (with `BLUEHOP_LOG_LEVEL=debug`) for a short, deliberate debugging window, and use `bash scripts/collect-logs.sh` to bundle logs for a report (it drops any line that opt-in may have added).
