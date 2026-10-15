# bluehop SPEC

> 프로젝트 이름은 bluehop 이다. 바이너리는 `bluehop`, 설치 경로는 `~/Library/Application Support/bluehop`, LaunchAgent 라벨·Keychain 서비스는 `dev.kanziw.bluehop` 이다.

텔레그램 봇 방 **하나** ↔ iMessage 1:1 대화 **하나**를 고정으로 잇는 연결("매핑")을 여러 개 나란히 돌리는 작은 중계기. 매핑마다 봇 토큰이 따로다(0.5.0 부터, 설계: `docs/design-multi-mapping.md`).
설계 결정: 범용 iMessage 브리지를 쓰는 대신 기능을 좁힌 중계기를 새로 만든다. 범용 브리지에서 흔한 위험(LAN 에 열린 웹 UI, 마지막 발신자 라우팅, 공용 인터프리터에 전체 디스크 권한, 고정되지 않은 의존성)을 설정이 아니라 **구조로** 없앤다(§4).

**목표**: iMessage 로만 대화할 수 있는 상대(예: iMessage 전용 AI 비서, 가족 한 명)와의 대화를 텔레그램에서 보고, 텔레그램에서 답한다.

**우선순위**(설계 결정):
1. **iMessage → 텔레그램을 가장 충실하게.** 본문·답글 관계·반응·첨부, 그리고 사용자가 iPhone 등에서 직접 보낸 메시지까지 보여 대화 전체 흐름이 텔레그램에 보이게 한다.
2. **텔레그램 → iMessage 는 범위보다 "실수 없음".** 정해 둔 그 대화로만 보내고, 보낸 뒤 chat.db 에 실제로 기록됐는지 확인하고, 실패만 텔레그램에 ⚠️ 답글로 알린다(성공은 표시하지 않는다 — 사용자 글에 달리는 반응은 상대가 단 것만 남아야 헷갈리지 않는다). 실패해도 자동 재시도하지 않고, 같은 텔레그램 메시지를 두 번 보내지 않는다. 텔레그램에서 수정한 글은 다시 보내지 않는다.

## 1. 요구사항

| # | 요구 | iMessage → 텔레그램 | 텔레그램 → iMessage |
|---|---|---|---|
| R1 | 글 | 그대로 | AppleScript `send` |
| R2 | 답글 관계 | 텔레그램 진짜 답글(`reply_parameters`). 매핑 없으면 `↪ "…"` 접두 | **진짜 답글 불가** → `↪ "원문 앞부분…"` 접두 |
| R3 | 반응(이모지) | `setMessageReaction`. 봇이 못 쓰는 이모지는 답글 글로 대체. 취소도 반영 | **진짜 반응 불가** → 무시(기본) 또는 `❤ ↪ "…"` 글 |
| R4 | 첨부(사진·음성·파일·영상) | 사진 `sendPhoto`(HEIC→JPEG, `sips`), 음성 `.caf`→`.m4a` `sendVoice`, 영상 `sendVideo`, 기타 `sendDocument` | 받은 파일을 내려받아 AppleScript `send POSIX file`. 텔레그램 음성(`.ogg`)은 `.m4a` 로 변환 |
| R5 | 내 다른 기기에서 보낸 글·반응 | 설정 `mirrorOwnMessages`(기본 켬)면 `🙋 나: …` 로 미러 | — |
| R6 | 발송 확인 | — | chat.db 에 내 메시지로 기록되면 조용히 확인(표시 없음), 실패·60초 미확인·메시지 앱 오류(`error≠0`)면 ⚠️ 답글. 자동 재시도 없음 |
| R7 | 수정 | — | 텔레그램 `edited_message` 는 다시 보내지 않고 "반영 안 됨" 안내만 |

한계의 근거는 `docs/imessage-limits.md`.

## 2. 데이터 흐름

