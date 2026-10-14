# Agent guide: install, operate, verify, troubleshoot

For AI agents (and people) setting up bluehop, an iMessage to Telegram relay for one chat, on a Mac. Every step has a check. Steps marked **HUMAN** cannot be done by an agent: macOS requires a person to approve them, or they involve a secret. Stop and ask the human at those steps; do not work around them.

The binary, its install paths, the LaunchAgent label and the Keychain service are still named `imsg-relay` / `dev.kanziw.imsg-relay`; the commands below use those real names.

The relay's own output (`doctor`, errors, logs, bot replies) is in Korean. The exact strings to look for are quoted below.

## 0. Preconditions

```bash
sw_vers -productVersion   # 14.0 or newer (built and run on 26.0.1 so far)
xcodebuild -version       # full Xcode; swift test needs XCTest
swift --version
git clone https://github.com/kanziw/bluehop && cd bluehop
```
Scope check: this tool links ONE iMessage 1:1 chat to ONE Telegram chat. If the user wants group chats, several chats, Linux, Windows, or a hosted service, stop: not supported.

Agents must not: grant macOS permissions, type or read the bot token, or send real messages to the user's contacts. `diag-send-file` really sends; run it only with the human's explicit go-ahead. Every other command below only reads.

## 1. Telegram bot (HUMAN)

The human opens @BotFather in Telegram, sends `/newbot`, picks a name, and keeps the token. Then opens a chat with the new bot and sends any message (step 5 needs one message to learn the ids). That message is never relayed: on the very first start the relay skips everything sent before it and posts a one-time notice.

## 2. Build and install the files

```bash
bash scripts/install.sh --no-load
```
It runs `scripts/check.sh` (forbidden-pattern scan, `swift build`, `swift test`), builds a signed release into `dist/imsg-relay`, copies it to `~/Library/Application Support/imsg-relay/bin/imsg-relay` (mode 700), writes `~/Library/LaunchAgents/dev.kanziw.imsg-relay.plist`, and creates `config.json` from `packaging/config.example.json` if missing. `--no-load` does not start anything. Note: it stops a running relay before replacing the binary (`launchctl bootout`), so on an existing install use `bash scripts/install.sh` (without `--no-load`) to get it running again.

Verify:
```bash
B="$HOME/Library/Application Support/imsg-relay"
test -x "$B/bin/imsg-relay" && echo binary ok
"$B/bin/imsg-relay" version
stat -f '%Lp' "$B" "$B/config.json"     # 700 and 600
codesign -dv "$B/bin/imsg-relay" 2>&1 | grep -E '^(Identifier|TeamIdentifier)='
```
Signing identity order: `IMSG_RELAY_CODESIGN_IDENTITY`, then the first "Developer ID Application" or "Apple Development" identity in the keychain, then ad-hoc (`-`). Ad-hoc prints `서명 인증서 없음 — ad-hoc 서명` and means the human must re-grant permissions (steps 4 and 7) after every reinstall.

## 3. Store the bot token (HUMAN)

The human runs this in their own terminal and pastes the token at the prompt (it stays out of shell history):
```bash
security add-generic-password -s dev.kanziw.imsg-relay -a telegram-bot-token \
  -T "$HOME/Library/Application Support/imsg-relay/bin/imsg-relay" -w
```
Never ask for the token in chat. Alternative without the Keychain: put the token in a file the user owns with mode 0600 and set `"tokenSource": "file"`, `"tokenFile": "~/path/to/token"` in step 6. The relay rejects the file if it is group- or world-readable or owned by someone else, and rejects any token that does not look like `<digits>:<letters, digits, _ or ->`.

## 4. Full Disk Access for the binary only (HUMAN)

System Settings → Privacy & Security → Full Disk Access → `+` → press ⌘⇧G → `~/Library/Application Support/imsg-relay/bin/imsg-relay` → turn it on. Do not add Terminal or any shell. `scripts/agent-run.sh` runs the binary through launchd (a one-shot job `dev.kanziw.imsg-relay.oneshot`) so it uses the binary's own permission.

## 5. Find the ids

