# iMessage 쪽 한계 조사 (구현 전, 2026-10-14)

이 문서는 구현을 시작하기 전에 "텔레그램 → iMessage 방향으로 답글·반응을 보낼 수 있는가"를 확인한 결과다.

## 1. 확인한 것

| 확인 | 방법 | 결과 |
|---|---|---|
| 메시지 앱의 AppleScript 사전 | `sdef /System/Applications/Messages.app` (macOS 26, Darwin 25.0.0) | 명령은 `send`(+ `to`), `login`, `logout` 셋뿐. 클래스는 `account`, `chat`, `participant`, `file transfer`. `reply`·`tapback`·`react`·`thread`·`edit` 에 해당하는 명령·속성 **0개** |
| chat.db 스키마 | `sqlite3 "file:…/chat.db?mode=ro" "pragma table_info(…)"` (스키마만, 내용 조회 없음) | 답글 = `message.thread_originator_guid`/`thread_originator_part`, 반응 = `associated_message_type`(2000~2007 추가, 3000~3007 취소)·`associated_message_guid`(`p:N/GUID`, `bp:GUID`)·`associated_message_emoji`(iOS 17+ 임의 이모지 반응, 타입 2006) |
| 1:1 대화 식별자 형식 | `chat.guid` 접두 집계(값은 보지 않음) | 1:1 은 `any;-;<handle>` 형식(style 45). 예전 `iMessage;-;`·`SMS;-;` 형식도 있을 수 있다 |
| 음성 변환 | `afconvert`(macOS 기본 도구)로 시험 | `.caf`(Opus) → `.m4a`(AAC) 가능, 텔레그램 음성(`.ogg` Opus) → `.m4a`/`.caf` **디코드 가능**. 단 `.ogg` Opus **인코드는 실패**(`ExtAudioFileClose failed ('pck?')`) |

## 2. 결론

### 텔레그램 → iMessage 답글
공개된 방법이 없다. AppleScript 의 `send` 는 "이 대화에 새 메시지"만 보낼 수 있다.
iMessage 의 진짜 답글(스레드)을 만드는 길은 비공개 프레임워크(IMCore)에 코드를 주입하는 방식(BlueBubbles Private API 헬퍼류)뿐이고, 이는 **SIP(시스템 무결성 보호) 해제**가 필요하다. 보안상 쓰지 않는다.

**대체 표현**: 원문 앞부분을 인용한 접두를 붙여 보낸다.

```
↪ "내일 몇 시에 볼까…"
7시 어때?
```

### 텔레그램 → iMessage 반응(이모지)
공개된 방법이 없다. 메뉴·단축키를 흉내 내는 UI 스크립팅(System Events)은 화면 상태에 따라 엉뚱한 메시지에 반응을 달 위험이 있고 손쉬운 사용 권한까지 필요해 쓰지 않는다.

**대체 표현**(설정 `telegramReactionMode` 로 고른다):
- `"ignore"`(기본): 아무것도 보내지 않는다. 설계 우선순위("텔레그램 → iMessage 는 범위보다 실수 없음", SPEC.md)에 따라, 반응 하나 누른 것이 상대에게 글로 날아가는 일을 기본으로 막는다.
- `"text"`: 아이폰이 문자(SMS) 상대에게 반응을 보여주는 방식처럼 짧은 글로 보낸다. 예: `❤ ↪ "내일 몇 시에 볼까…"`

반응 **취소**는 iMessage 쪽에서 되돌릴 방법이 없으므로 무시한다.

### iMessage → 텔레그램 (제약 적음)
- 답글: 매핑이 있으면 텔레그램 `reply_parameters` 로 진짜 답글이 된다. 매핑이 없는 옛 메시지면 같은 `↪ "…"` 접두로 표시한다.
- 반응: 텔레그램 `setMessageReaction` 으로 실제 반응을 단다. 단 봇이 쓸 수 있는 이모지는 텔레그램 기본 반응 목록뿐이고 메시지당 1개다. 목록에 없는 이모지(예: ‼️, 임의 이모지)는 답글 형태 글(`‼️ 반응`)로 대신한다.
- 음성: `.caf` → `.m4a`(afconvert) 로 바꿔 `sendVoice`(Bot API 는 OGG/Opus·MP3·M4A 를 음성으로 받는다). 실패하면 `sendAudio` → `sendDocument`.