```
 ┌──────────────── 이 맥 (한 프로세스, 열린 포트 없음) ────────────────┐
 │                                                                     │
 │  chat.db ──(읽기 전용, 고정 chat ROWID 로 한정한 질의)──▶ IMessageIn │
 │                                                          │          │
 │                     state.sqlite (커서·매핑·outbox) ◀────┤          │
 │                                                          ▼          │
 │  Messages.app ◀── osascript(argv 로 값 전달) ◀── TelegramIn ◀──┐    │
 └────────────────────────────────────────────────────────────────┼────┘
                                                                  │ HTTPS
                                                       api.telegram.org (유일한 외부)
```

한 프로세스가 켜진 매핑마다 일꾼을 하나씩 띄운다. 일꾼 하나의 루프가 순서대로 돈다: ① 자기 봇의 `getUpdates`(짧은 long-poll) → 허용 방·허용 사람만 처리 ② 자기 대화의 chat.db 새 행 처리 ③ 발송 확인.

### 2-0. 매핑과 일꾼
- 일꾼은 서로 아무것도 나눠 쓰지 않는다: 텔레그램 클라이언트(토큰), 속도 제한·안전 정지, 커서·offset·outbox(메아리 맞춤), 보낼 첨부 폴더(`<첨부 폴더>/<매핑 id>/`), chat.db·상태 DB 연결이 모두 매핑마다 따로다. 한 매핑의 토큰 폐기·네트워크 오류·안전 정지는 그 매핑만 멈춘다.
- 예외 하나: chat.db 변화 감시는 공용이다. 매핑한 대화들의 마지막 ROWID 를 질의 한 번(`… WHERE chat_id IN (매핑한 대화) GROUP BY chat_id`, 최소 1초 간격)으로 읽고, 일꾼은 자기 대화에 커서 뒤 행이 있을 때만 행을 읽는다.
- 시작에 실패한 일꾼(토큰 없음·대화 없음·같은 봇)은 오류를 상태 DB 에 남기고 5초부터 두 배씩 최대 5분 쉬었다 다시 시도한다. `getUpdates` 실패는 3초부터 두 배씩 최대 60초.
- 설정 파일이 바뀌면(5초마다 확인) 일꾼을 맞춘다: 없어진·멈춘 매핑은 멈추고, 새 매핑은 띄우고, 바뀐 매핑은 다시 띄운다. 바뀐 설정이 잘못됐으면 로그만 남기고 지금 일꾼을 그대로 둔다. 멈추기는 await 지점에서만 일어나므로 시작한 발송은 끝나고 outbox 에 남는다.
- 같은 봇을 두 매핑이 쓰지 못하게 설정 검사(botId·Keychain 계정·토큰 파일) 외에 실행 중에도 봇 id 로 한 번 더 막는다(`getUpdates` 는 토큰마다 받는 쪽이 하나뿐).

### 2-1. iMessage → 텔레그램
1. 시작 시 `chat.guid = 설정값` 인 행을 찾는다. **style=45(1:1)이고 참가자가 정확히 1명이며 그 handle 이 설정의 handle 과 같아야** 시작한다(단체방이 묶이는 실수를 구조로 막음).
2. `SELECT … FROM message JOIN chat_message_join ON … WHERE chat_id = :고정 AND message.ROWID > :커서 ORDER BY ROWID LIMIT 50` — 다른 대화는 질의 자체에 안 들어온다.
3. 행 분류: 반응(`associated_message_type` 2000~3007) / 일반(텍스트·첨부) / 그 외(건너뜀).
4. 본문: `text` 가 비면 `attributedBody`(typedstream)에서 NSString 을 꺼낸다. 첨부 자리표시 `U+FFFC` 는 지운다.
5. 답글: `thread_originator_guid` → 매핑된 텔레그램 message_id 로 답글. 없으면 원문(같은 대화에서만 조회) 앞부분 인용 접두.
   같은 원글에 연달아 단 답글(사이에 텔레그램에 올라간 다른 글이 없음)은 첫 말풍선만 답글로 걸고 나머지는 이어 보낸다 — 텔레그램은 말풍선마다 인용 머리를 그린다. 답글 관계 매핑은 모두 저장한다.
   링크 말풍선(`balloon_bundle_id = com.apple.messages.URLBalloonProvider`): 미리보기 그림 첨부(`*.pluginPayloadAttachment`)는 올리지 않고, `payload_data` 의 제목 + 원래 주소를 글 한 통으로 보내며 그 주소로만 텔레그램 미리보기를 켠다(다른 글은 미리보기 끔, 서식 없음). 다른 말풍선 앱 행이 글 없이 자료 첨부뿐이면 못 옮겼다는 한 줄을 남긴다.
   반응: `associated_message_type` 2000~2006 → 매핑된 텔레그램 메시지에 `setMessageReaction`(❤️→❤, 😂→🤣, ❓→🤔, 👍, 👎, iOS 17+ 임의 이모지는 봇 목록에 있으면 그대로). 목록 밖(‼️ 등)·스티커·텔레그램 거부 시 답글 글 `‼️ 반응`. 3000~3006(취소) → 봇 반응 제거.
