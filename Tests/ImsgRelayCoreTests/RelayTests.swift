import Foundation
import XCTest
@testable import ImsgRelayCore

/// iMessage → 텔레그램 (우선순위 1: 가장 충실하게)
final class IMessageToTelegramTests: XCTestCase {
    func testBaselineDoesNotReplayHistory() async throws {
        let fx = try FixtureChatDB()
        try fx.insert(text: "옛날 메시지")
        let h = try Harness.make(fixture: fx)
        try await h.relay.start()
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)
    }

    func testNewTextIsRelayedOnceAcrossRestart() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let (_, guid) = try h.fixture.insert(text: nil, blobText: "안녕하세요")
        await h.relay.tick()
        let sent = MockTelegram.calls("sendMessage")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].json["text"] as? String, "안녕하세요")
        XCTAssertNotNil(try h.state.tgMessageID(forGuid: guid))

        // 재시작: 같은 상태 DB 로 새 엔진 → 다시 보내지 않는다
        let h2 = try Harness.make(fixture: h.fixture, statePath: h.statePath)
        try await h2.relay.start()
        await h2.relay.tick()
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)
    }

    func testOtherChatsAreNeverRelayed() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        try h.fixture.insert(chat: 2, text: "다른 사람")
        try h.fixture.insert(chat: 3, text: "단체방")
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)
    }

    func testReplyUsesMappedTelegramMessage() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let (_, original) = try h.fixture.insert(text: "원문")
        await h.relay.tick()
        let originalTG = try XCTUnwrap(h.state.tgMessageID(forGuid: original))
        try h.fixture.insert(text: "답글", threadOriginator: original, threadPart: "0:0:2")
        await h.relay.tick()
        let reply = MockTelegram.calls("sendMessage").last!
        XCTAssertEqual(reply.json["text"] as? String, "답글")
        XCTAssertEqual((reply.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, originalTG)
    }

    func testReplyToUnmappedOldMessageQuotes() async throws {
        let fx = try FixtureChatDB()
        let (_, old) = try fx.insert(text: "기준선 이전의 아주 오래된 메시지입니다")
        let h = try Harness.make(fixture: fx)
        try await h.relay.start()
        try fx.insert(text: "그거 말이야", threadOriginator: old)
        await h.relay.tick()
        let t = MockTelegram.calls("sendMessage").last!.json["text"] as? String
        XCTAssertEqual(t, "↪ \"기준선 이전의 아주 오래된 메시지입니다\"\n그거 말이야")
    }

    func testTapbacksBecomeTelegramReactions() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let (_, target) = try h.fixture.insert(text: "반응 받을 글")
        await h.relay.tick()
        let tgID = try XCTUnwrap(h.state.tgMessageID(forGuid: target))

        try h.fixture.insert(assocType: 2000, assocGuid: "p:0/\(target)")       // ❤️
        await h.relay.tick()
        var r = MockTelegram.calls("setMessageReaction").last!
        XCTAssertEqual(r.json["message_id"] as? Int64, tgID)
        XCTAssertEqual(((r.json["reaction"] as? [[String: Any]])?.first)?["emoji"] as? String, "❤")

        try h.fixture.insert(assocType: 2006, assocGuid: "p:0/\(target)", assocEmoji: "🔥")  // iOS 17+ 임의 이모지
        await h.relay.tick()
        r = MockTelegram.calls("setMessageReaction").last!
        XCTAssertEqual(((r.json["reaction"] as? [[String: Any]])?.first)?["emoji"] as? String, "🔥")

        try h.fixture.insert(assocType: 3006, assocGuid: "p:0/\(target)", assocEmoji: "🔥")  // 취소
        await h.relay.tick()
        r = MockTelegram.calls("setMessageReaction").last!
        XCTAssertEqual((r.json["reaction"] as? [Any])?.count, 0)
    }

    func testUnsupportedReactionFallsBackToReplyText() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let (_, target) = try h.fixture.insert(text: "강조할 글")
        await h.relay.tick()
        let tgID = try XCTUnwrap(h.state.tgMessageID(forGuid: target))
        try h.fixture.insert(assocType: 2004, assocGuid: "p:0/\(target)")  // ‼️ 는 봇 반응 목록에 없음
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.calls("setMessageReaction").isEmpty)
        let m = MockTelegram.calls("sendMessage").last!
        XCTAssertEqual(m.json["text"] as? String, "‼️ 반응")
        XCTAssertEqual((m.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, tgID)
    }

    func testReactionRejectedByTelegramFallsBack() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let (_, target) = try h.fixture.insert(text: "글")
        await h.relay.tick()
        MockTelegram.failures["setMessageReaction"] = ["ok": false, "error_code": 400, "description": "Bad Request: REACTION_INVALID"]
        try h.fixture.insert(assocType: 2001, assocGuid: "p:0/\(target)")
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").last!.json["text"] as? String, "👍 반응")
    }

    func testVoiceMemoIsConvertedAndSentAsVoice() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let path = h.fixture.makeAttachmentFile("Audio Message.caf")
        try h.fixture.insert(audio: true, attachments: [("Audio Message.caf", path, nil)])
        await h.relay.tick()
        XCTAssertEqual(h.converter.calls, ["m4a"])
        let v = try XCTUnwrap(MockTelegram.calls("sendVoice").first)
        XCTAssertTrue(v.multipart.contains("filename=\"Audio Message.m4a\""))
        XCTAssertTrue(v.multipart.contains("name=\"chat_id\"\r\n\r\n555"))
    }

    func testHeicPhotoWithTextAndPartMapping() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let path = h.fixture.makeAttachmentFile("IMG_0001.HEIC")
        let (_, guid) = try h.fixture.insert(text: "\u{FFFC}사진 봐", attachments: [("IMG_0001.HEIC", path, "image/heic")])
        await h.relay.tick()
        XCTAssertEqual(h.converter.calls, ["jpg"])
        XCTAssertEqual(MockTelegram.calls("sendPhoto").count, 1)
        XCTAssertEqual(MockTelegram.calls("sendMessage").last!.json["text"] as? String, "사진 봐")
        let photoID = try XCTUnwrap(h.state.tgMessageID(forGuid: guid, part: 0))
        let textID = try XCTUnwrap(h.state.tgMessageID(forGuid: guid, part: 1))
        XCTAssertNotEqual(photoID, textID)
    }

    func testMediaRejectedFallsBackToDocument() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.failures["sendPhoto"] = ["ok": false, "error_code": 400, "description": "Bad Request: IMAGE_PROCESS_FAILED"]
        let path = h.fixture.makeAttachmentFile("a.png")
        try h.fixture.insert(attachments: [("a.png", path, "image/png")])
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendDocument").count, 1)
    }

    func testWaitsForAttachmentThenPlaceholder() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let cursor0 = h.state.imsgCursor
        try h.fixture.insert(attachments: [("late.jpg", h.fixture.attachmentsRoot.path + "/notyet/late.jpg", "image/jpeg")])
        try h.fixture.insert(text: "다음 글")
        await h.relay.tick()
        XCTAssertEqual(h.state.imsgCursor, cursor0)                // 순서를 지키려 커서 정지
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)
        h.clock.now += 301
        await h.relay.tick()
        let texts = MockTelegram.calls("sendMessage").compactMap { $0.json["text"] as? String }
        XCTAssertEqual(texts, ["[첨부를 받지 못함: late.jpg]", "다음 글"])
    }

    func testOwnMessagesFromOtherDevicesAreMirrored() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        try h.fixture.insert(text: "아이폰에서 보낸 글", fromMe: true)
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").last!.json["text"] as? String, "🙋 나: 아이폰에서 보낸 글")
    }

    func testOwnReactionIsShownAsTextNotBotReaction() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let (_, target) = try h.fixture.insert(text: "상대 글")
        await h.relay.tick()
        let tgID = try XCTUnwrap(h.state.tgMessageID(forGuid: target))
        try h.fixture.insert(fromMe: true, assocType: 2000, assocGuid: "p:0/\(target)")
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.calls("setMessageReaction").isEmpty)
        let m = MockTelegram.calls("sendMessage").last!
        XCTAssertEqual(m.json["text"] as? String, "🙋 나: ❤️ 반응")
        XCTAssertEqual((m.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, tgID)
    }

    func testOwnMessagesNotMirroredWhenDisabled() async throws {
        let h = try Harness.make { $0.mirrorOwnMessages = false }
        try await h.relay.start()
        try h.fixture.insert(text: "안 보여야 함", fromMe: true)
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)
    }
}

