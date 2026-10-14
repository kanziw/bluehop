# 메아리 맞춤: 본문 대신 고유 ID 로 할 수 있는가 (조사 2026-10-14)

질문: 텔레그램 → iMessage 로 보낸 글이 chat.db 에 다시 적힐 때, 지금처럼 **본문(정규화)** 으로 대조하지 말고
**고유 ID** 나 결정적인 메타 컬럼으로 "중계기가 보낸 글"과 "사용자가 iPhone 에서 직접 보낸 글"을 가를 수 있는가.

## 결론

**결정적인 수단은 없다. 그래서 코드는 바꾸지 않았다.**

- 메시지 앱 AppleScript 의 `send` 는 **아무것도 돌려주지 않는다**(메시지 객체·guid 없음). 보낸 글을 가리킬 손잡이가 처음부터 없다.
- chat.db 에도 "이 맥이 보낸 것 / 다른 기기가 보낸 것"을 적는 **문서화된 컬럼이 없다.** 실측에서 갈리는 신호가 3개 보였지만
  모두 비공개 구현의 부수효과이고, 다른 서비스(SMS)에서는 이미 성립하지 않는 반례가 있다. 1차 기준으로 쓰면 OS 업데이트 한 번에 조용히 깨진다.
- 고유 ID 를 얻는 유일한 길은 메시지 앱 내부(IMCore) 비공개 API 인데, SIP(시스템 무결성 보호)를 꺼야 한다. 이 맥에 그런 조건을 거는 것은 권하지 않는다.

대신 **"보낸 뒤 새로 생긴 내 행만, 보낸 순서대로" 범위를 좁히는 방식**을 본문 대조와 함께 쓰는 것이 가장 낫다(아래 "권하는 조합").
구현은 이번 범위 밖으로 남긴다 — 결정적이지 않으므로 조사 보고서만 둔다.

## 1. AppleScript `send` 가 돌려주는 것 (실측: macOS 26.0.1, 25A362)

`sdef /System/Applications/Messages.app` 의 해당 부분(발췌, 원문 그대로):

```xml
<command name="send" code="ichtsend" description="Sends a message to a participant or to a chat.">
    <cocoa class="CKScriptCommand"/>
    <direct-parameter>
        <type type="file"/>
        <type type="text"/>
    </direct-parameter>
    <parameter name="to" code="TO  ">
        <cocoa key="to"/>
        <type type="participant"/>
        <type type="chat"/>
    </parameter>
</command>
```

- `<result>` 요소가 **없다** → 반환값 없음(missing value).
- 사전에 노출된 클래스는 `participant`·`account`·`chat`·`file transfer` 뿐이고 **`message` 클래스가 없다.** 보낸 글을 나중에 조회할 방법도 없다.
- `id` 속성은 participant·account·chat·file transfer 에만 있다. 파일 발송이면 `file transfer` 의 `id`(guid)를 이론상 볼 수 있지만,
  `send` 가 그 객체를 돌려주지 않으므로 "방금 내 발송"과 묶을 수 없다.
- 실제 send 는 실행하지 않았다(사전만 읽음).

공개 자료도 같은 처지를 보여 준다. BlueBubbles 서버는 AppleScript 경로로 보낼 때 클라이언트가 만든 `tempGuid` 를 따로 요구하고
(메시지 앱이 guid 를 돌려주지 않으니 자기 쪽 임시 키로 나중에 맞춘다), 진짜 guid 를 얻는 기능은 SIP 를 끄고 메시지 앱에 주입하는 Private API 모드에서만 제공한다.

- BlueBubbles Private API 설치(SIP 해제 필요): https://docs.bluebubbles.app/private-api/installation
- BlueBubbles Private API 기능 설명: https://github.com/BlueBubblesApp/bluebubbles-server/wiki/Using-Private-API-Features/a03a4d710f5e3520b42d2f957700a9c2bb7c9ff7
- AppleScript 경로의 tempGuid 필수 오류 사례: https://github.com/NousResearch/hermes-agent/issues/122949
- macOS 26 에서 AppleScript 발송이 불안정해 Private API 로 우회하는 사례: https://github.com/openclaw/openclaw/issues/29389

## 2. chat.db 에서 "이 맥이 보낸 것"을 가르는 컬럼이 있는가