6. 첨부: `attachment.filename` 을 `~/Library/Messages/Attachments` 아래인지 실제 경로로 검사한 뒤 읽는다. 변환본은 원본 옆이 아니라 앱 전용 임시 폴더에 쓴다. 파일이 아직 안 내려왔으면 최대 5분 기다리고(그동안 커서 정지), 넘으면 `[첨부를 받지 못함: 이름]` 글로 대신한다. 50MB 를 넘는 첨부는 올리지 않고 `[첨부가 너무 큼: 이름, N MB]` 글로 대신한다(봇 업로드 한도).
7. 보낸 텔레그램 message_id 와 iMessage guid(+part) 를 매핑에 저장하고 커서를 그 ROWID 로 올린다(같은 트랜잭션).
8. `is_from_me=1` 행: 먼저 outbox(중계기가 방금 보낸 것)와 맞춰 본다. 맞으면 매핑만 저장하고 텔레그램엔 다시 안 보낸다(메아리 방지 + 상대가 그 메시지에 답글/반응할 때 원래 텔레그램 메시지에 연결). 안 맞으면(사용자가 iPhone·Mac 에서 직접 보낸 것) `mirrorOwnMessages` 에 따라 `🙋 나: …` 로 미러한다. 사용자 본인의 반응은 봇 반응으로 달면 상대 반응처럼 보이므로 `🙋 나: ❤️ 반응` 답글 글로 보인다.
   - **본문 비교는 양쪽을 같은 키로 접은 뒤 한다**(`EchoKey.normalize`, outbox 에 넣을 때와 chat.db 행을 볼 때 둘 다). 메시지 앱은 보낸 글을 그대로 적지 않는다 — **한글을 NFD(자모 분해)로**, `text` 를 비우고 `attributedBody` 에만 적는다(실측 2026-10-14: 46 스칼라·102바이트 글이 83 스칼라·213바이트로 기록, 'Hi' 같은 ASCII 글만 맞고 한국어 글은 전부 틀림). 여러 줄 글의 줄바꿈도 U+2028/U+2029 로 적을 수 있다. 그래서 키는 ① U+FFFC 제거·줄바꿈 통일 ② NFC 합성 ③ 둥근 따옴표·대시·말줄임표를 곧은 꼴로(`“”`→`"`, `‘’`→`'`, `–—`→`-`, 연속 `-` 하나로, `…`→`...`) ④ 폭 없는 공백·BOM·제어문자 제거, NBSP 등 공백류를 공백 하나로, 줄 끝 공백 제거. 맞추지 못하면 사용자가 텔레그램으로 보낸 글이 "🙋 나: …"로 중복 게시되고, 상대 반응·답글이 그 메아리에 붙고, 60초 뒤 **실제로는 보낸** 글에 거짓 ⚠️ 가 달린다(사고 2026-10-14).
   - **정확 일치만 쓴다 — "대기 발송 1건 + 시간 창 안의 내 행 1건이면 맞춤" 같은 보조 규칙은 두지 않는다.** 원인(NFD)이 키 규칙으로 닫혔고, 보조 규칙이 틀리면 사용자가 iPhone 에서 직접 보낸 글이 텔레그램에서 사라지고 실제로 안 간 발송이 확인된 것으로 처리된다(실패가 조용해진다). 대신 유예가 끝나도 못 맞춘 행은 미러하기 직전에 `메아리 불일치 rowid=… 후보 tg=… 받은 len=…/h=… 기다림 len=…/h=… 같은앞부분=N` 를 로그에 남긴다(본문 없음). 새 변형이 나오면 이 줄과 `bluehop diag-echo` 로 원인을 확정하고 키 규칙에 더한다.
   - **메아리 맞춤에 유예(`echoGraceSeconds`, 기본 5초)를 둔다**: 확인 안 된 텔레그램 발송(outbox `sending`/`sent`)이 남아 있는 동안 본 `is_from_me` 행은, 본문 비교가 그 발송과 아직 못 맞춰진 것일 수 있으니 곧바로 "직접 보낸 글"로 단정하지 않고 잠깐(최대 `echoGraceSeconds`) 기다려 재시도 기회를 준다. 유예가 끝나도 못 맞추면(정말 다른 글이면) 그제서야 평소처럼 미러한다 — 안전망이 영원히 막지는 않는다.

