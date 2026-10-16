# Agent guide: install, operate, verify, troubleshoot

For AI agents (and people) setting up bluehop, an iMessage to Telegram relay (one Telegram bot per linked chat), on a Mac. Every step has a check. Steps marked **HUMAN** cannot be done by an agent: macOS requires a person to approve them, or they involve a secret. Stop and ask the human at those steps; do not work around them.

The binary is `bluehop`; the LaunchAgent label and Keychain service are `dev.kanziw.bluehop`. A **mapping** links one iMessage 1:1 chat to one Telegram bot; one relay process runs every enabled mapping. A shorter task-oriented version of this guide for agents is the skill file [`skills/bluehop/SKILL.md`](../skills/bluehop/SKILL.md).

Every command and every script in `scripts/` has `--help`/`-h`, which prints help and exits 0 before doing anything (also after an unknown flag or in another flag's value slot); unknown flags fail with exit code 2. Read commands take `--json`; `doctor`, `mapping test` and `status` have stable error codes in their JSON (README "Machine-readable checks") and `--lang en` for English text. Exit codes: `0` ok, `1` failure, `2` usage, `3` conflict (same chat, same bot, same id), `4` not found, `5` timed out waiting for a Telegram message, `130` cancelled.

The relay's own output (errors, logs, bot replies, and `doctor`/`status` unless `--lang en`) is in Korean. The exact strings to look for are quoted below; prefer the JSON codes.

## 0. Preconditions

```bash
sw_vers -productVersion   # 14.0 or newer (built and run on 26.0.1 so far)
xcodebuild -version       # full Xcode; swift test needs XCTest
swift --version
git clone https://github.com/kanziw/bluehop && cd bluehop
```
Scope check: each linked iMessage 1:1 chat needs its own Telegram bot; several chats can be linked. If the user wants group chats, every chat at once through one bot, Linux, Windows, or a hosted service, stop: not supported.

Agents must not: grant macOS permissions, type or read the bot token, or send real messages to the user's contacts. Many commands below change state; check the table before running one.

### Side effects of every command

Checked against the code of 0.5.1 (`Sources/BluehopCLI/Commands.swift`, `scripts/*.sh`). Classes: **read-only** (reads files, the Messages database or the Keychain, changes nothing), **local write** (changes files, the Keychain or launchd on this Mac), **external request** (calls `api.telegram.org` or GitHub, delivers nothing to a person), **message delivery** (a message reaches a person: the iMessage contact, or you in a Telegram bot chat). `--help` and `-h` are read-only for every command and script.

`"$B" …` is the installed binary. "Running relay" means the LaunchAgent `dev.kanziw.bluehop` is running: it re-reads `config.json` and the state database about every 5 seconds, so a local write can cause delivery a few seconds later.

| Command | Class | What it does beyond reading |
|---|---|---|
| `version`, `mapping list`, `selfcheck-attributed`, `diag-echo`, `diag-audio` | read-only | Nothing. `diag-audio` opens audio attachment files to read their format; `diag-echo --expect-file` reads that file. |
| `chats` / `list-chats` | read-only | When the terminal lacks Full Disk Access and the binary is installed: creates and removes a temporary launchd job (`dev.kanziw.bluehop.oneshot.<pid>`, plist in `$TMPDIR`) to read with the binary's permission. |
| `status` | read-only | Runs `launchctl print` (read-only). Opening a 0.4 state database migrates it once to the 0.5 layout (**local write**, keeps `state.sqlite.v1-backup`). |
| `doctor` | read-only | Same temporary launchd job as `chats` when needed. `--messages` asks Messages.app over AppleScript whether the chat exists: **the first run shows the macOS Automation prompt** (a HUMAN must click Allow); nothing is sent. `--telegram`: **external request** `getMe`. |
| `mapping test <id>` | external request | `getMe` with that mapping's token. `--messages` as in `doctor` (Automation prompt). Sends nothing. |
| `telegram-ids` | external request | `getMe` and `getUpdates` without an offset, so pending Telegram updates are not consumed. Does not work while the running relay polls the same bot. |
| `mapping add` | local write + external request | `getMe`, `getUpdates` (peek, no offset), and `getMe` again for the final check (`--no-doctor` skips it). Writes the bot token to the Keychain (service `dev.kanziw.bluehop`, account `bot-token:<id>`; not with `--token-file`), writes `config.json` (a 0.4 config is rewritten in the 0.5 shape after a `config.json.v1-backup` copy). `--dry-run` writes nothing. **With a running relay, the new mapping starts relaying within about 5 seconds** (message delivery from then on; see `run`). |
| `mapping remove <id>` | local write | Rewrites `config.json` (with `.v1-backup` if it was 0.4), deletes the mapping's Keychain token (not with `--keep-token`), `--purge-state` deletes its rows from the state database. A running relay stops that mapping. |
| `mapping pause <id>` | local write | Sets `enabled: false` in `config.json` (with `.v1-backup` if it was 0.4). A running relay stops that mapping. |
| `mapping resume <id>` | local write → delivery | Sets `enabled: true`. **A running relay restarts that mapping**: waiting iMessages are relayed to Telegram, Telegram messages from while it was paused are sent to iMessage if younger than 10 minutes, older ones get a ⚠️ reply in Telegram. |
| `resume [--mapping ID] [--skip-backlog]` | local write → delivery | Clears the safety halt in the state database (creates it if missing); `--skip-backlog` also moves the iMessage cursor to the end. Sends nothing itself, but **a running relay then relays the waiting iMessages to Telegram** (none with `--skip-backlog`) and resumes sending Telegram replies to iMessage. |
| `run` | local write + external request + **message delivery** | The relay itself (what the LaunchAgent runs). Writes the state database and staging folders, polls Telegram, relays iMessage → Telegram and **sends iMessages to the linked contacts**. On a mapping's first start it skips old messages and posts `ℹ️ 켜기 전 메시지 N개는 보내지 않았습니다` to the bot chat if any were waiting; a safety halt posts `⏸ bluehop 안전 정지`. Never run it by hand next to the LaunchAgent. |
| `diag-send-file` | **message delivery** | **Sends the file (and `--caption`) to the real iMessage contact** of the mapping, after copying it into the staging folder. Only with the human's explicit go-ahead. The other `diag-*` commands send nothing. |
| `bash scripts/install.sh --no-load` | local write | Runs `check.sh` and `build-release.sh` (writes `.build/`, `dist/`; signs with a keychain identity). **Stops a running relay** (`launchctl bootout`) before copying the binary to `~/Library/Application Support/bluehop/bin/bluehop`, writes `~/Library/LaunchAgents/dev.kanziw.bluehop.plist`, and leaves the relay stopped. |
| `bash scripts/install.sh` | local write → **message delivery** | As above, then `doctor` through a temporary launchd job, then **starts the LaunchAgent: from here on messages are really relayed** in both directions for every enabled mapping. If doctor fails or there is no config, the relay stays stopped. Update (`git pull && bash scripts/install.sh`) is the same. |
| `bash scripts/uninstall.sh` | local write | Stops the LaunchAgent, deletes its plist, the binary and the `tmp`/`outbox` folders. Keeps config and state. |
| `bash scripts/uninstall.sh --purge` | local write, **irreversible** | Also deletes `~/Library/Application Support/bluehop` (config, state, every mapping) and every Keychain item of `dev.kanziw.bluehop`. |
| `bash scripts/agent-run.sh <command>` | depends on `<command>` | Creates and removes a temporary launchd job (`dev.kanziw.bluehop.oneshot`) that runs the installed binary with the given arguments; the command has its own side effects from this table. With `--help`/`-h` it runs the binary directly, without launchd. |
| `bash scripts/check.sh`, `bash scripts/build-release.sh` | local write | Build output in `.build/` and `dist/`; `build-release.sh` signs with a keychain identity (macOS may ask for keychain access). |
| `bash scripts/setup-dev.sh` | local write | `git config core.hooksPath .githooks` in the clone; creates `.git/info/pii-denylist`. |
| `bash scripts/publish-site.sh [--push]` | local write (+ external request with `--push`) | Commits `docs/site/` and `llms.txt` to the local `gh-pages` branch; `--push` pushes it to GitHub (maintainers only). |
| `launchctl kickstart -k …` / `bootstrap …` (section 9) | local write → **message delivery** | (Re)starts the relay; same effects as `run`. |
| `/status`, `/pause`, `/resume` in a bot chat | — | Sent by the human in Telegram. `/resume` releases waiting messages like `resume`. |

**Where real relaying becomes possible:** only a running relay delivers messages. It starts with `bash scripts/install.sh` (without `--no-load`) or `launchctl bootstrap`/`kickstart`, and after that `mapping add`, `mapping resume` and `resume` take effect within seconds. Running `run` by hand does the same. `diag-send-file` delivers on its own, even with the relay stopped.

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
"$B" mapping add --token-stdin --chat '<guid>' --id <slug> --wait 180 --json < "$TOKEN_FILE"   # $TOKEN_FILE: path the human gave
```
- The token comes from stdin only. There is no flag that takes the token value. **The human** creates the token file (for example `umask 077; pbpaste > ~/bluehop-token` right after copying the token from @BotFather), tells the agent the path, and **deletes it after `mapping add` succeeds** (`rm ~/bluehop-token`; the token is then in the Keychain). The agent only redirects the file into stdin as shown; it never opens, prints, copies or `cat`s the file, and never asks for the token in chat. Or the human runs the command and pipes the token themselves.
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
tail -n 20 "$HOME/Library/Logs/bluehop-events.jsonl"
```
Expect `service.running: true` and, within a few seconds, `verdict: "ok"` for every enabled mapping. Log lines: `시작 v<version> 매핑 N개(켜짐 N개)`, then per mapping `[<id>] 일꾼 띄움`, `[<id>] 시작 halted=false`; the first start of a mapping also logs `기준선 커서 설정` and `텔레그램 기준선 설정`. The log never contains message text. Then the human sends `/status` in the bot chat and gets `▶️ 동작 중`. Do not send test messages to the real contact without the human's say-so.

`bluehop-events.jsonl` is the structured (one JSON object per line) sibling log — one line per step of a request (received, send start/end with its duration, send retries `im_send_retry` and skipped resends `im_resend_skipped`, echo wait/match/give-up, warning sent, reaction/attachment, getUpdates error/retry, start/halt/resume), each tagged with the mapping id and whatever correlation id applies (Telegram update/message id, chat.db rowid). It rotates by size on its own (`RotatingFileLog`, default 10 MB × 5 files) — `scripts/install.sh` does not need to logrotate it. `bluehop status`/`doctor` print both log paths and the active level. Reconstructing a past incident (e.g. a send that looked ambiguous): read this file instead of asking the operator to reproduce it; it never has message text, phone numbers, Apple IDs or the token at the default `info` level. `BLUEHOP_LOG_LEVEL=debug` in the LaunchAgent's `EnvironmentVariables` adds step-by-step detail (still no bodies); `BLUEHOP_LOG_BODIES=1` on top of that lets the few call sites that opt in also log message text — turn it on only for a short, deliberate debugging window, never left on.

## 7. Link another chat

Repeat step 1 (a new bot) and step 4. The running relay notices the config change within about 5 seconds and starts the new mapping; nothing else is restarted. Check with `"$B" status --json`. The same iMessage chat, or a bot that is already linked, is refused with exit code 3.

## 8. Upgrade from 0.4.x

**Warning:** after the gate and the build pass, `bash scripts/install.sh` stops the running relay (`launchctl bootout`), replaces the binary, runs `doctor`, and only then starts the LaunchAgent again. From the stop until the new start nothing is relayed in either direction (after the start, waiting iMessages are relayed, or trigger a safety halt if more than 50 are waiting; Telegram messages older than 10 minutes by then are not sent and get a ⚠️). If `doctor` fails, or with `--no-load`, the relay **stays stopped** with the new binary in place: fix the cause and run `bash scripts/install.sh` again, or start it anyway with `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/dev.kanziw.bluehop.plist"`. Upgrade when a few minutes without relaying are acceptable. The same applies to every later update.

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
| Update | `git pull && bash scripts/install.sh` (permissions survive when the same signing identity is used; the relay is down while it runs, see section 8) |
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