```bash
bash scripts/agent-run.sh telegram-ids   # prints: chatId=<n>  allowedUserId=<n>  (private)
bash scripts/agent-run.sh list-chats     # prints: chatGuid <TAB> handle, 30 most recent 1:1 chats
```
- Run `telegram-ids` **before** the relay service is running. A running relay consumes the bot's updates (and two pollers conflict), so the ids may not show up. If it prints `최근 메시지가 없습니다`, ask the human to send the bot a message and run it again. With `--token-file <path>` it reads the token from a file instead of the Keychain.
- `list-chats` output contains phone numbers and email addresses. Do not paste it into logs, issues or chat. Show the human only the line they need.
- Pick the chat the human named. 1:1 guids look like `any;-;<handle>` (older ones may start with `iMessage;-;` or `SMS;-;`). Confirm the handle with the human before writing it: a wrong handle sends messages to the wrong person.

## 6. Fill config.json

File: `~/Library/Application Support/imsg-relay/config.json`, mode 0600 in a 0700 folder.
```json
{
  "telegram": { "chatId": 123456789, "allowedUserId": 123456789, "tokenSource": "keychain", "tokenFile": null },
  "imessage": { "chatGuid": "any;-;+15555550123", "handle": "+15555550123" },
  "relay": { "mirrorOwnMessages": true, "telegramReactionMode": "ignore", "outboxDirectory": null }
}
```
Key meanings: [README Configuration](../README.md#configuration). Verify:
```bash
C="$HOME/Library/Application Support/imsg-relay/config.json"
plutil -convert json -o /dev/null "$C" && echo valid-json
stat -f '%Lp' "$C"   # 600
```

## 7. Doctor, then start

```bash
bash scripts/agent-run.sh doctor --messages --telegram; echo "exit=$?"
```
Expected (each line starts with ✔, exit 0):
```
✔ 설정 파일 (0600): …/config.json
✔ 봇 토큰: 읽음 (keychain)
✔ chat.db 읽기 전용 열기 + 대화 검증: 1:1 대화 확인 (chat rowid N)
✔ 메시지 앱에 대화 존재 (자동 제어): 있음
✔ 텔레그램 getMe: @<bot username>
```
The first `--messages` run shows a macOS prompt asking whether imsg-relay may control Messages. **HUMAN**: click Allow. `doctor` never sends a message.

Only after doctor passes:
```bash
bash scripts/install.sh
```
`install.sh` repeats the gate and the build, runs `doctor` again (without `--messages`/`--telegram`), and only then `launchctl bootstrap`s the LaunchAgent. If doctor fails it prints `doctor 실패 — LaunchAgent 를 켜지 않았습니다` and leaves the service stopped.

## 8. Verify it is running

```bash
launchctl print "gui/$(id -u)/dev.kanziw.imsg-relay" | grep -E '^\s*(state|pid|last exit code) '
tail -n 20 "$HOME/Library/Logs/imsg-relay.log"
```
Expect `state = running`, a pid, and a log line `시작 v0.4.0 halted=false`. The first start also logs `기준선 커서 설정` and `텔레그램 기준선 설정`. The log never contains message text. Then the human sends `/status` in Telegram and gets `▶️ 동작 중`. Do not send test messages to the real contact without the human's say-so.

## 9. Operate

| Task | Command |
|---|---|
| Status | `/status` in Telegram |
| Pause / resume | `/pause`, `/resume` (`/resume skip` drops waiting iMessages, `/resume all` sends them) |
| Resume after a safety halt from the Mac | `bash scripts/agent-run.sh resume` or `... resume --skip-backlog` |
| Restart | `launchctl kickstart -k "gui/$(id -u)/dev.kanziw.imsg-relay"` |
| Stop | `launchctl bootout "gui/$(id -u)/dev.kanziw.imsg-relay"` |
| Start again | `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.kanziw.imsg-relay.plist"` |
| Update | `git pull && bash scripts/install.sh` (permissions survive when the same signing identity is used) |
| Uninstall | `bash scripts/uninstall.sh` (keeps config and state) or `--purge` (also config, state and the Keychain item) |
| Version | `"$HOME/Library/Application Support/imsg-relay/bin/imsg-relay" version` |

The CLI has no `--help` and ignores unknown flags: `imsg-relay <command> --help` runs the command. Run the binary with no arguments to see usage. After uninstall, the human should remove imsg-relay from the Full Disk Access and Automation lists. `uninstall.sh` does not delete the log file or the attachment staging folder `~/Library/Caches/com.apple.MobileSMS/imsg-relay-outbox`.

## 10. Troubleshooting

| Symptom (exact text) | Likely cause | Fix |
|---|---|---|
| `설치된 바이너리가 없습니다` from agent-run.sh | Step 2 not run | Run step 2 |
| `파일 없음: …/config.json` | Config not created | Run step 2 |
| `권한이 너무 넓다: <path> (644)` | Config, token file or folder is group/world accessible | `chmod 600` the file or `chmod 700` the folder |
| `설정 오류: telegram.chatId 가 비었다` / `allowedUserId 가 비었다` | Template values still 0 | Step 5 and 6 |
| `설정 오류: imessage.chatGuid 는 1:1 대화 형식(…;-;…)이어야 한다` | Placeholder or a group guid | Copy a guid from `list-chats` |
| `봇 토큰: Keychain 에서 읽지 못함 (OSStatus -25300)` | No Keychain item | Step 3 (HUMAN) |
| Keychain prompt "imsg-relay wants to access" after reinstall | Binary signature changed | HUMAN: Always Allow |
| `봇 토큰: 형식이 맞지 않다` | Wrong or truncated token | Redo step 3 |
| chat.db step fails with an SQLite open error, or `list-chats` ends with `전체 디스크 접근 권한이 … 있어야 합니다` | Full Disk Access missing, or reinstall with ad-hoc signing | Step 4 (HUMAN) |
| `설정한 chatGuid 의 대화를 chat.db 에서 찾지 못했다` | Wrong guid | `list-chats` again |
| `1:1 대화가 아니다` / `대화 참가자가 설정의 handle 과 다르다` | Group chat, or `handle` differs | Use a 1:1 chat and its exact handle |
| `메시지 앱에서 chat id 를 찾지 못함` or osascript error -1743 | Automation not allowed | Re-run doctor and click Allow; check System Settings → Privacy & Security → Automation |
| `텔레그램 getMe` fails with `401` / `Unauthorized` | Token revoked or wrong | New token from @BotFather, redo step 3 |
| `텔레그램 getMe` network error | No network to api.telegram.org | Check connectivity |
| Nothing arrives after start | Paused or safety halt (`⏸ imsg-relay 안전 정지` in Telegram) | `/status`, then `/resume` or `/resume skip` |
| `⚠️ 오래돼서 안 보냄` | The Telegram message was over 10 minutes old when processed | Send it again |
| `⚠️ 첨부를 둔 폴더를 메시지 앱이 읽을 수 없어` | `outboxDirectory` points outside the Messages sandbox | Set it to `null` |
| Telegram reactions do not reach iMessage | Default `"ignore"` | Set `telegramReactionMode` to `"text"` if wanted |
| `install.sh` stops at `✘ …` | Forbidden pattern, build or test failure | Read the ✘ line; full Xcode must be installed |
| Permissions asked again after every reinstall | Ad-hoc signing | Install an Apple Development certificate, or set `IMSG_RELAY_CODESIGN_IDENTITY` |

## 11. Hard limits (do not promise these)

No group chats, no multiple chats, no real iMessage threaded replies or tapbacks from Telegram (no public API; it would need SIP disabled, which this project will not do), no edit or unsend mirroring, no Telegram stickers, at most 4000 characters and 20 MB per item to iMessage. See [README Limits](../README.md#limits).

## 12. Rules for agents changing this repo

See [AGENTS.md](../AGENTS.md). In short: no dependencies, no listening sockets, no other hard-coded URLs, no write access to chat.db, no message text, phone numbers or tokens in logs, no real chat.db in tests, and `bash scripts/check.sh` before every commit.