/// 텔레그램 → iMessage (우선순위: 실수 없음)
final class TelegramToIMessageTests: XCTestCase {
    func testTextIsSentConfirmedAndNotEchoedBack() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "텔레그램에서 쓴 글")])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.count, 1)
        XCTAssertEqual(h.sender.sent[0].payload, "텔레그램에서 쓴 글")
        XCTAssertEqual(h.sender.sent[0].chat, FixtureChatDB.chatGuid)
        // 메아리(내 메시지 행)는 텔레그램으로 되돌려 보내지 않고, 성공 표시(반응)도 달지 않는다
        // — 사용자 글에 달리는 반응은 상대가 단 것만 남는다.
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)
        XCTAssertTrue(MockTelegram.calls("setMessageReaction").isEmpty)
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])
        XCTAssertNil(try h.state.outbox(tgMessageID: 42)[0].matchKey)  // 확인되면 본문을 지운다
        XCTAssertEqual(h.state.tgOffset, 2)
    }

    func testRepliesToRelayedOwnMessageThreadOnTelegram() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "질문 있어")])
        await h.relay.tick()
        let echoGuid = try XCTUnwrap(h.state.imsgGuid(forTG: 42).map { $0 })
        // 상대가 그 메시지에 답글 → 텔레그램에서 42 에 대한 답글로
        try h.fixture.insert(text: "답이야", threadOriginator: echoGuid)
        await h.relay.tick()
        let m = MockTelegram.calls("sendMessage").last!
        XCTAssertEqual((m.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 42)
    }

    func testStrangersAndOtherChatsAreIgnored() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([
            Harness.textUpdate(1, messageID: 10, text: "낯선 사람", from: 999),
            Harness.textUpdate(2, messageID: 11, text: "다른 방", chat: 12345),
        ])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)  // 답장도 안 한다
        XCTAssertEqual(h.state.tgOffset, 3)
    }

    func testSameTelegramMessageIsNeverSentTwice() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let u = Harness.textUpdate(1, messageID: 42, text: "한 번만")
        MockTelegram.enqueue([u])
        await h.relay.tick()
        try h.state.setTGOffset(0)  // offset 저장 전에 죽었다고 가정 → 같은 업데이트가 다시 옴
        MockTelegram.enqueue([u])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.count, 1)
    }

    func testCrashMidSendIsNotRetried() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        // 이전 프로세스가 'sending' 기록 후 죽은 상황
        try h.state.insertOutbox(OutboxEntry(tgMessageID: 42, part: 0, kind: "text", matchKey: "x", status: .sending, createdAt: h.clock.now, detail: nil))
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "x")])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)
        h.clock.now += 61
        await h.relay.tick()
        let warn = MockTelegram.calls("sendMessage").last!.json["text"] as? String
        XCTAssertTrue(warn?.contains("보내는 도중 중계기가 멈춤") == true)
        XCTAssertTrue(h.sender.sent.isEmpty)
    }

    func testSendFailureIsReportedWithoutRetry() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.failNext = true
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "실패할 글")])
        await h.relay.tick()
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)
        let warns = MockTelegram.calls("sendMessage")
        XCTAssertEqual(warns.count, 1)
        XCTAssertEqual((warns[0].json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 42)
        XCTAssertTrue((warns[0].json["text"] as? String)?.contains("자동으로 다시 보내지 않았습니다") == true)
    }

    func testMissingEchoTimesOutAsFailure() async throws {
        let h = try Harness.make()
        h.sender.echoInto = nil  // 메시지 앱이 기록하지 않음
        try await h.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "기록 안 됨")])
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)  // 아직 기다리는 중
        h.clock.now += 61
        await h.relay.tick()
        XCTAssertTrue((MockTelegram.calls("sendMessage").last?.json["text"] as? String)?.contains("확인되지 않음") == true)
    }

    func testMessagesAppErrorIsReported() async throws {
        let h = try Harness.make()
        h.sender.echoError = 22
        try await h.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "전송 실패 표시")])
        await h.relay.tick()
        XCTAssertTrue((MockTelegram.calls("sendMessage").last?.json["text"] as? String)?.contains("error=22") == true)
    }

    // 사고 2026-10-14: 첨부를 메시지 앱이 못 읽는 폴더에 두고 보내 chat.db 에 error=25 만 남았다.
    func testDefaultOutboxIsReadableByMessagesSandbox() {
        XCTAssertTrue(MessagesSandbox.canRead(Paths.defaultOutboxDir))
        XCTAssertFalse(Paths.defaultOutboxDir.hasPrefix(Paths.home + "/Library/Messages"))  // Messages 폴더엔 쓰지 않는다
        XCTAssertFalse(MessagesSandbox.canRead(Paths.supportDir + "/outbox"))  // 예전 기본값은 못 읽는다
        XCTAssertFalse(MessagesSandbox.canRead("/tmp/x.jpg"))
        XCTAssertFalse(MessagesSandbox.canRead(Paths.home + "/Pictures/x.jpg"))
        XCTAssertFalse(MessagesSandbox.canRead(Paths.home + "/Library/Caches/com.apple.MobileSMSX/x.jpg"))
    }

    func testPhotoIsNotSentFromFolderMessagesCannotRead() async throws {
        let h = try Harness.make { $0.requireMessagesReadableOutbox = true }
        try await h.relay.start()
        MockTelegram.enqueue([["update_id": 1, "message": [
            "message_id": 42, "chat": ["id": Harness.chatID], "from": ["id": Harness.userID], "caption": "사진",
            "photo": [["file_id": "L", "file_size": 9, "width": 800, "height": 600]],
        ] as [String: Any]]])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)  // 캡션만 가는 반쪽 발송도 없음
        let notice = MockTelegram.calls("sendMessage").last?.json["text"] as? String
        XCTAssertTrue(notice?.contains("메시지 앱이 읽을 수 없어") == true)
    }

    func testAttachmentErrorIsExplainedInWarning() async throws {
        let h = try Harness.make()
        h.sender.echoError = 25
        try await h.relay.start()
        MockTelegram.enqueue([["update_id": 1, "message": [
            "message_id": 42, "chat": ["id": Harness.chatID], "from": ["id": Harness.userID],
            "photo": [["file_id": "L", "file_size": 9, "width": 800, "height": 600]],
        ] as [String: Any]]])
        await h.relay.tick()
        let notice = MockTelegram.calls("sendMessage").last?.json["text"] as? String
        XCTAssertTrue(notice?.contains("error=25") == true)
        XCTAssertTrue(notice?.contains("첨부") == true)
        // 임시 폴더(메시지 앱이 못 읽는 곳)라 원인을 폴더로 짚는다
        XCTAssertTrue(notice?.contains("샌드박스") == true)
    }

    func testFailureDetailWhenFolderIsReadable() {
        let d = MessagesSandbox.failureDetail(kind: "file", errorCode: 25, outboxDir: Paths.defaultOutboxDir)
        XCTAssertTrue(d.contains("error=25"))
        XCTAssertFalse(d.contains("샌드박스"))
        XCTAssertEqual(MessagesSandbox.failureDetail(kind: "text", errorCode: 22, outboxDir: "/tmp"), "메시지 앱이 실패로 표시(error=22)")
    }

    func testCleanupKeepsFilesUntilSendIsResolved() async throws {
        let h = try Harness.make()
        h.sender.echoInto = nil  // 메아리가 아직 안 옴 → 확인 대기
        try await h.relay.start()
        MockTelegram.enqueue([["update_id": 1, "message": [
            "message_id": 42, "chat": ["id": Harness.chatID], "from": ["id": Harness.userID],
            "photo": [["file_id": "L", "file_size": 9, "width": 800, "height": 600]],
        ] as [String: Any]]])
        await h.relay.tick()
        let dir = h.workDir.appendingPathComponent("outbox/42")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        h.relay.cleanupOutboxFiles(olderThan: -1)  // 시간 조건은 이미 지났다고 본다
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))  // 결과 미확정이라 남긴다
        try h.state.updateOutbox(tgMessageID: 42, part: 0, status: .confirmed)
        h.relay.cleanupOutboxFiles(olderThan: -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testTelegramReplyBecomesQuotePrefix() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "응 좋아", replyTo: (900, "🙋 나: 내일 몇 시에 볼까 저녁은 어디서 먹을까 고민이야"))])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent[0].payload, "↪ \"내일 몇 시에 볼까 저녁은 어디서 먹을까 고민이야\"\n응 좋아")
    }

    func testEditsAreNotResent() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        var u = Harness.textUpdate(1, messageID: 42, text: "수정본")
        u["edited_message"] = u.removeValue(forKey: "message")
        MockTelegram.enqueue([u])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)
        XCTAssertTrue((MockTelegram.calls("sendMessage").last?.json["text"] as? String)?.contains("수정한 내용") == true)
    }

    func testVoiceIsDownloadedConvertedAndSentAsFile() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([["update_id": 1, "message": [
            "message_id": 42, "chat": ["id": Harness.chatID], "from": ["id": Harness.userID],
            "voice": ["file_id": "VOICE1", "file_size": 9],
        ] as [String: Any]]])
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("getFile").count, 1)
        XCTAssertEqual(MockTelegram.calls("file").count, 1)
        XCTAssertEqual(h.converter.calls, ["m4a"])
        XCTAssertEqual(h.sender.sent.map(\.kind), ["file"])
        XCTAssertTrue(h.sender.sent[0].payload.hasSuffix("/42/voice-42.m4a"))
        XCTAssertTrue(h.sender.sent[0].payload.hasPrefix(h.workDir.appendingPathComponent("outbox").path))
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])
    }

    func testPhotoWithCaptionSendsFileThenText() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([["update_id": 1, "message": [
            "message_id": 42, "chat": ["id": Harness.chatID], "from": ["id": Harness.userID], "caption": "이거 봐",
            "photo": [["file_id": "S", "file_size": 5, "width": 90, "height": 90], ["file_id": "L", "file_size": 9, "width": 800, "height": 600]],
        ] as [String: Any]]])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.map(\.kind), ["file", "text"])
        XCTAssertEqual(h.sender.sent[1].payload, "이거 봐")
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed, .confirmed])
        XCTAssertTrue(MockTelegram.calls("setMessageReaction").isEmpty)
    }

    func testOversizeAttachmentSendsNothing() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([["update_id": 1, "message": [
            "message_id": 42, "chat": ["id": Harness.chatID], "from": ["id": Harness.userID], "caption": "큰 파일",
            "document": ["file_id": "D", "file_size": 30_000_000, "file_name": "big.zip"],
        ] as [String: Any]]])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)  // 캡션만 따로 보내는 반쪽 발송도 없음
        XCTAssertTrue((MockTelegram.calls("sendMessage").last?.json["text"] as? String)?.contains("아무것도 보내지 않았습니다") == true)
    }

    func testSlashCommandsAndEscape() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 40, text: "/pause")])
        await h.relay.tick()
        XCTAssertTrue(h.relay.isHalted)
        MockTelegram.enqueue([Harness.textUpdate(2, messageID: 41, text: "정지 중 글")])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)
        MockTelegram.enqueue([Harness.textUpdate(3, messageID: 43, text: "/resume")])
        await h.relay.tick()
        XCTAssertFalse(h.relay.isHalted)
        MockTelegram.enqueue([Harness.textUpdate(4, messageID: 44, text: "//slash 로 시작")])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.map(\.payload), ["/slash 로 시작"])
        // 정지 중에 거부된 글은 재개 뒤에도 보내지 않는다
        XCTAssertFalse(h.sender.sent.contains { $0.payload == "정지 중 글" })
    }

    func testTelegramReactionIgnoredByDefaultAndTextWhenEnabled() async throws {
        let reactionUpdate: [String: Any] = ["update_id": 9, "message_reaction": [
            "chat": ["id": Harness.chatID], "message_id": 42, "user": ["id": Harness.userID],
            "old_reaction": [], "new_reaction": [["type": "emoji", "emoji": "❤"]],
        ] as [String: Any]]
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([reactionUpdate])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)

        let h2 = try Harness.make { $0.reactionMode = .text }
        try await h2.relay.start()
        let (_, guid) = try h2.fixture.insert(text: "상대 글")
        await h2.relay.tick()
        let tgID = try XCTUnwrap(h2.state.tgMessageID(forGuid: guid))
        var u = reactionUpdate
        var r = u["message_reaction"] as! [String: Any]
        r["message_id"] = tgID
        u["message_reaction"] = r
        MockTelegram.enqueue([u])
        await h2.relay.tick()
        XCTAssertEqual(h2.sender.sent.map(\.payload), ["❤ ↪ \"상대 글\""])
        MockTelegram.enqueue([u])  // 같은 업데이트 재전달 → 다시 안 보냄
        await h2.relay.tick()
        XCTAssertEqual(h2.sender.sent.count, 1)
    }
}

