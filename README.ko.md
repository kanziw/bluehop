# bluehop: iMessage 를 텔레그램으로, 대화마다 봇 하나로 잇는 중계기

**bluehop** 은 iMessage 대화를 텔레그램 봇 대화로 전달하고, 텔레그램에서 쓴 답장을 같은 iMessage 대화로 보내는 **iMessage 텔레그램 중계기**입니다. 대화 하나만 이어도 되고 여러 개를 이어도 됩니다 — 이은 대화마다 텔레그램 봇이 하나씩이고, 프로세스 하나가 모두 중계합니다. "아이메시지를 텔레그램으로 받기", "iMessage 텔레그램 봇 전달"을 내 맥 한 대에서 직접(셀프 호스팅) 합니다. 서명된 Swift 바이너리 하나, 외부 라이브러리 0개, 웹 화면 없음, 열린 포트 없음, 클라우드 없음. 메시지 앱에 로그인된 내 맥에서 돕니다.

> Apple Inc. 및 Telegram 과 제휴·보증·후원 관계가 없습니다. iMessage 와 Messages 는 Apple Inc. 의 상표이고, Telegram 은 해당 소유자의 상표입니다.

[English README](README.md) · [에이전트 가이드(설치·운영·확인·문제 해결, 영어)](docs/AGENT-GUIDE.md) · [에이전트 스킬](skills/bluehop/SKILL.md) · [보안](SECURITY.md) · [설계 SPEC](SPEC.md) · [llms.txt](llms.txt)

```
iMessage 상대 ── 내 맥의 메시지 앱 ──┐
                                      │ chat.db (읽기 전용)
                        bluehop (이 맥) ──── https://api.telegram.org ──── 이은 대화마다 텔레그램 봇 하나(나와 1:1)
                                      │ AppleScript send (고정 스크립트, 값은 argv)
                                      └── 메시지 앱 → 같은 상대
```

## 왜 만들었나

iMessage 로만 대화할 수 있는 상대가 있습니다. 예를 들어 iMessage 로만 연결되는 AI 비서나 가족 한 명. 하루 대부분(그리고 다른 에이전트들)이 텔레그램에 있다면, 그 대화 하나를 텔레그램에서 읽고 답할 수 있게 합니다. iMessage 는 메시지 앱에 로그인된 맥이 있어야 하므로 호스팅 서비스가 아니라 내 맥에서 직접 돌립니다.

## 하는 일

- **iMessage → 텔레그램:** 글, 답글 관계(텔레그램 진짜 답글), 반응(봇이 쓸 수 있는 이모지면 텔레그램 진짜 반응, 아니면 짧은 답글), 사진(HEIC→JPEG), 음성 메모(.caf→.m4a), 영상, 파일.
- **텔레그램 → iMessage:** 글, 사진, 음성(.ogg→.m4a), 영상, 파일(20MB 까지). 그 봇에 이은 대화로만 보냅니다. 보낸 뒤 메시지 앱 기록(chat.db)에서 확인하고, 실패만 ⚠️ 답글로 알립니다. 자동 재발송은 없고, 같은 텔레그램 메시지를 두 번 보내지 않습니다.
- **여러 대화:** 연결("매핑") 하나는 iMessage 1:1 대화 하나와 그 대화 전용 텔레그램 봇 하나입니다. 매핑들은 한 프로세스에서 나란히 돌고 서로 격리됩니다 — 한 매핑의 토큰 폐기·네트워크 오류·안전 정지가 다른 매핑을 멈추지 않습니다. `bluehop mapping …` 으로 추가·조회·멈춤·삭제합니다.
- iPhone 이나 다른 맥에서 직접 보낸 글도 `🙋 나:` 를 붙여 텔레그램에 보여 줍니다(`mirrorOwnMessages`, 기본 켬).
- 봇 안내 문구·`doctor` 출력·로그는 지금 한국어입니다. 중계되는 본문은 그대로 전달됩니다.