`message` 테이블 컬럼 전부(본문 계열 제외)를 중계 대화의 최근 행에 대해 덤프해 비교했다. 본문은 꺼내지 않았다.
표본: **이 맥에서 AppleScript 로 보낸 행 5개**(rowid 1134·1136·1139·1141·1143 — 상태 DB 의 tg=3·5·9·13·15 와 로그로 대응 확인)
vs **같은 대화에서 iPhone 에서 보낸 행 9개**(rowid 1055~1092, 중계기 기준선 1133 이전, 12:24~13:07 UTC).

### 양쪽이 똑같아서 쓸 수 없는 컬럼

`account`, `account_guid`, `service`(iMessage), `destination_caller_id`, `cache_roomnames`(NULL), `is_sent`(1), `is_delivered`(1),
`is_finished`, `message_source`(0), `was_downgraded`(0), `sort_id`(0), `part_count`(1), `ck_sync_state`(0), `ck_record_id`/`ck_record_change_tag`(빈 문자열),
`text`(둘 다 NULL — 본문은 attributedBody 에만), attributedBody 의 속성 키 집합(둘 다 `__kIMMessagePartAttributeName` 하나).
요청서에 예로 든 후보는 전부 여기에 들어간다.

다른 테이블(`message_processing_task`, `persistent_tasks`, `recoverable_message_part`, `sync_*` 등)에도 발신 기기를 적는 곳은 없었다.

### 실측에서 갈린 신호 3개 (비공개 부수효과)

| 신호 | 이 맥 발송 5건 | iPhone 발송 9건 |
|---|---|---|
| `reply_to_guid` | 있음(직전 행 guid) | NULL |
| `date_delivered` vs `date_read` | 서로 다름 | 같은 값 |
| `date` 정밀도 | 밀리초 단위로 잘림(예: `…959.900000`) | 나노초까지 있음 |

이 셋은 iMessage 1:1 대화 14건에서 100% 갈렸지만 1차 기준으로 쓰지 않는 이유:

1. **문서가 없다.** 어느 컬럼도 "발신 기기"라는 뜻으로 정의된 적이 없다. 메시지 앱이 순서 정렬·읽음 처리를 위해 채우는 값의 부수효과다.
2. **반례가 이미 있다.** DB 전체에서 `is_from_me=1` SMS 행 29건 중 23건이 `reply_to_guid` 를 갖는다(iPhone 문자 전달로 들어온 것). 서비스·경로에 따라 의미가 바뀐다.
3. **표본이 작다**(이 맥 발송 5건). iPhone 쪽 표본도 중계기 운영 이전 것뿐이다.
4. 잘못 판정하면 피해가 크다 — "메아리"로 오인하면 사용자가 iPhone 에서 보낸 글이 텔레그램에서 **사라진다**(조용한 누락). 본문 비교 실패(🙋 중복 표시)보다 나쁜 실패다.

전체 DB 분포(`associated_message_type=0` 행):

```
is_from_me|service |reply_to_guid 있음|delivered==read|건수
1         |iMessage|0                 |1             |10
1         |iMessage|1                 |0             |4   ← 조회 시점의 중계 발송(이후 1143 추가로 5)
1         |SMS     |1                 |1             |23  ← 반례: iPhone 경유인데 reply_to_guid 있음
1         |SMS     |0                 |1             |6
```

## 3. 순서·타이밍으로 1:1 대응시키는 방식

아이디어: 보내기 직전 그 대화의 최대 rowid(워터마크)를 기록하고, 발송을 한 번에 하나씩(직렬) 하며,
워터마크 뒤에 처음 나타나는 `is_from_me=1` 행을 그 발송의 메아리로 본다.

- 중계기는 이미 `handle(message:)` 안에서 부분을 차례로, 한 번에 하나씩 보낸다. 직렬화는 사실상 되어 있다.
- 실측 지연: 로그상 `보냄` 과 `메아리 확인` 이 같은 초에 찍히고, chat.db `date` 는 발송 직후 1초 안이다.
- **실패 경우**: 발송 후 메아리 행이 생기기 전(약 1초) 사이에 사용자가 iPhone 에서도 같은 대화로 글을 보내면 순서만으로는 둘을 못 가른다.
  - 대략의 확률: 사용자가 그 대화에서 시간당 N 건 직접 보낸다면, 한 발송당 충돌 확률 ≈ N × (창 2초) / 3600초.
    N=20 이어도 약 1%, 실제로는 텔레그램에 글을 쓰는 동시에 iPhone 으로도 쓰는 일이 드물어 그보다 훨씬 낮다.
  - 메시지 앱 발송이 실패해 chat.db 에 행이 아예 안 생기는 경우, 그 뒤 iPhone 발송을 메아리로 잘못 잡을 수 있다 — 그래서 순서만 쓰면 안 되고 본문과 함께 써야 한다.