final class SafetyStopTests: XCTestCase {
    func testBacklogOnStartHalts() async throws {
        let h = try Harness.make { $0.limits.maxBacklog = 3 }
        try h.state.setIMsgCursor(0)
        for i in 0..<5 { try h.fixture.insert(text: "밀린 \(i)") }
        try await h.relay.start()
        XCTAssertTrue(h.relay.isHalted)
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").count, 1)  // 정지 알림 1건만
        try h.relay.resume(skipBacklog: true)
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").count, 1)  // 건너뛰었으니 쏟지 않음
    }

    func testFloodTripsBreaker() async throws {
        let h = try Harness.make {
            $0.limits.toTelegramPerWindow = 3
            $0.limits.toTelegramPerMinute = 100
        }
        try await h.relay.start()
        for i in 0..<6 { try h.fixture.insert(text: "폭주 \(i)") }
        await h.relay.tick()
        XCTAssertTrue(h.relay.isHalted)
        let texts = MockTelegram.calls("sendMessage").compactMap { $0.json["text"] as? String }
        XCTAssertEqual(texts.filter { $0.hasPrefix("폭주") }.count, 3)
        XCTAssertTrue(texts.contains { $0.contains("안전 정지") })
        let cursor = h.state.imsgCursor
        await h.relay.tick()
        XCTAssertEqual(h.state.imsgCursor, cursor)  // 정지 중엔 진행하지 않음
    }