## 2-1. 첨부 보내기는 메시지 앱이 읽을 수 있는 폴더에서만 된다 (확인 2026-10-14)
- 메시지 앱은 샌드박스 앱이라 entitlement 로 허용된 폴더의 파일만 읽는다. 그 밖(예: `~/Library/Application Support/…`, `/tmp`, `~/Pictures`)의 파일을 `send POSIX file` 로 넘기면 osascript 는 성공하지만 chat.db 에 `message.error=25`, `attachment.transfer_state=6` 이 남고 `attachment.filename` 은 넘긴 경로 그대로다. 캡션 글만 상대에게 간다.
- 허용 폴더(home 기준 read-write)는 `codesign -d --entitlements - /System/Applications/Messages.app` 의 `com.apple.security.temporary-exception.files.home-relative-path.read-write` 에 있다: `~/Library/Messages/`, `~/Media/`, `~/Library/SMS/`, `~/Library/Caches/com.apple.MobileSMS/` 등(macOS 26.0.1 에서 확인). `~/Pictures` 는 없다.
- 그래서 기본 첨부 폴더는 `~/Library/Caches/com.apple.MobileSMS/imsg-relay-outbox`(0700)다. `~/Library/Messages` 에는 쓰지 않는다는 규칙을 지키면서 허용 폴더에 든다. 다른 곳을 `outboxDirectory` 로 지정하면 시작 로그에 경고가 남고, 첨부가 든 텔레그램 글은 보내지 않고 ⚠️ 로 알린다.
- 성공하면 메시지 앱이 파일을 `~/Library/Messages/Attachments/…` 로 복사하고 `transfer_state=5`, `error=0` 이 된다(실측). 보낸 사본은 결과가 확정(confirmed/failed)된 뒤 1시간 지나 지운다.
- 음성(텔레그램 ogg → m4a)·문서·영상도 같은 폴더를 거치므로 같은 규칙을 따른다.
- 진단: `bash scripts/agent-run.sh diag-send-file --file 경로 --caption 글` — 같은 폴더·같은 발신기로 설정한 대화에만 보내고 상태만 출력한다(실제로 보낸다).
- 근거: Messages.app entitlement 덤프(위), [anthropics/claude-plugins-official#1113](https://github.com/anthropics/claude-plugins-official/issues/1113)(macOS 15+ 에서 샌드박스 밖 첨부가 조용히 실패, 허용 폴더로 복사 후 보내면 됨).

## 2-2. 텔레그램 음성은 iMessage 에서 "음성 말풍선"이 아니라 오디오 파일 첨부로 보인다 (확인 2026-10-15)

**결론: 파일 첨부로 유지한다.** 공개된 방법(AppleScript)으로 음성 말풍선을 결정적으로 만드는 근거가 없다.

| 확인 | 결과 |
|---|---|
| 실제 행(`diag-audio`, 설정한 대화) | 중계한 `voice-<id>.m4a` 행: `is_audio_message=0`, `expire_state=0`, `item_type=0`, `mime=audio/x-m4a`, `uti=com.apple.m4a-audio`, 코덱 `m4af/aac@48000Hz/1ch` |
| 아이폰 음성 메시지 행(비교 기준) | 설정한 대화에는 아이폰에서 녹음한 음성 메시지 행이 없다(질의는 고정 대화로만 한다). 공개 자료 기준 모양: `is_audio_message=1`, 이름 `Audio Message.caf`, CAF 컨테이너 + Opus(약 24kHz, 모노) |
| 음성 말풍선을 만드는 것 | 메시지 행의 "음성 메시지" 플래그다. BlueBubbles 는 이 플래그를 Private API(IMCore 주입) 경로에서만 넘긴다(`PrivateApiAttachment.ts` 의 `isAudioMessage`). AppleScript 경로(`apple/actions.ts`)는 mp3 를 `.caf` 로 바꿔 **보통 파일로** 보낼 뿐 플래그를 넘길 수단이 없다 |
| 메시지 앱 AppleScript 사전 | `sdef` 에 `audio`·`voice` 관련 명령·속성 0개(macOS 26.0.1). `send` 에 "음성 메시지로" 옵션이 없다 |
| 형식 조건 | 플래그를 넣어도 CAF+Opus 가 아니면 0초짜리 깨진 말풍선이 된다는 보고가 있다 — 형식만 맞춰서 되는 문제가 아니라 플래그가 먼저다 |

- 근거: [BlueBubbles 서버 소스](https://github.com/BlueBubblesApp/bluebubbles-server)(커밋 `f2e2286`, `packages/server/src/server/api/apple/actions.ts`·`api/privateApi/apis/PrivateApiAttachment.ts`), [Advanced iMessage Kit — Audio Messages](https://mintlify.wiki/photon-hq/advanced-imessage-kit/api/attachments/audio-messages)("Audio messages require the Private API"), [openclaw#33377](https://github.com/openclaw/openclaw/issues/33377)·[openclaw#1526](https://github.com/openclaw/openclaw/issues/1526)(CAF+Opus 가 아니면 0초 말풍선).
- 반대 신호: [Hermes BlueBubbles 문서](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/bluebubbles)는 음성 메시지가 Private API 없이 된다고 적지만 시험 결과가 없다. "AppleScript 로 `Audio Message.caf`(Opus) 를 보내면 메시지 앱이 알아서 음성으로 표시한다"는 가설은 공개 근거가 없어 **실제 발송 시험을 하지 않았다**(상대에게 시험 음성이 가기 때문). 시험하려면 운영자 승인 후 1회: `say` 합성 → `afconvert -f caff -d opus@24000 -c 1` → `diag-send-file` → `diag-audio` 로 `is_audio_message` 확인.
- SIP 해제·IMCore 주입(Private API)은 보안상 쓰지 않는다(§2 와 같은 이유).
- 진단: `bash scripts/agent-run.sh diag-audio` — 설정한 대화의 오디오 첨부 행 메타(플래그·mime·uti·확장자·코덱)만 출력한다. 본문·음성 내용·사람이 지은 파일 이름은 출력하지 않는다.

## 3. 확인하지 못한 것 (실제 연결 뒤 확인)
- ~~`send … to chat id "any;-;…"` 가 이 맥에서 동작하는지~~ → 동작한다(macOS 26.0.1, 2026-10-14~15 운영 로그의 `iMessage 로 보냄` 뒤 `메아리 확인`, `doctor --messages` ✔).
- ~~스크립트로 보낸 첨부가 상대에게 "음성 메시지 말풍선"으로 보이는지~~ → 오디오 파일 첨부로 보인다(§2-2, 2026-10-15).
- 1:1 봇 대화에서 텔레그램이 `message_reaction` 업데이트를 봇에게 보내 주는지(문서상 그룹은 봇이 관리자여야 한다).
