# Agent guide: install, operate, verify, troubleshoot

For AI agents (and people) setting up bluehop, an iMessage to Telegram relay (one Telegram bot per linked chat), on a Mac. Every step has a check. Steps marked **HUMAN** cannot be done by an agent: macOS requires a person to approve them, or they involve a secret. Stop and ask the human at those steps; do not work around them.

The binary is `bluehop`; the LaunchAgent label and Keychain service are `dev.kanziw.bluehop`. A **mapping** links one iMessage 1:1 chat to one Telegram bot; one relay process runs every enabled mapping. A shorter task-oriented version of this guide for agents is the skill file [`skills/bluehop/SKILL.md`](../skills/bluehop/SKILL.md).

Every command has `--help`, read commands take `--json`, and unknown flags fail with exit code 2. Exit codes: `0` ok, `1` failure, `2` usage, `3` conflict (same chat, same bot, same id), `4` not found, `5` timed out waiting for a Telegram message, `130` cancelled.

The relay's own output (`doctor`, errors, logs, bot replies) is in Korean. The exact strings to look for are quoted below.

## 0. Preconditions

```bash
sw_vers -productVersion   # 14.0 or newer (built and run on 26.0.1 so far)
xcodebuild -version       # full Xcode; swift test needs XCTest
swift --version
git clone https://github.com/kanziw/bluehop && cd bluehop
```
Scope check: each linked iMessage 1:1 chat needs its own Telegram bot; several chats can be linked. If the user wants group chats, every chat at once through one bot, Linux, Windows, or a hosted service, stop: not supported.

Agents must not: grant macOS permissions, type or read the bot token, or send real messages to the user's contacts. `diag-send-file` really sends; run it only with the human's explicit go-ahead. Every other command below only reads.

## 1. Telegram bot (HUMAN)

The human opens @BotFather in Telegram, sends `/newbot`, picks a name, and keeps the token. **One bot per chat to link**; a bot that is already linked is refused. Then the human opens a chat with the new bot and sends any message (step 4 uses it to learn the Telegram ids). That message is never relayed: on the first start of a mapping the relay skips everything sent before it and posts a one-time notice.

## 2. Build and install the files

```bash
bash scripts/install.sh --no-load
```
It runs `scripts/check.sh` (forbidden-pattern scan, `swift build`, `swift test`), builds a signed release into `dist/bluehop`, copies it to `~/Library/Application Support/bluehop/bin/bluehop` (mode 700) and writes `~/Library/LaunchAgents/dev.kanziw.bluehop.plist`. `--no-load` does not start anything. Note: it stops a running relay before replacing the binary (`launchctl bootout`), so on an existing install use `bash scripts/install.sh` (without `--no-load`) to get it running again.

Verify:
```bash
B="$HOME/Library/Application Support/bluehop/bin/bluehop"
test -x "$B" && echo binary ok
"$B" version
stat -f '%Lp' "$HOME/Library/Application Support/bluehop"     # 700
codesign -dv "$B" 2>&1 | grep -E '^(Identifier|TeamIdentifier)='
```
Signing identity order: `BLUEHOP_CODESIGN_IDENTITY`, then the first "Developer ID Application" or "Apple Development" identity in the keychain, then ad-hoc (`-`). Ad-hoc prints `서명 인증서 없음 — ad-hoc 서명` and means the human must re-grant permissions (steps 3 and 5) after every reinstall.

## 3. Full Disk Access for the binary only (HUMAN)

System Settings → Privacy & Security → Full Disk Access → `+` → press ⌘⇧G → `~/Library/Application Support/bluehop/bin/bluehop` → turn it on. Do not add Terminal or any shell. Commands that read the Messages database (`chats`, `doctor`, the chat picker of `mapping add`) notice when the terminal lacks the permission and re-run the read through a one-shot launchd job of the installed binary, which uses the binary's own permission. `scripts/agent-run.sh <command>` does the same for any command.

## 4. Add the mapping

**Option A, the human at a terminal (recommended for the first one):**
```bash
"$B" mapping add
```
It asks for the bot token (hidden input), checks it with Telegram (`getMe`), shows the local 1:1 chats to pick with the arrow keys (type to filter, Enter to pick, Esc to cancel; already linked chats cannot be picked), asks the human to send any message to the bot and confirms the detected Telegram user, asks for a mapping id, stores the token in the Keychain (service `dev.kanziw.bluehop`, account `bot-token:<id>`, trusted for the installed binary) and runs a check.