    func testIMessageFloodTrips() async throws {
        let h = try Harness.make {
            $0.limits.toIMessagePerWindow = 2
            $0.limits.toIMessagePerMinute = 100
        }
        try await h.relay.start()
        MockTelegram.enqueue((1...4).map { Harness.textUpdate(Int64($0), messageID: Int64(100 + $0), text: "글 \($0)") })
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.count, 2)
        XCTAssertTrue(h.relay.isHalted)
    }

    func testRateLimitSpacesTelegramSends() async throws {
        let h = try Harness.make { $0.limits.toTelegramPerMinute = 2 }
        try await h.relay.start()
        for i in 0..<3 { try h.fixture.insert(text: "글 \(i)") }
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").count, 3)
        XCTAssertGreaterThanOrEqual(h.clock.slept, 29.9)  // 세 번째는 기다렸다 보냄
    }
}

/// 사고 2026-10-14 재발 방지: 켜기 전 텔레그램 백로그, 멈춰 있던 사이 늦게 처리된 글.
final class TelegramBaselineAndFreshnessTests: XCTestCase {
    /// 설정 과정에서 봇에게 보낸 글(예: 'Hi')이 켜기 전 백로그로 남아 있어도,
    /// 첫 시작은 그 백로그를 전부 확인 처리(offset 만 올림)만 하고 iMessage 로 보내지 않는다.
    func testFirstStartDoesNotRelayTelegramBacklog() async throws {
        let h = try Harness.make()
        MockTelegram.enqueue([
            Harness.textUpdate(1, messageID: 900, text: "Hi"),
            Harness.textUpdate(2, messageID: 901, text: "둘째 백로그"),
        ])
        try await h.relay.start()

        XCTAssertTrue(h.sender.sent.isEmpty)  // 사고의 핵심 회귀 포인트: iMessage 전송 0건
        XCTAssertEqual(h.state.tgOffset, 3)
        XCTAssertTrue(h.state.hasTGBaseline)
        XCTAssertEqual(MockTelegram.calls("sendMessage").last?.json["text"] as? String,
                       "ℹ️ 켜기 전 메시지 2개는 보내지 않았습니다.")

        // 큐가 비었으니 이후 틱에서도 같은 백로그를 다시 처리하지 않는다(멱등성 재확인)
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)

