# 실측 사실과 그것을 지키는 테스트

실제 chat.db·메시지 앱에서 확인한 사실(2026-10-14, macOS 26.0.1)을 테스트로 고정한다. fixture 의 본문은 테스트용 문자열, GUID 는 가짜다.
사실이 바뀌면(macOS 업데이트 등) 이 표와 테스트를 같이 고친다. 첨부 전송 제약의 근거는 `imessage-limits.md` §2-1.

## 첨부 (텔레그램 → iMessage)

| 사실 | 테스트 |
|---|---|
| 메시지 앱은 샌드박스라 허용 폴더(`~/Library/Caches/com.apple.MobileSMS/` 등) 밖 파일을 못 읽는다. 기본 첨부 폴더는 그 안이고 `~/Library/Messages` 가 아니다 | `RelayTests.testDefaultOutboxIsReadableByMessagesSandbox` |
| 허용 밖 폴더로 설정돼 있으면 사진·캡션 모두 보내지 않고 ⚠️ 로 알린다(반쪽 발송 없음) | `testPhotoIsNotSentFromFolderMessagesCannotRead` |
| 내가 보낸 첨부 행: `text` NULL, `attributedBody` = U+FFFC 하나 → 글 없음으로 본다. `transfer_name` = 보낸 파일 이름(메아리 키) | `ObservedShapeTests.testOwnAttachmentRowHasNoTextOnlyPlaceholder` |
| 실패 행: `error=25`, `is_sent=0`, `is_delivered=0`, attachment `transfer_state=6`, `filename` = 넘긴 경로 그대로, `mime_type=image/jpeg` | `testFailedAttachmentRowKeepsSentPathAndError25` |
| 성공 행: `error=0`, `is_sent=1`, `transfer_state=5`, `filename` = `~/Library/Messages/Attachments/…/원래이름` 사본 | `testSendDiagRowsReadsSuccessShape` |
| 사진+캡션은 chat.db 에 **두 행**(첨부 행 → 캡션 글 행 순). 사진만 실패해도 캡션은 간다 | `testAttachmentMatrix` |
| 사진 `photo-<id>.jpg`, 음성 `voice-<id>.m4a`(ogg 변환), 파일은 원래 이름 — 모두 `<첨부폴더>/<매핑 id>/<텔레그램 id>/`(0700, 0.5.0 부터 매핑 폴더 아래) | `testAttachmentMatrix`, `MultiMappingConfigTests.testPerMappingOptionsUseOwnStagingFolder` |
| 사진·음성·파일 × 캡션 유무 × 성공/error=25 12가지: 보내는 순서, outbox 상태, 메아리 미재게시, ⚠️ 는 실패 때만 1번(원인 설명 포함) | `testAttachmentMatrix` |
| 첨부 실패 ⚠️ 는 폴더가 원인이면 "샌드박스", 아니면 다른 원인을 적는다 | `testAttachmentErrorIsExplainedInWarning`, `testFailureDetailWhenFolderIsReadable` |
| 중계한 음성(`voice-<id>.m4a`) 행은 `is_audio_message=0`, `expire_state=0`, `mime=audio/x-m4a`, `uti=com.apple.m4a-audio` — 음성 말풍선이 아니라 오디오 파일 첨부(2026-10-15, `imessage-limits.md` §2-2) | `ObservedShapeTests.testRelayedVoiceRowIsPlainAudioAttachmentNotAudioMessage`, `testAudioDiagIncludesFlaggedAudioMessageAndHidesOtherNames` |
| 보낸 사본은 결과 확정 + 1시간 뒤 지운다. 미확정이면 남긴다. `diag-` 폴더도 정리, 모르는 폴더는 안 건드린다 | `testCleanupWaitsForResultAndAge`, `testCleanupKeepsFilesUntilSendIsResolved` |

## 글·답글·반응