### 2-2. 텔레그램 → iMessage
1. **시작 시 텔레그램 기준선**: `tg_offset` 이 상태 DB 에 한 번도 저장된 적 없으면(첫 실행 또는 상태 DB 초기화 뒤), `getUpdates(offset: 0)` 로 그 시점까지 쌓인 업데이트를 전부 받아 **확인 처리만**(offset = 최신 update_id + 1) 하고 iMessage 로는 아무것도 보내지 않는다. 건너뛴 건수를 로그에 남기고, 1건 이상이면 텔레그램 방에 "켜기 전 메시지 N개는 보내지 않았습니다"를 한 번 보낸다. iMessage 쪽 커서 기준선(§2-1 1번)과 같은 이유다 — `getUpdates` 는 offset 이 없으면 설정 과정에서 보낸 글까지 처음부터 돌려준다(사고 2026-10-14: 설정 중 봇에게 보낸 'Hi' 가 켜자마자 iMessage 상대에게 전송됨).
2. `getUpdates(offset, timeout)`. 업데이트마다 `chat.id == 설정 chat_id` **그리고** `from.id == 설정 user_id` 가 아니면 내용을 보지 않고 버린다(로그에도 내용 없음).
3. **지연 메시지 거부**: 멱등성 확인을 지난 글이라도, 텔레그램이 보낸 시각(`date`)이 지금으로부터 `lateMessageThreshold`(기본 600초/10분)보다 오래됐으면 iMessage 로 보내지 않고 "⚠️ 오래돼서 안 보냄"을 답글로 알린다. 재시작 사이 쌓였다가 늦게 처리되는 지시가 엉뚱한 때 나가는 것을 막는다. 이 규칙이 켜기 전 백로그 전부를 걷어내지는 않는다 — 1번의 기준선이 그 역할이고, 이 규칙은 **재시작 뒤 멈춰 있던 동안의** 글이 대상이다.
4. `/` 로 시작하는 글은 명령: `/status`, `/pause`, `/resume`(`/resume skip` = 밀린 iMessage 건너뛰기, `/resume all` = 밀린 것도 모두 보내기). 진짜 `/` 로 시작하는 글을 보내려면 `//`. (명령은 지연 메시지 규칙 밖 — 늦게 받아도 지금 상태를 그대로 처리)
5. 답글이면 `reply_to_message` 의 글(텔레그램이 같이 준다)로 `↪ "…"` 접두를 만든다 — 원문을 로컬에 저장하지 않는다.
6. 첨부는 `getFile` → `api.telegram.org/file/bot…` 내려받기(20MB 한도) → 메시지별 폴더에 안전한 이름으로 저장 → `send POSIX file`.
7. 첨부를 **모두** 먼저 내려받는다. 하나라도 실패하면 아무것도 보내지 않는다(캡션만 가는 반쪽 발송 방지).
8. 보내기 **전에** outbox 에 모든 부분을 `sending` 으로 적는다(키: 텔레그램 message_id + 부분 번호). 이미 그 message_id 의 행이 있으면 어떤 이유로도 다시 보내지 않는다 — 멱등성의 핵심. 중간에 죽으면 그 부분은 `sending` 으로 남고, 60초 뒤 "보내는 도중 중계기가 멈춤"으로 알린다(재발송 안 함).
9. osascript 성공 → `sent`. chat.db 에 같은 글(또는 같은 파일 이름)의 내 메시지 행이 나타나면 `confirmed` + 매핑 저장(상대가 그 메시지에 답글·반응하면 텔레그램의 사용자 원래 메시지에 연결된다). 그 행은 텔레그램으로 되돌려 보내지 않는다(메아리 방지).
10. 모든 부분이 `confirmed` 면 아무것도 달지 않는다(성공 반응 없음). 하나라도 실패면 사유를 답글로 알린다. 메아리 맞춤용 본문은 확인되면 바로 지운다.
11. `getUpdates` offset 은 처리 뒤에 저장한다. 처리 도중 죽어 같은 업데이트가 다시 와도 8번 검사로 다시 보내지 않는다.