        // 켠 뒤 새로 온 글은 정상 처리된다
        MockTelegram.enqueue([Harness.textUpdate(3, messageID: 902, text: "켠 뒤 글")])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.map(\.payload), ["켠 뒤 글"])
    }

    /// 백로그가 없으면 안내 없이 조용히 기준선(offset=0)만 잡는다.
    func testFirstStartWithNoBacklogSendsNoNotice() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        XCTAssertTrue(h.state.hasTGBaseline)
        XCTAssertEqual(h.state.tgOffset, 0)
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)
    }

    /// 재시작(기준선이 이미 있음)에 중계기가 멈춰 있던 사이 쌓인 글 중, 10분보다 오래된 것은
    /// iMessage 로 보내지 않고 ⚠️ 답글로 알린다. 같은 배치의 최신 글은 정상 처리한다.
    func testLateTelegramMessageIsNotRelayedButFreshOneIs() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let now = Int64(h.clock.now)
        MockTelegram.enqueue([
            Harness.textUpdate(1, messageID: 42, text: "오래된 지시", date: now - 700),
            Harness.textUpdate(2, messageID: 43, text: "방금 쓴 글", date: now - 5),
        ])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.map(\.payload), ["방금 쓴 글"])
        let warn = try XCTUnwrap(MockTelegram.calls("sendMessage").first {
            ($0.json["text"] as? String)?.contains("오래돼서 안 보냄") == true
        })
        XCTAssertEqual((warn.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 42)
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.failed])
    }

    /// date 가 기준(10분) 안쪽이면 평소처럼 보낸다 — 문턱값 경계 회귀 확인.
    func testMessageJustWithinThresholdIsStillRelayed() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let now = Int64(h.clock.now)
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 50, text: "9분 전 글", date: now - 540)])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sent.map(\.payload), ["9분 전 글"])
    }
}