**Option B, the agent with flags (no prompts):**
```bash
"$B" chats --search "<part of the number or email>" --json     # pick the guid the human confirms
"$B" mapping add --token-stdin --chat '<guid>' --id <slug> --wait 180 --json < "$TOKEN_FILE"
```
- The token comes from stdin only. The human puts it into a file the agent never prints (mode 0600), or pipes it. There is no flag that takes the token value.
- `--chat` takes a guid (`any;-;…`, `iMessage;-;…`, `SMS;-;…`) or a handle; a handle picks that contact's most recently active 1:1 chat.
- Telegram ids: detected from a private message to the bot sent within the last 10 minutes or during `--wait` seconds. Several different senders → exit 3; then pass `--telegram-chat <id> --allowed-user <id>` (both or neither; `"$B" telegram-ids --token-stdin` lists recent senders).
- `--dry-run` checks everything and writes nothing. `--token-file PATH` keeps the token in that 0600 file instead of the Keychain.
- `chats --json` and `mapping list --json` contain phone numbers and email addresses. Do not paste them into logs, issues or chat.

Verify:
```bash
"$B" mapping list --json      # the new mapping, no token in the output
C="$HOME/Library/Application Support/bluehop/config.json"; stat -f '%Lp' "$C"   # 600
```

## 5. Doctor, then start

```bash
bash scripts/agent-run.sh doctor --messages --telegram; echo "exit=$?"
```
Expected (every check starts with ✔, exit 0):
```
✔ 설정 파일 (0600): …/config.json — 매핑 1개
[family]
  ✔ 봇 토큰: 읽음 (Keychain 계정 bot-token:family)
  ✔ chat.db 읽기 전용 열기 + 대화 검증: 1:1 대화 확인 (chat rowid N)
  ✔ 메시지 앱에 대화 존재 (자동 제어): 있음
  ✔ 텔레그램 getMe: @<bot username>
```
The first `--messages` run shows a macOS prompt asking whether bluehop may control Messages. **HUMAN**: click Allow. `doctor` never sends a message. Add `--mapping <id>` to check one mapping, `--json` for machine output.

Only after doctor passes:
```bash
bash scripts/install.sh
```
`install.sh` repeats the gate and the build, runs `doctor` again (without `--messages`/`--telegram`), and only then `launchctl bootstrap`s the LaunchAgent. If doctor fails it prints `doctor 실패 — LaunchAgent 를 켜지 않았습니다` and leaves the service stopped; without any config it prints `설정이 없어 LaunchAgent 를 켜지 않았습니다`.

## 6. Verify it is running

```bash
"$B" status --json
tail -n 20 "$HOME/Library/Logs/bluehop.log"
```
Expect `service.running: true` and, within a few seconds, `verdict: "ok"` for every enabled mapping. Log lines: `시작 v0.5.0 매핑 N개(켜짐 N개)`, then per mapping `[<id>] 일꾼 띄움`, `[<id>] 시작 halted=false`; the first start of a mapping also logs `기준선 커서 설정` and `텔레그램 기준선 설정`. The log never contains message text. Then the human sends `/status` in the bot chat and gets `▶️ 동작 중`. Do not send test messages to the real contact without the human's say-so.

## 7. Link another chat

Repeat step 1 (a new bot) and step 4. The running relay notices the config change within about 5 seconds and starts the new mapping; nothing else is restarted. Check with `"$B" status --json`. The same iMessage chat, or a bot that is already linked, is refused with exit code 3.

## 8. Upgrade from 0.4.x

A 0.4.x config (top-level `telegram` and `imessage`) keeps working: it is read as one mapping named `default` that uses the old Keychain account `telegram-bot-token`, and the state database is moved under `default` on the first start (a copy is kept as `state.sqlite.v1-backup`). The first `bluehop mapping` command that changes something rewrites the config in the new shape and keeps `config.json.v1-backup`.

## 9. Operate