## 3. 상태 저장 (`state.sqlite`, 0600)

파일 하나를 모든 매핑이 함께 쓰고 **모든 표의 모든 행에 `mapping_id`** 가 있다(기본 키에도 포함, `PRAGMA user_version = 2`). `StateStore` 는 매핑 하나의 보기라 모든 질의가 자기 `mapping_id` 로 한정된다. 0.4.x 상태 DB 는 처음 열 때 `VACUUM INTO 'state.sqlite.v1-backup'` 으로 사본을 만든 뒤, 트랜잭션 하나 안에서 표를 다시 만들고 기존 행을 `mapping_id = 'default'` 로 옮긴다.

| 테이블 | 내용 | 메시지 본문 저장? |
|---|---|---|
| `kv` | `imsg_cursor`(ROWID), `tg_offset`, `halted`(사유), `health.*`(일꾼 상태·마지막 텔레그램 확인·마지막 오류 — `bluehop status` 가 읽음) | 아니오 |
| `mapping` | `imsg_guid, part, tg_message_id, direction, created_at` | 아니오 |
| `outbox` | `tg_message_id, part, kind, match_key, status(sending/sent/confirmed/failed), detail, matched_guid, notified` | 잠깐(메아리 맞춤 키, 확인 즉시·늦어도 1시간 뒤 삭제) |
| `reaction_state` | 봇이 단 반응(취소 반영용) | 아니오 |
| `pending_attachment` | 첨부 대기 시작 시각 | 아니오 |

첫 실행 때 커서는 그 대화의 **현재 최대 ROWID** 로 잡는다 — 과거 대화를 한꺼번에 쏟지 않는다(기준선 먼저).

## 4. 보안 설계