/// 사고 2026-10-14(2): 메시지 앱이 여러 줄 글의 줄바꿈을 U+2028 로 바꿔 적어 메아리 본문 비교가
/// 실패하면, 사용자가 텔레그램으로 보낸 글이 "🙋 나: …"로 중복 게시되고, 상대 반응·답글이 원래
/// 글이 아니라 그 메아리에 붙고, 60초 뒤 실제로는 보낸 글에 거짓 ⚠️ 가 달렸다.
final class EchoMatchingAcrossLineBreaksTests: XCTestCase {
    func testMultilineTextEchoedWithUnicodeLineSeparatorStillMatches() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        // 메시지 앱이 chat.db 에 줄바꿈을 U+2028 로 바꿔 적는 것을 흉내낸다.
        h.sender.echoTextTransform = { $0.replacingOccurrences(of: "\n", with: "\u{2028}") }
        let text = "나 지금 kanziw/imsg-relay\n위에서 작업 중이야"
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: text)])
        await h.relay.tick()

        // 중복 게시 없음: 메아리로 맞춰져 텔레그램에 다시 글을 올리지 않는다.
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)
        // 원래 글(42)의 발송이 확인된다(성공 반응은 달지 않음) — 가짜 ⚠️ 타임아웃이 없다.
        XCTAssertTrue(MockTelegram.calls("setMessageReaction").isEmpty)
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])

        // 60초가 지나도 거짓 ⚠️ 가 달리지 않는다.
        h.clock.now += 61
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)

        // 상대가 그 글에 반응·답글을 하면 "🙋 나:" 메아리가 아니라 사용자의 원래 글(42)에 연결된다.
        let echoGuid = try XCTUnwrap(h.state.imsgGuid(forTG: 42))
        try h.fixture.insert(assocType: 2000, assocGuid: "p:0/\(echoGuid)")
        await h.relay.tick()
        let reactionCall = try XCTUnwrap(MockTelegram.calls("setMessageReaction").last)
        XCTAssertEqual(reactionCall.json["message_id"] as? Int64, 42)
    }

    /// 확인 안 된 텔레그램 발송이 남아 있는 동안엔 다른(관련 없는) is_from_me 글도 곧바로
    /// 미러하지 않고 잠깐 기다린다 — 유예가 끝나면 정상적으로 미러한다(안전망이 영원히 막지 않음).
    func testForeignMessageWhileTelegramSendUnresolvedWaitsThenMirrors() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        try h.state.insertOutbox(OutboxEntry(tgMessageID: 99, part: 0, kind: "text", matchKey: "다른 글",
                                             status: .sent, createdAt: h.clock.now, detail: nil))
        try h.fixture.insert(text: "iPhone 에서 직접 보낸 전혀 다른 글", fromMe: true)

        await h.relay.tick()
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)  // 유예 기간 — 아직 미러하지 않음

        h.clock.now += h.relay.options.echoGraceSeconds + 1
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").last?.json["text"] as? String,
                       "🙋 나: iPhone 에서 직접 보낸 전혀 다른 글")
    }
}