| Task | Command |
|---|---|
| Health of every mapping | `"$B" status --json` (`verdict`: `ok`, `paused`, `halted`, `error`, `stale`, `unknown`) |
| Status inside one bot chat | `/status` in Telegram |
| List / add / remove / pause / resume / check a mapping | `"$B" mapping list`, `mapping add`, `mapping remove <id>`, `mapping pause <id>`, `mapping resume <id>`, `mapping test <id>` |
| Pause / resume from Telegram (that mapping only) | `/pause`, `/resume` (`/resume skip` drops waiting iMessages, `/resume all` sends them) |
| Resume after a safety halt from the Mac | `"$B" resume --mapping <id>` or `... --skip-backlog` |
| Restart | `launchctl kickstart -k "gui/$(id -u)/dev.kanziw.bluehop"` |
| Stop | `launchctl bootout "gui/$(id -u)/dev.kanziw.bluehop"` |
| Start again | `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.kanziw.bluehop.plist"` |
| Update | `git pull && bash scripts/install.sh` (permissions survive when the same signing identity is used) |
| Uninstall | `bash scripts/uninstall.sh` (keeps config and state) or `--purge` (also config, state and every mapping's Keychain token) |
| Version | `"$B" version` |

`mapping pause`, `resume`, `add` and `remove` take effect in the running relay within about 5 seconds. A paused mapping does not poll Telegram at all, so its bot does not answer `/status`; Telegram messages sent to it while paused for more than 10 minutes are not sent to iMessage when it resumes (each gets a ⚠️). After uninstall, the human should remove bluehop from the Full Disk Access and Automation lists. `uninstall.sh` does not delete the log file or the attachment staging folder `~/Library/Caches/com.apple.MobileSMS/bluehop-outbox`.

## 10. Troubleshooting

| Symptom (exact text) | Likely cause | Fix |
|---|---|---|
| `설치된 바이너리가 없습니다` from agent-run.sh | Step 2 not run | Run step 2 |
| `파일 없음: …/config.json` | No mapping added yet | Step 4 |
| `매핑 충돌: …` | The config links one chat or one bot twice (hand edit) | `"$B" mapping list`, then `mapping remove` the duplicate |
| `--mapping 이 필요합니다 (매핑 N개: …)` | Several mappings; the command needs to know which | Add `--mapping <id>` |
| `status` verdict `error` with `401` / `토큰이 거부됨` | That mapping's token was revoked | New token from @BotFather; `mapping remove <id>`, then `mapping add` |
| `status` verdict `error` with `409` | Another program polls the same bot, or a webhook is set | Stop it; one bot per mapping |
| `status` verdict `stale` | The worker is not polling (service stopped, or backing off after errors) | Check `service.running`, the log lines for that `[<id>]` |
| `mapping add` exits 5 | No message reached the bot in time | Send the bot a message, rerun with a longer `--wait` |
| `권한이 너무 넓다: <path> (644)` | Config, token file or folder is group/world accessible | `chmod 600` the file or `chmod 700` the folder |
| `설정 오류: [<id>] telegram.chatId 가 비었다` / `allowedUserId 가 비었다` | Hand-edited config with placeholder 0 | `mapping remove <id>` and `mapping add` |
| `설정 오류: [<id>] imessage.chatGuid 는 1:1 대화 형식(…;-;…)이어야 한다` | Placeholder or a group guid | Copy a guid from `"$B" chats` |
| `봇 토큰: Keychain(계정 …)에서 읽지 못함 (OSStatus -25300)` | No Keychain item for that mapping | `mapping remove <id> --keep-token`, then `mapping add` again |
| Keychain prompt "bluehop wants to access" after reinstall | Binary signature changed | HUMAN: Always Allow |
| `봇 토큰: 형식이 맞지 않다` | Wrong or truncated token | Copy the token again from @BotFather |
| chat.db step fails with an SQLite open error, or `chats` ends with `전체 디스크 접근 권한이 … 있어야 합니다` | Full Disk Access missing, or reinstall with ad-hoc signing | Step 3 (HUMAN) |
| `설정한 chatGuid 의 대화를 chat.db 에서 찾지 못했다` | Wrong guid | `"$B" chats` again |
| `1:1 대화가 아니다` / `대화 참가자가 설정의 handle 과 다르다` | Group chat, or `handle` differs | Use a 1:1 chat and its exact handle |
| `메시지 앱에서 chat id 를 찾지 못함` or osascript error -1743 | Automation not allowed | Re-run doctor and click Allow; check System Settings → Privacy & Security → Automation |
| `텔레그램 getMe` fails with `401` / `Unauthorized` | Token revoked or wrong | New token from @BotFather, then `mapping remove <id>` and `mapping add` |
| `텔레그램 getMe` network error | No network to api.telegram.org | Check connectivity |
| Nothing arrives after start | Mapping paused in the config, or safety halt (`⏸ bluehop 안전 정지` in Telegram) | `"$B" status`; `mapping resume <id>`, or `/resume` / `/resume skip` |
| `⚠️ 오래돼서 안 보냄` | The Telegram message was over 10 minutes old when processed | Send it again |
| `⚠️ 첨부를 둔 폴더를 메시지 앱이 읽을 수 없어` | `outboxDirectory` points outside the Messages sandbox | Set it to `null` |
| Telegram reactions do not reach iMessage | Default `"ignore"` | Set that mapping's `relay.telegramReactionMode` to `"text"` if wanted |
| `install.sh` stops at `✘ …` | Forbidden pattern, build or test failure | Read the ✘ line; full Xcode must be installed |
| Permissions asked again after every reinstall | Ad-hoc signing | Install an Apple Development certificate, or set `BLUEHOP_CODESIGN_IDENTITY` |

## 11. Hard limits (do not promise these)

No group chats, no linking several chats through one bot, no real iMessage threaded replies or tapbacks from Telegram (no public API; it would need SIP disabled, which this project will not do), no edit or unsend mirroring, no Telegram stickers, at most 4000 characters and 20 MB per item to iMessage. See [README Limits](../README.md#limits).

## 12. Rules for agents changing this repo

See [AGENTS.md](../AGENTS.md). In short: no dependencies, no listening sockets, no other hard-coded URLs, no write access to chat.db, no message text, phone numbers or tokens in logs, no real chat.db in tests, and `bash scripts/check.sh` before every commit.