| 사실 | 테스트 |
|---|---|
| 메시지 앱은 보낸 한글을 NFD 로, `text` 를 비우고 `attributedBody` 에만 적는다 | `testObservedNFDFixtureShape`, `testEchoesWrittenAsNFDAttributedBodyAllMatch` |
| 줄바꿈이 U+2028 로, 따옴표·대시가 둥근 꼴로 적힐 수 있다 | `testMultilineTextEchoedWithUnicodeLineSeparatorStillMatches`, `testSmartPunctuationEchoStillMatches` |
| 상대 답글의 `thread_originator_part`: 첨부 행이면 `0:0:1`, 글 행이면 `0:0:<길이>` — 둘 다 원래 텔레그램 글에 답글로 잇는다 | `testCounterpartRepliesToPhotoAndCaptionThreadOnTelegram`, `testReplyUsesMappedTelegramMessage` |
| 상대가 한 글에 여러 말풍선으로 연달아 답하면 행마다 같은 `thread_originator_guid` 가 붙는다(반응 행이 사이에 낄 수 있다, 2026-10-15). 텔레그램에는 첫 말풍선만 답글로 건다 | `RichLinkRelayTests.testObservedLinkReplyRunBecomesOneLinkCardAndOneReplyHeader`, `testReplyHeaderReturnsAfterAnotherMessageInterleaves` |
| 상대 반응 행은 `text` 가 차 있고(`Loved …`) `associated_message_guid=p:0/<GUID>`, 기본 반응은 emoji NULL — 글로 중계하지 않고 반응으로 단다 | `testCounterpartReactionRowWithTextBecomesReactionOnly`, `testTapbacksBecomeTelegramReactions` |
| 상대가 같은 글의 반응을 바꾸면(예: 👀 → ✅) chat.db 에 "지움" 행이 따로 오지 않는다 — 옛 `associated_message_type` 행이 사라지고 새 반응의 add 행(2006, 임의 이모지)만 남는다(2026-10-15). 그래서 교체 처리는 remove 이벤트를 기다리지 않고 새 add 행 하나로 끝낸다 | `testReactionChangeReplacesPreviousTelegramReaction`, `testReactionChangeToUnmappedEmojiClearsStaleBotReactionBeforeFallback` |

## 링크 (2026-10-15, macOS 26.0.1)

| 사실 | 테스트 |
|---|---|
| 링크 말풍선은 앞뒤 글과 따로 한 행이다. `balloon_bundle_id = com.apple.messages.URLBalloonProvider`, 본문 = 주소 그대로(`text` 가 NULL 이고 `attributedBody` 에만 있을 때도 있다) | `testLinkBalloonWithBodyOnlyInAttributedBodyIsNotHeldForPreviewImages` |
| 미리보기 아이콘·대표 그림이 그 행의 첨부(1~3개)로 붙는다: 이름 `<UUID>.pluginPayloadAttachment`, `mime_type` NULL, `uti = dyn.age81a5dzq7y066dbtf0g82peqf4hk2pdrb00n5xy`, 내용은 PNG/ICO. 파일로 올리면 텔레그램에 열 수 없는 문서가 쌓인다 | `testObservedLinkReplyRunBecomesOneLinkCardAndOneReplyHeader` |
| 제목·사이트·요약은 `payload_data`(NSKeyedArchiver) `root(RichLink) → richLinkMetadata(LPLinkMetadata)` 의 `title`·`siteName`·`summary`·`URL`·`originalURL`(NSURL = `NS.base`/`NS.relative`). `URL` 은 정규화된 주소라 원래 주소(쿼리 포함)와 다를 수 있다 | `RichLinkParsingTests.testParsesObservedPayloadShape` |
| 내가 iPhone 에서 보낸 링크 행은 첨부 없이 메타데이터 없는 `RichLink` 자리표시 payload 만 있고, 뒤따른 글은 다른 행이 된다 | `testOwnLinkBalloonFromIPhoneIsMirroredAsURL` |
| 같은 주소가 링크 말풍선 행과 옆 글 행에 겹쳐 적힌 경우는 이 대화에서 보지 못했다(옆 글에 든 주소는 다른 링크였다) | — |

## 서비스 상태 (`launchctl print`)

| 사실 | 테스트 |
|---|---|
| 출력은 탭 들여쓰기 블록이고 서비스 속성은 깊이 1 이다. 하위 블록 `resource coalition`·`jetsam coalition` 에도 `state = active` 가 있고 최상위 `state = running` 보다 뒤에 나온다 | `CLIParsingTests.testServiceStateIgnoresNestedCoalitionState` |

## chat.db 파일

| 사실 | 테스트 |
|---|---|
| `~/Library/Messages` 에 `chat.db-wal`·`chat.db-shm` 이 있다 — chat.db 는 WAL 모드다(2026-10-15, macOS 26.0.1, 목록만 확인). fixture 도 WAL 로 만들어, 여러 일꾼이 읽기 전용으로 읽는 동안 새 행이 써져도 서로 막지 않는 실제 조건을 흉내 낸다 | `MultiMappingRelayTests.testFailingWorkerDoesNotStopAnother`, `testWorkerThatCannotStartRetriesWhileOthersRun` |