/// 사고 2026-10-14(3): 메시지 앱은 한글을 NFD(자모 분해)로, text 컬럼을 비운 채 attributedBody 에만 적는다.
/// 텔레그램 글(NFC)과 그대로 비교하면 ASCII 글('Hi')만 맞고 한국어 글은 모두 틀려 "🙋 나:" 메아리가
/// 다시 올라오고 상대 답글이 그 메아리에 붙었다. 실측: '[테스트 1/5] …' 46 스칼라(UTF-8 102B) →
/// chat.db 83 스칼라(UTF-8 213B), 둥근 따옴표 변환은 없었다.
final class EchoMatchingAcrossUnicodeFormsTests: XCTestCase {
    static let observed = "[테스트 1/5] 중계 테스트 글입니다. 보이면 짧게 \"확인\"이라고만 답해 주세요."

    func testObservedNFDFixtureShape() {
        let nfd = Self.observed.decomposedStringWithCanonicalMapping
        // 실측 바이트 모양을 고정한다(diag-echo rowid=1139).
        XCTAssertEqual(Self.observed.unicodeScalars.count, 46)
        XCTAssertEqual(Self.observed.utf8.count, 102)
        XCTAssertEqual(nfd.unicodeScalars.count, 83)
        XCTAssertEqual(nfd.utf8.count, 213)
        XCTAssertEqual(AttributedBody.extractText(AttributedBody.encodeForTesting(nfd)), nfd)
    }