## 하지 않는 일

일부러 작게 만들었습니다. 모든 대화를 잇는 브리지(대화마다 직접 골라 봇을 따로 붙입니다)·단체방 브리지, 호스팅 서비스, 범용 iMessage API 가 아닙니다. 시스템 무결성 보호(SIP)를 끄라고 하지 않습니다. 자세한 것은 [한계](#한계).

## 다른 도구와 비교

넷 다 메시지 앱에 로그인된 맥에서 `chat.db` 를 읽습니다. 아래 내용은 각 프로젝트의 README·공식 문서 기준입니다(2026-10-15 확인).

| | bluehop | [chatwire](https://github.com/allenbina/chatwire) | [BlueBubbles](https://bluebubbles.app/) | [mautrix-imessage](https://github.com/mautrix/imessage) |
|---|---|---|---|---|
| 어디서 쓰나 | 이은 대화마다 텔레그램 봇 대화 하나 | 웹 화면, 텔레그램(플러그인), 푸시, 기타 플러그인 | 안드로이드·윈도우·리눅스·웹용 BlueBubbles 앱 | Matrix 클라이언트 |
| 대화 범위 | 고른 1:1 대화들, 대화마다 봇 하나 | 전체(단체방 포함) | 전체(단체방 포함) | 전체(단체방 포함) |
| 포트를 여나 | 아니오(텔레그램으로 나가는 HTTPS 만) | 예, 웹 화면. README 에 "기본은 인증 없음, 네트워크 단에서 막을 것"이라고 적혀 있음 | 예, 서버. 내장 프록시(ngrok, Cloudflare)나 포트 포워딩으로 접속 | Matrix 홈서버와 웹소켓 프록시 필요 |
| 기술 | Swift, 외부 패키지 0개 | Python + React | TypeScript(Node) | Go |
| iMessage 로 진짜 답글·반응 보내기 | 안 됨(인용 글로 대신) | 해당 문서 참고 | Private API 로 가능, SIP 해제 필요 | 기본 macOS 커넥터는 불가, SIP 해제가 필요한 커넥터나 BlueBubbles 커넥터로 가능 |
| 라이선스 | MIT | MIT | Apache-2.0(서버) | AGPL-3.0 |

모든 대화나 풍부한 클라이언트가 필요하면 전체 브리지를, 고른 대화 몇 개를 텔레그램에서 가장 작은 공격면으로 쓰고 싶으면 bluehop 을 고르세요.

## 필요한 것

- 켜져 있고 로그인된 맥, 메시지 앱 로그인. 패키지 최소 사양은 macOS 14 이고, 실제로 빌드·실행해 본 것은 macOS 26.0.1 뿐입니다.
- Xcode(`swift build`·`swift test` 용, Xcode 26.2 / Swift 6.2.3 에서 확인).
- 텔레그램 계정과 @BotFather 에서 받은 봇 토큰.
- 시스템 설정에서 이 바이너리에 **전체 디스크 접근**과 **자동화(메시지)** 를 허용해 줄 사람.
- 권장: 키체인의 Apple Development 또는 Developer ID 서명 인증서. 없으면 ad-hoc 서명이 되어 재설치마다 두 권한을 다시 허용해야 합니다.

## 설치

단계마다 확인 명령이 있는 전체 절차: **[docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md)**. 요약:

0. `git clone https://github.com/kanziw/bluehop && cd bluehop`
1. 텔레그램 @BotFather → `/newbot` → 토큰 받기. 이을 대화마다 봇이 하나씩 필요합니다.
2. `bash scripts/install.sh --no-load` — 로컬 게이트, 빌드·서명, `~/Library/Application Support/bluehop/bin/bluehop` 배치, LaunchAgent plist 생성. 아무것도 켜지 않습니다.
3. 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 → `+` → ⌘⇧G → `~/Library/Application Support/bluehop/bin/bluehop`. 이 바이너리에만 주고 터미널에는 주지 않습니다.
4. 첫 대화 잇기:
   ```bash
   B="$HOME/Library/Application Support/bluehop/bin/bluehop"
   "$B" mapping add
   ```
   봇 토큰을 (화면에 안 보이게) 묻고, 텔레그램으로 확인하고, iMessage 대화를 화살표 키로 고르게 하고, 봇에게 아무 글이나 보내 달라고 해서 텔레그램 id 를 알아낸 뒤, 토큰을 Keychain 에 넣고 점검합니다. 터미널에 전체 디스크 접근이 없어도 됩니다 — 메시지 DB 를 못 읽으면 설치된 바이너리를 launchd 로 한 번 돌려 대화 목록을 받습니다.
5. `bash scripts/agent-run.sh doctor --messages --telegram`. "bluehop 이 메시지 앱을 제어하려 함" 창이 뜨면 **허용**. 모두 ✔ 면 `bash scripts/install.sh` 로 LaunchAgent 를 켭니다.
6. 그 봇의 텔레그램 대화에서 `/status`.

나중에 대화를 더 이으려면 봇을 하나 더 만들고 `mapping add` 를 다시 실행합니다. 실행 중인 중계기가 약 5초 안에 새 매핑을 시작합니다(재시작 불필요).

에이전트·스크립트는 모든 값을 옵션으로 주고 토큰은 표준입력으로 넘깁니다(명령줄 인자로는 받지 않음):

```bash
printf '%s\n' "$TOKEN" | "$B" mapping add --token-stdin --chat '+15555550123' --id family --json
```

## CLI

모든 명령에 `--help`, 조회 명령에 `--json`. 모르는 옵션은 오류입니다. 명령 표와 옵션: [README.md 의 CLI](README.md#cli).

| 명령 | 하는 일 |
|---|---|
| `bluehop chats` | 이 맥의 iMessage 1:1 대화 목록(본문 없음) |
| `bluehop mapping list` / `add` / `remove ID` / `pause ID` / `resume ID` / `test ID` | 매핑 조회·추가·삭제·멈춤·재개·점검 |
| `bluehop doctor [--mapping ID]` | 점검(보내지 않음) |
| `bluehop status` | 매핑별 마지막 텔레그램 확인 시각·마지막 오류·안전 정지, LaunchAgent 실행 여부 |
| `bluehop resume [--mapping ID]` | 안전 정지 해제 |

종료 코드: `0` 성공, `1` 실패, `2` 사용법 오류, `3` 충돌(같은 대화·같은 봇·같은 id), `4` 없음, `5` 텔레그램 메시지 기다림 시간 초과, `130` 취소.

## 설정

`~/Library/Application Support/bluehop/config.json`(0600, 폴더 0700. 더 넓으면 시작을 거부합니다). `bluehop mapping add` 가 쓰므로 손으로 고칠 일은 드뭅니다. 키 설명은 [README.md 의 Configuration 표](README.md#configuration)와 [SPEC.md §5](SPEC.md).

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

읽고 쓸 때마다 검사하는 규칙: id 는 겹치지 않고, iMessage 대화(guid 또는 handle)는 한 매핑에만, 봇 토큰도 한 매핑에만 씁니다(텔레그램 `getUpdates` 는 봇마다 받는 쪽이 하나뿐). 0.4 설정(최상위 `telegram`·`imessage`)도 그대로 읽습니다 — 옛 Keychain 계정 `telegram-bot-token` 을 쓰는 매핑 `default` 하나로 봅니다. 처음으로 무언가를 바꾸는 `bluehop mapping` 명령이 새 모양으로 다시 쓰고 `config.json.v1-backup` 을 남깁니다.

## 텔레그램 명령

봇마다 자기 매핑만 다룹니다: `/status`, `/pause`, `/resume`. 밀린 iMessage 가 50건을 넘으면 `/resume skip`(건너뛰기) 또는 `/resume all`(모두 보내기)을 고르라고 합니다. `/` 로 시작하는 글을 보내려면 `//`.

## 한계

| | iMessage → 텔레그램 | 텔레그램 → iMessage |
|---|---|---|
| 글 | ✅ 4000자 넘으면 나눠 보냄 | ✅ 4000자까지 |
| 답글 | 원문을 알면 진짜 답글, 아니면 `↪ "인용…"` | 공개 방법 없음 → `↪ "원문 앞부분…"` 을 붙여 보냄 |
| 반응 | 봇이 쓸 수 있는 이모지는 진짜 반응(😂→🤣, ❓→🤔), ‼️ 등은 짧은 답글. 취소도 반영 | 공개 방법 없음 → 기본은 무시, `"text"` 모드면 글로(1:1 봇 대화에서 텔레그램이 반응 업데이트를 주는지는 아직 미확인) |
| 첨부 | 50MB 까지(넘으면 안내 글), GIF·10MB 넘는 사진은 파일로 | 20MB 까지(봇 내려받기 한도) |
| 다른 기기에서 보낸 내 글 | `🙋 나:` | — |
| 수정·보내기 취소 | ✘ | ✘ (텔레그램 수정은 "반영 안 됨" 안내만) |
| 텔레그램 스티커 | — | 보내지 않음(⚠️) |
| 단체방 | ✘ | ✘ |
| 여러 대화 | ✅ 대화마다 봇 하나 | ✅ 봇마다 자기 대화로만 |

안전장치(매핑마다 따로): 텔레그램으로 분당 20건, iMessage 로 분당 10건(넘으면 기다림). 10분에 텔레그램 120건·iMessage 40건을 넘으려 하거나 시작 시 밀린 iMessage 가 50건을 넘으면 양방향을 멈추고 알립니다. 처리 시점에 10분 넘게 지난 텔레그램 글은 보내지 않고 ⚠️ 로 알립니다. 처음 켜기 전 봇에게 보낸 글은 한 번 건너뛰고 안내합니다. 근거: [docs/imessage-limits.md](docs/imessage-limits.md).

## 보안 요지

리스닝 소켓·웹 서버 없음. 나가는 곳은 코드에 고정된 `https://api.telegram.org` 하나. chat.db 는 읽기 전용, 모든 질의는 설정한 대화로 한정. 전체 디스크 접근은 서명된 이 바이너리에만. osascript 에는 고정 스크립트와 argv 만. 설정·상태·토큰 파일 0600. 로그에 본문·전화번호·토큰 없음. 남는 위험: 텔레그램 봇 대화는 종단간 암호화가 아니어서 중계된 내용이 텔레그램 서버에 남습니다. 자세히: [SECURITY.md](SECURITY.md).

## 운영

| 할 일 | 명령 |
|---|---|
| 점검(보내지 않음) | `bash scripts/agent-run.sh doctor --messages --telegram` |
| 모든 매핑 상태 | `bluehop status` (또는 봇 대화에서 `/status`) |
| 대화 추가·멈춤·삭제 | `bluehop mapping add`, `bluehop mapping pause ID`, `bluehop mapping remove ID` |
| 다시 시작 | `launchctl kickstart -k "gui/$(id -u)/dev.kanziw.bluehop"` |
| 업데이트 | `git pull && bash scripts/install.sh` |
| 로그 | `~/Library/Logs/bluehop.log`(본문 없음) |
| 제거 | `bash scripts/uninstall.sh`(설정·상태 유지) / `--purge`(설정·상태·모든 매핑의 Keychain 토큰까지 삭제) |

## 개발

```bash
bash scripts/setup-dev.sh      # 클론마다 한 번: .githooks/ 의 git 훅 켜기
bash scripts/check.sh          # 금지 패턴 + swift build + swift test
bash scripts/build-release.sh  # 서명된 dist/bluehop
```

기여·코딩 에이전트 규칙: [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md).

## 라이선스

[MIT](LICENSE)
