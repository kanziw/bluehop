# Security

## Reporting a vulnerability

Please do not open a public issue for security problems. Report privately through GitHub's private vulnerability reporting: open the [Security tab](https://github.com/kanziw/bluehop/security) and choose **Report a vulnerability** (direct link: <https://github.com/kanziw/bluehop/security/advisories/new>). This is the only security contact channel.

Include the relay version (`imsg-relay version`; the binary keeps its old name for now), macOS version, and steps to reproduce. Remove bot tokens, phone numbers, email handles, chat guids and Telegram ids from anything you send. bluehop is maintained by one person in their spare time, so there is no guaranteed response time; reports are read and answered on a best-effort basis. The aim for a confirmed issue is a fix and a published advisory before details are discussed publicly.

Supported versions: only the latest release on `main` receives fixes.

## Threat model

bluehop needs Full Disk Access to read the Messages database, and it can send iMessages as you. The design keeps that power narrow:

| Risk | Control |
|---|---|
| Exposed web UI or open port | None exist: no listening sockets, no HTTP server. `scripts/check.sh` fails on `NWListener`, `bind(`, `listen(`, `HTTPServer`, `NSNetService`, `CFSocketCreate`. |
| Talking to an unexpected server | The only URL in the code is `https://api.telegram.org`; it cannot be changed from the config file. `check.sh` fails on any other hard-coded URL. |
| Sending to the wrong chat | One fixed chat. Startup checks that it is a 1:1 chat (style 45) whose only participant is the configured handle. Every chat.db query is limited to that chat's ROWID. |
| Someone else controlling the bot | Telegram messages, edits and reactions are ignored unless they come from the configured chat id and `allowedUserId`, and not from a bot. |
| Shared interpreter with disk access | Only the single signed binary gets Full Disk Access. No Python, shell or plugins. `scripts/agent-run.sh` runs it through launchd, so your terminal never needs that permission. |
| Dependency supply chain | Zero third-party packages (Foundation, SQLite3, Security, AudioToolbox only). `check.sh` fails if `.package(` or `Package.resolved` appears. |
| Script injection through osascript | `osascript` is started without a shell, with one fixed script; message text, file path and chat guid are passed as argv only. |
| Writing to Messages data | chat.db is opened `SQLITE_OPEN_READONLY` with `PRAGMA query_only`. Nothing is written under `~/Library/Messages`. Outgoing attachments are staged in `~/Library/Caches/com.apple.MobileSMS/imsg-relay-outbox` (0700). |
| Secret leakage | Bot token in the Keychain (or a file that must be 0600 and owned by you). Config, state database and their folder must be 0600/0700 and owned by you, or startup is refused. Network errors never include the request URL (which contains the token). Logs contain row ids, counts and kinds, never message text, phone numbers or the token. |
| Runaway sending | Rate limits (20/min to Telegram, 10/min to iMessage) and a circuit breaker that halts both directions above 120/40 messages in 10 minutes or a startup backlog above 50. |
| Late or replayed commands | Each Telegram message is sent at most once (recorded before sending). Messages older than 10 minutes when processed are not sent. Messages from before the first start are skipped. |
| Attachment path tricks | Only files whose real path (symlinks resolved) is under `~/Library/Messages/Attachments` are read. Telegram file names are sanitized before use. |

## Accepted risks

- Telegram bot chats are not end-to-end encrypted. Relayed text and files are stored on Telegram's servers. If that is not acceptable for a conversation, do not relay it.
- Anyone who controls your Telegram account (or the bot token plus your account) can send iMessages to the one configured contact.
- The local state database briefly keeps a normalized copy of text you sent from Telegram, for echo matching. It is cleared when the send is confirmed, and at the latest after one hour.

## Operator checklist

- Keep the bot token private. If it leaks, revoke it in @BotFather (`/revoke`) and replace the Keychain item.
- Keep Full Disk Access limited to the relay binary.
- Use a stable signing identity so you are not trained to click through permission prompts.
- Check `~/Library/Logs/imsg-relay.log` if behavior looks wrong; it contains no message text.