    func testEchoesWrittenAsNFDAttributedBodyAllMatch() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.echoAsAttributedBody = true
        h.sender.echoTextTransform = { $0.decomposedStringWithCanonicalMapping }
        MockTelegram.enqueue([
            Harness.textUpdate(1, messageID: 41, text: "Hi"),
            Harness.textUpdate(2, messageID: 42, text: "한국어 한 줄 글입니다"),
            Harness.textUpdate(3, messageID: 43, text: Self.observed),
        ])
        await h.relay.tick()
        h.clock.now += h.relay.options.echoGraceSeconds + 61
        await h.relay.tick()

        XCTAssertEqual(h.sender.sent.count, 3)
        for id: Int64 in [41, 42, 43] {
            XCTAssertEqual(try h.state.outbox(tgMessageID: id).map(\.status), [.confirmed], "tg=\(id)")
            XCTAssertNotNil(try h.state.imsgGuid(forTG: id), "tg=\(id) 매핑")
        }
        // 메아리 재게시 없음 · 거짓 ⚠️ 없음 · 성공 반응 없음
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)
        XCTAssertTrue(MockTelegram.calls("setMessageReaction").isEmpty)
        XCTAssertFalse(h.logs.lines.contains { $0.contains("메아리 불일치") })

        // 상대 답글은 사용자의 원래 글(43)에 붙는다.
        let echoGuid = try XCTUnwrap(h.state.imsgGuid(forTG: 43))
        try h.fixture.insert(text: "확인", threadOriginator: echoGuid)
        await h.relay.tick()
        let reply = try XCTUnwrap(MockTelegram.calls("sendMessage").last)
        XCTAssertEqual((reply.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 43)
    }

    func testSmartPunctuationEchoStillMatches() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.echoAsAttributedBody = true
        h.sender.echoTextTransform = {
            $0.replacingOccurrences(of: "\"확인\"", with: "\u{201C}확인\u{201D}")
              .replacingOccurrences(of: "don't", with: "don\u{2019}t")
              .replacingOccurrences(of: "...", with: "\u{2026}")
              .replacingOccurrences(of: "--", with: "\u{2014}")
              .decomposedStringWithCanonicalMapping
        }
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "\"확인\" don't -- 음...")])
        await h.relay.tick()
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)
    }

    /// 정말 다른 글이면 유예 뒤 미러하되, 그 전에 기다리던 발송과의 닮은 정도를 본문 없이 남긴다.
    func testMismatchLogsFingerprintWithoutBodyBeforeMirroring() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        try h.state.insertOutbox(OutboxEntry(tgMessageID: 99, part: 0, kind: "text", matchKey: EchoKey.normalize("기다리는 글"),
                                             status: .sent, createdAt: h.clock.now, detail: nil))
        try h.fixture.insert(blobText: "전혀 다른 글", fromMe: true)
        await h.relay.tick()
        h.clock.now += h.relay.options.echoGraceSeconds + 1
        await h.relay.tick()
        let line = try XCTUnwrap(h.logs.lines.first { $0.contains("메아리 불일치") })
        XCTAssertTrue(line.contains("tg=99"))
        XCTAssertTrue(line.contains("len="))
        XCTAssertFalse(line.contains("다른 글"))
        XCTAssertFalse(line.contains("기다리는"))
        XCTAssertEqual(MockTelegram.calls("sendMessage").last?.json["text"] as? String, "🙋 나: 전혀 다른 글")
    }
}