| 범용 브리지에서 흔한 위험 | bluehop 의 구조적 대응 |
|---|---|
| 웹 UI 가 LAN(0.0.0.0)에 인증 없이 열림 | **웹 서버·리스닝 소켓 없음.** 나가는 HTTPS 만 쓴다. 텔레그램 기본 주소는 코드에 고정(`https://api.telegram.org`)이고 설정 파일로 바꿀 수 없다(테스트만 주입) |
| 마지막 발신자에게 답장(라우팅 혼동) | 매핑마다 대화 1개·봇 1개 고정. 봇마다 보내는 대상은 그 매핑의 chat guid 하나뿐이고 시작 시 1:1·handle 일치를 검증. 한 대화·한 봇을 두 매핑에 쓰는 설정은 거부 |
| 공용 Python 에 전체 디스크 권한 | 서명된 **단일 바이너리**에만 권한을 준다. 인터프리터·플러그인·셸 없음 |
| 의존성 미고정 | **외부 패키지 0개**(Swift 표준·Foundation·SQLite3·Security). `Package.resolved` 자체가 없다 |
| osascript 스크립트에 값 삽입(셸·ssh 경유 시 주입) | `osascript` 를 셸 없이 직접 실행하고 본문·대상은 **argv 로만** 넘긴다(스크립트 문자열에 값을 끼워 넣지 않음) |
| 첨부 변환본을 Messages 폴더에 씀 | chat.db 는 `SQLITE_OPEN_READONLY`, Messages 폴더엔 아무것도 쓰지 않음 |

그 밖:
- 설정 파일·상태 DB·토큰 파일은 0600, 폴더는 0700. 권한이 더 넓으면 **시작을 거부**한다.
- 봇 토큰은 Keychain(`security add-generic-password -s dev.kanziw.bluehop -a telegram-bot-token`) 또는 0600 파일. 로그·에러 메시지에 토큰을 찍지 않는다(URL 이 들어간 에러는 토큰을 가린다).
- 로그에는 ROWID·message_id·개수·종류만 남기고 **본문·전화번호는 남기지 않는다.**
- 첨부 읽기는 `~/Library/Messages/Attachments` 아래 실제 경로만 허용(심볼릭 링크로 빠져나가기 차단).
- 텔레그램 봇 대화는 종단간 암호화가 아니다 — 중계된 문자는 텔레그램 서버에 남는다(받아들인 위험).

### 4-1. 속도 제한과 안전 정지
- 토큰 버킷: 텔레그램으로 분당 20건, iMessage 로 분당 10건(넘으면 버리지 않고 기다림).
- 위 제한과 안전 정지는 **매핑마다 따로** 센다(한 매핑의 정지가 다른 매핑을 멈추지 않는다).
- 안전 정지(서킷 브레이커): 최근 10분 동안 텔레그램으로 120건 또는 iMessage 로 40건을 넘기면, 또는 시작 시 밀린 iMessage 가 50건을 넘으면 **양방향을 멈추고** `halted` 를 저장한 뒤 텔레그램에 한 번 알린다. 재개는 사용자가 `/resume`(텔레그램) 또는 `bluehop resume [--skip-backlog]`.
- iMessage 로 보내는 글 최대 4000자, 첨부 최대 20MB(텔레그램 봇 내려받기 한도). 텔레그램으로 올리는 첨부 최대 50MB(넘으면 안내 글), 4000자 넘는 글은 나눠 보낸다.
- 정지 중이거나 보낸 지 10분 넘은 텔레그램 글, 스티커는 보내지 않고 ⚠️ 로 알린다.

## 5. 설정 (`~/Library/Application Support/bluehop/config.json`, 0600)

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