- 순서 방식은 **본문 없이 단독으로는 결정적이지 않다.** 그러나 본문 대조와 겹치면 서로의 약점을 덮는다.

## 4. 보이지 않는 표식(제로폭 문자 등)을 본문에 넣는 방식

원칙적으로 쓰지 않는다.

- 장점: 본문에 고유 꼬리표를 심으면 chat.db 에서 결정적으로 찾을 수 있다.
- 단점:
  - 표식이 **iMessage 상대에게 그대로 전달된다.** 화면에 안 보여도 복사·검색·번역·음성 읽기·링크 감지에 끼어든다.
  - 메시지 앱이 그 문자를 그대로 저장한다는 보장이 없다(이미 NFD 변환·스마트 구두점 변환을 하는 앱이다). 지우면 표식 방식 자체가 깨진다.
  - 지금 `EchoKey.normalize` 는 U+200B·U+200C·U+200D·U+2060·U+FEFF 를 일부러 지운다. 표식 방식은 이 안전장치와 정면으로 부딪친다.
  - 상대에게 나가는 글을 중계기가 바꾸는 것은 이 도구의 원칙(사용자 글을 그대로 전달)에 어긋난다.

## 권하는 조합 (구현은 하지 않음)

결정적 수단이 없으므로, 다음 순서로 판정을 좁히는 것이 가장 낫다.

1. **범위 좁히기(순서)**: 발송마다 워터마크 rowid 를 outbox 에 저장. 메아리 후보는 "워터마크 뒤의 `is_from_me=1` 행"으로 한정.
   지금은 시간 창 안의 모든 대기 항목과 본문이 같으면 맞추므로, 과거 같은 글이 남아 있는 경우의 오매칭을 줄인다.
2. **1차 판정(본문)**: 지금의 정규화 본문 비교 유지(fb216cf).
3. **보조 판정(순서 + 단일 후보)**: 본문이 안 맞아도 ① 기다리는 발송이 정확히 1건이고 ② 그 발송 워터마크 뒤 첫 `is_from_me` 행이며
   ③ 발송 후 수 초 안에 생겼고 ④ 종류(글/파일)가 같으면 메아리로 본다. 이때 로그에 "본문 불일치·순서로 맞춤"을 남겨 정규화 규칙의 빈틈을 계속 찾는다.
4. 위 셋 다 아니면 지금처럼 유예(5초) 뒤 "🙋 나:" 로 올린다.
5. (선택) 2절의 비공개 신호 3개는 판정에 쓰지 말고 **로그에만** 남겨 표본을 쌓는다. 몇 주 쌓여 반례가 없으면 그때 3번의 보조 신호로 올릴지 다시 본다.

예상 실패율(대략):

- 지금 방식: 정규화 규칙이 하나라도 어긋나는 글 유형에서는 100% 실패(이번 한글 NFD 사고처럼), 나머지는 거의 0.
- 권하는 조합: 정규화가 어긋나도 3번이 대부분 덮는다. 남는 실패는 "사용자가 텔레그램 발송과 1~2초 안에 iPhone 에서도 같은 대화로 글을 보내고, 동시에 본문 정규화도 어긋나는" 겹친 경우로, 발송 1건당 1% 미만(위 추정)의 일부.
- 3번이 틀리는 방향(iPhone 글을 메아리로 오인)을 막기 위해 "대기 1건 + 워터마크 뒤 첫 행"을 모두 요구한다.

## 재현 방법(본문 없이 메타만)

chat.db 는 읽기 전용으로 열고, `text`·`attributedBody`·`payload_data`·`message_summary_info` 등 본문 계열은 빼고 덤프했다.
대응 근거는 상태 DB(`outbox.matched_guid`, `mapping`)와 `~/Library/Logs/bluehop.log` 의 `메아리 확인 rowid=` 줄이다.
