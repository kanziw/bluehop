---
name: bluehop
description: Install, operate and troubleshoot bluehop, a macOS relay that links iMessage 1:1 chats to Telegram bots (one bot per chat). Use when a user wants to read or answer an iMessage conversation from Telegram, add or remove a linked chat, list local iMessage chats, check relay health, or fix a bluehop error. Not for group chats, Linux/Windows, or sending iMessages without the user's explicit go-ahead.
---

# bluehop

bluehop runs on the user's Mac (signed in to Messages) as the LaunchAgent `dev.kanziw.bluehop`. Each **mapping** links one iMessage 1:1 chat to one Telegram bot chat; one process relays every enabled mapping, each in its own isolated worker. Full step-by-step guide with checks: `docs/AGENT-GUIDE.md`. Design: `docs/design-multi-mapping.md`.

Binary after install: `B="$HOME/Library/Application Support/bluehop/bin/bluehop"`. Every command and script has `--help`/`-h` (prints help, exits 0, does nothing else); read commands take `--json`; unknown flags fail with exit code 2. Before running a command that is not read-only, check its row in the side-effect table of `docs/AGENT-GUIDE.md` ("Side effects of every command").

## When to use

- "Get my iMessages from X in Telegram", "link another chat", "which chats are linked", "is the relay running", "the relay stopped", "remove the link to X".
- Not for: group chats (unsupported), all chats at once (each chat needs its own bot), reading message content (bluehop never prints it).

## Safety rules (always)

1. **Never ask for, print or log a bot token.** Pass it on stdin (`--token-stdin`) or let the human type it into the hidden prompt of `bluehop mapping add` in their own terminal. There is no flag that takes a token value.
2. **Never send a real message** to the user's contacts to "test". `doctor`, `mapping test`, `status`, `chats` and `mapping list` send nothing (`doctor --messages` shows the macOS Automation prompt the first time). `diag-send-file` really sends: only with the human's explicit go-ahead. `notify` really sends to the mapping's own Telegram chat (never to the iMessage contact) — only when the human (or the automation they set up) asked for that alert. With the relay running, `mapping add`, `mapping resume` and `resume` make it start relaying within seconds, and `bash scripts/install.sh` starts it; `bash scripts/uninstall.sh --purge` deletes every mapping and token.
3. `bluehop chats` and `mapping list` print phone numbers and email addresses. Do not paste them into logs, issues or chat; show the human only the line they need, and confirm the chosen contact with them before adding a mapping.
4. Agents do not grant macOS permissions (Full Disk Access, Automation). Stop and ask the human.
5. Do not edit `config.json` by hand when a `bluehop mapping` command can do it; the commands validate and back up.

## Install (first time)

```bash
git clone https://github.com/kanziw/bluehop && cd bluehop
bash scripts/install.sh --no-load      # gate + build + sign + place binary; starts nothing
```
HUMAN: System Settings → Privacy & Security → Full Disk Access → add `~/Library/Application Support/bluehop/bin/bluehop`. Then add the first mapping (below), then:
```bash
bash scripts/agent-run.sh doctor --messages --telegram   # HUMAN clicks "Allow" for Messages automation
bash scripts/install.sh                                  # starts the LaunchAgent once doctor passes
```

## Add a mapping without prompts

Prerequisites: the human created a **new** bot with @BotFather (one bot per chat; a bot already linked is refused with exit 3).

1. Find the chat (no message content is read):
   ```bash
   "$B" chats --search "<part of the number or email>" --json
   ```
   Pick the `guid` the human confirms. `mappedTo` non-null means it is already linked.
2. Ask the human to send any message to the new bot in Telegram (it is never relayed). Then, with the token on stdin. The human creates the token file (mode 0600, e.g. `umask 077; pbpaste > ~/bluehop-token`) and gives you only its path; you redirect it into stdin and never open or print it; the human deletes the file after success (the token is then in the Keychain). Or the human pipes it themselves:
   ```bash
   "$B" mapping add --token-stdin --chat '<guid>' --id <slug> --wait 180 --json < /path/to/token-file
   ```
   - `--id`: starts with a lowercase letter; lowercase, digits, `-`; ≤ 32 chars. Omit to derive from the bot name.
   - The Telegram chat and user ids are detected from a private message to the bot sent in the last 10 minutes or during `--wait`. If the human already knows them: `--telegram-chat <id> --allowed-user <id>` (both or neither).
   - `--dry-run` validates without writing. `--token-file PATH` keeps the token in that 0600 file instead of the Keychain.