- `id`: 소문자로 시작, 소문자·숫자·`-`, 32자 이하. Keychain 계정·상태 DB·로그 접두(`[id]`)·CLI 인자에 쓴다. 글자로 시작하는 이유: 0.4.x 가 보낼 첨부 폴더 바로 아래에 남긴 숫자 이름 폴더와 겹치지 않게.
- `enabled`: `false` 면 멈춘 매핑 — 일꾼을 띄우지 않는다(텔레그램도 iMessage 도 읽지 않음). 기본 `true`.
- `telegram.chatId`: 그 봇과의 1:1 방 id(0 이 아니어야 함). `telegram.allowedUserId`: 글을 받아 줄 텔레그램 사용자 id(양수). `bluehop mapping add` 가 봇에게 온 메시지로 알아낸다.
- `telegram.botId`·`botUsername`: 매핑을 추가할 때 `getMe` 로 기록. 토큰의 `:` 앞 숫자라 비밀이 아니고, 토큰을 읽지 않고도 같은 봇을 두 번 묶지 못하게 한다. 실행 중에는 토큰의 봇 id 가 이 값과 다르면 시작하지 않는다.
- `telegram.tokenSource`: `"keychain"`(서비스 `dev.kanziw.bluehop` / 계정 `tokenAccount`, 비어 있으면 `bot-token:<id>`) 또는 `"file"`(`tokenFile`, `~` 펼침, 현재 사용자 소유·0600). 토큰 형식(`<숫자>:<영숫자_->`)이 아니면 거부한다.
- `imessage.chatGuid`: `;-;` 가 든 1:1 형식만(단체방 `;+;` 거부). `imessage.handle`: 그 대화의 유일한 참가자(공백·`-`·괄호·대소문자 무시하고 비교).
- `relay.*`: 매핑마다 따로. `mirrorOwnMessages`(기본 `true`), `telegramReactionMode`(`"ignore"` 기본 / `"text"`), `outboxDirectory`(기본 `~/Library/Caches/com.apple.MobileSMS/bluehop-outbox`, 그 아래 `<id>/` 를 쓴다. 메시지 앱 샌드박스가 읽을 수 있는 곳이어야 함 — `docs/imessage-limits.md` §2-1). `relay` 블록은 통째로 빠져도 된다.
- **규칙(읽을 때·쓰기 전에 모두 검사)**: id 가 겹치지 않는다. iMessage 대화(같은 `chatGuid` 또는 같은 `handle`)는 한 매핑에만. 봇 토큰(같은 `botId`·같은 Keychain 계정·같은 토큰 파일)은 한 매핑에만 — (봇, 텔레그램 방) 쌍의 유일성은 여기에 포함된다. 어기면 `매핑 충돌:` 로 시작을 거부하고 CLI 는 종료 코드 3.
- **0.4.x 설정**(버전 표시 없이 최상위 `telegram`·`imessage`·`relay`)은 손대지 않아도 매핑 `default` 하나로 읽는다(Keychain 계정 `telegram-bot-token` 그대로). 매핑 목록을 바꾸는 첫 CLI 명령(`mapping add/remove/pause/resume`)이 버전 2 로 다시 쓰고, 그 전에 `config.json.v1-backup`(0600)을 한 번 남긴다. 쓰기는 같은 폴더의 0600 임시 파일 → `rename` 이다. `run`·`doctor`·`status`·`mapping list` 는 설정을 쓰지 않는다.

## 6. 범위 밖
iMessage 편집(`date_edited`)·보내기 취소 반영, 단체방, 봇 하나로 여러 대화 잇기, 텔레그램 스티커 전달, 텔레그램 메시지 수정 반영, 텔레그램 반응 취소의 iMessage 반영.

## 7. CLI

명령·옵션·`--json` 모양·종료 코드는 `docs/design-multi-mapping.md` §5 와 README "CLI" 가 기준이다. 요점:
- 모든 명령에 `--help`. 모르는 옵션·남는 인자는 오류(종료 코드 2). 조회 명령은 `--json` 으로 JSON 하나를 표준출력에 낸다(오류도 `{"ok": false, "error": {...}}`).
- 종료 코드: 0 성공, 1 실패, 2 사용법, 3 충돌, 4 없음, 5 시간 초과, 130 취소.
- 봇 토큰은 명령줄 인자로 받지 않는다(표준입력 `--token-stdin` 또는 숨김 입력). Keychain 에는 `security -i` 의 표준입력으로 넘겨 저장한다(`ps` 에 안 보임). 대화형 질문은 표준입력이 터미널이고 값이 빠졌을 때만 한다.
- 터미널에 전체 디스크 접근이 없어 chat.db 를 못 열면, 읽기(`chats --json`, `doctor --json`)만 설치된 바이너리를 launchd 일회성 작업으로 돌려 받는다(`BLUEHOP_ONESHOT=1` 로 재귀 방지).