3. The JSON result has `ok`, `mapping` (no token), `doctor` and `service`. A running relay starts the new mapping within about 5 seconds; no restart needed.

Interactive alternative for a human at a terminal: `"$B" mapping add` (hidden token prompt, arrow-key chat picker, confirmation of the detected Telegram sender).

## Inspect and operate

| Goal | Command |
|---|---|
| List mappings | `"$B" mapping list --json` |
| Health per mapping | `"$B" status --json` → `verdict`: `ok`, `paused`, `halted`, `error`, `stale`, `unknown`; `lastErrorCode` (stable code) |
| Why a check failed | `"$B" doctor --json` → each check's `code` (`TOKEN_FORMAT`, `CHATDB_UNREADABLE`, `TELEGRAM_UNAUTHORIZED`, …; table in README "Machine-readable checks"). `--lang en` for English text |
| Check one mapping (sends nothing) | `"$B" mapping test <id> --json` |
| Check everything with the binary's own permissions | `bash scripts/agent-run.sh doctor --telegram --json` |
| Pause / resume one mapping | `"$B" mapping pause <id>`, `"$B" mapping resume <id>` |
| Clear a safety halt | `"$B" resume --mapping <id>` (or `/resume` in that bot chat) |
| Remove | `"$B" mapping remove <id>` (deletes its Keychain token; `--keep-token` keeps it, `--purge-state` also drops its state rows) |
| Restart the service | `launchctl kickstart -k "gui/$(id -u)/dev.kanziw.bluehop"` |
| Logs (no message text) | `tail -n 50 ~/Library/Logs/bluehop.log` — lines are prefixed `[<mapping id>]` |

Exit codes: `0` ok · `1` failure (check failed, network, Keychain) · `2` usage · `3` conflict (same chat, same bot, same id) · `4` not found · `5` timed out waiting for a Telegram message · `130` cancelled.

With `--json`, errors are printed on stdout as `{"ok": false, "error": {"kind", "message", "exitCode"}}`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `status` verdict `error`, `lastError` mentions `401` or "토큰이 거부됨" | Bot token revoked or wrong | Human makes a new token; `mapping remove <id>` then `mapping add` |
| `lastError` mentions `409` | Another program polls the same bot (or a webhook is set) | Stop the other consumer; one bot per mapping |
| verdict `stale` | Worker is not polling (service stopped, or it is backing off) | `status` → `service.running`; `launchctl kickstart -k …`; read the log |
| verdict `halted` | Safety halt (too many messages, or > 50 waiting at start) | `resume --mapping <id>` or `/resume skip` in that bot chat |
| `chats` says it re-runs through launchd, then fails | Installed binary lacks Full Disk Access | HUMAN grants Full Disk Access to the installed binary |
| `mapping add` exit 3 | Chat or bot already linked, or id taken | `mapping list --json`; choose another bot or chat |
| `mapping add` exit 5 | No message reached the bot in time | Ask the human to message the bot, rerun with a longer `--wait` |
| `매핑 충돌` when the service starts | Hand-edited config links one chat or bot twice | Fix with `mapping remove`; never reuse a bot |
| Keychain prompt "bluehop wants to access" | Binary was re-signed (ad-hoc builds) | HUMAN clicks Always Allow |

## Limits (do not promise)

No group chats. No real iMessage threaded replies or tapbacks from Telegram (a quoted prefix is sent instead). No edit or unsend mirroring. Text up to 4000 characters and files up to 20 MB to iMessage. Bot replies, logs and most CLI text are in Korean (`doctor`, `mapping test`, `status` take `--lang en`); JSON keys, check codes and exit codes are stable.
