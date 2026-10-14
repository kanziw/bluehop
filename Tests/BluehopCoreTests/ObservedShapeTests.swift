import Foundation
import XCTest
@testable import BluehopCore

/// 실제 chat.db 에서 확인한 행 모양(2026-10-14, macOS 26.0.1)을 fixture 로 고정한 테스트.
/// 본문은 테스트용 문자열이고 GUID 는 가짜다. 각 테스트가 지키는 사실은 `docs/observed-facts.md` 표에 있다.
final class ObservedShapeTests: XCTestCase {

    // MARK: - 첨부 행 모양

    func testOwnAttachmentRowHasNoTextOnlyPlaceholder() throws {
        let fx = try FixtureChatDB()
        let staged = makeTempDir().appendingPathComponent("photo-42.jpg")
        try Data("jpeg".utf8).write(to: staged)
        try fx.insertObservedOwnAttachment(sentPath: staged.path, mime: "image/jpeg", uti: "public.jpeg", error: 0)
        let db = try fx.reader()
        let chat = try db.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        let m = try XCTUnwrap(db.messages(after: 0, chat: chat).first)
        XCTAssertEqual(AttributedBody.extractText(ObservedShapes.attachmentPlaceholderBody), "\u{FFFC}")
        XCTAssertEqual(m.text, "")                       // U+FFFC 는 지워져 글로 취급하지 않는다
        XCTAssertTrue(m.isFromMe)
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertEqual(m.attachments[0].transferName, "photo-42.jpg")  // 보낸 파일 이름이 그대로 남는다(메아리 키)
        XCTAssertNotNil(m.attachments[0].path)           // 성공하면 메시지 첨부 폴더 안 사본을 가리킨다
    }

    func testFailedAttachmentRowKeepsSentPathAndError25() throws {
        let fx = try FixtureChatDB()
        let staged = makeTempDir().appendingPathComponent("photo-16.jpg")
        try Data("jpeg".utf8).write(to: staged)
        try fx.insertObservedOwnAttachment(sentPath: staged.path, mime: "image/jpeg", uti: "public.jpeg", error: 25)
        let db = try fx.reader()
        let chat = try db.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        let m = try XCTUnwrap(db.messages(after: 0, chat: chat).first)
        XCTAssertEqual(m.errorCode, 25)
        XCTAssertNil(m.attachments[0].path)              // 넘긴 경로 그대로라 첨부 폴더 밖 → 읽지 않는다
        let diag = try XCTUnwrap(db.sendDiagRows(after: 0, chat: chat).first)
        XCTAssertEqual(diag.error, 25)
        XCTAssertFalse(diag.isSent)
        XCTAssertFalse(diag.isDelivered)
        XCTAssertEqual(diag.attachments.map(\.transferState), [6])
        XCTAssertEqual(diag.attachments.first?.filename, staged.path)
        XCTAssertEqual(diag.attachments.first?.mimeType, "image/jpeg")
    }

    func testSendDiagRowsReadsSuccessShape() throws {
        let fx = try FixtureChatDB()
        let staged = makeTempDir().appendingPathComponent("grad.jpg")
        try Data("jpeg".utf8).write(to: staged)
        try fx.insertObservedOwnAttachment(sentPath: staged.path, mime: "image/jpeg", uti: "public.jpeg", error: 0)
        let db = try fx.reader()
        let chat = try db.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        let diag = try XCTUnwrap(db.sendDiagRows(after: 0, chat: chat).first)
        XCTAssertEqual(diag.error, 0)
        XCTAssertTrue(diag.isSent)
        XCTAssertEqual(diag.attachments.map(\.transferState), [5])
        XCTAssertTrue(diag.attachments[0].filename.hasPrefix(fx.attachmentsRoot.path + "/"))
    }

    // MARK: - 음성 (텔레그램 → iMessage)

    /// 스크립트로 보낸 음성은 음성 메시지 플래그 없이 일반 오디오 파일 첨부 행이 된다(2026-10-15 실측, voice-24.m4a).
    func testRelayedVoiceRowIsPlainAudioAttachmentNotAudioMessage() throws {
        let fx = try FixtureChatDB()
        let staged = makeTempDir().appendingPathComponent("voice-24.m4a")
        try Data("m4a".utf8).write(to: staged)
        try fx.insertObservedOwnAttachment(sentPath: staged.path, mime: "audio/x-m4a", uti: "com.apple.m4a-audio", error: 0)
        try fx.insert(text: "글", fromMe: false)  // 오디오가 아닌 행은 진단에 나오지 않는다
        let db = try fx.reader()
        let chat = try db.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        let rows = try db.audioDiagRows(chat: chat)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertTrue(r.isFromMe)
        XCTAssertFalse(r.isAudioMessage)                 // 음성 말풍선 조건(is_audio_message=1)이 아니다
        XCTAssertEqual(r.expireState, 0)
        XCTAssertEqual(r.mimeType, "audio/x-m4a")
        XCTAssertEqual(r.uti, "com.apple.m4a-audio")
        XCTAssertEqual(r.fileExtension, "m4a")
        XCTAssertNotNil(r.path)
        XCTAssertEqual(ChatDB.transferNameClass(r.transferName), "voice-<id>.m4a")
    }

    func testAudioDiagIncludesFlaggedAudioMessageAndHidesOtherNames() throws {
        let fx = try FixtureChatDB()
        let p = fx.makeAttachmentFile("Audio Message.caf")
        try fx.insert(fromMe: true, audio: true, attachments: [(name: "Audio Message.caf", path: p, mime: nil)])
        try fx.insert(chat: 2, fromMe: true, audio: true, attachments: [(name: "Audio Message.caf", path: p, mime: nil)])  // 다른 대화는 안 본다
        let db = try fx.reader()
        let chat = try db.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        let rows = try db.audioDiagRows(chat: chat)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isAudioMessage)
        XCTAssertEqual(rows[0].fileExtension, "caf")
        XCTAssertEqual(ChatDB.transferNameClass("Audio Message.caf"), "\"Audio Message.caf\"")
        XCTAssertEqual(ChatDB.transferNameClass("엄마 생일 녹음.MP3"), "기타(.mp3)")  // 사람이 지은 이름은 출력하지 않는다
    }

    // MARK: - 사진·음성·파일 × 캡션 × 성공/실패 표

    struct Case {
        var kind: String          // photo | voice | document
        var caption: String?
        var fileError: Int        // 0 = 성공, 25 = 메시지 앱이 파일을 못 읽음
    }

    static func update(_ c: Case) -> [String: Any] {
        var msg: [String: Any] = ["message_id": 42, "chat": ["id": Harness.chatID], "from": ["id": Harness.userID]]
        switch c.kind {
        case "photo": msg["photo"] = [["file_id": "S", "file_size": 5, "width": 90, "height": 90],
                                      ["file_id": "L", "file_size": 9, "width": 800, "height": 600]]
        case "voice": msg["voice"] = ["file_id": "V", "file_size": 9]
        default: msg["document"] = ["file_id": "D", "file_size": 9, "file_name": "보고서.pdf"]
        }
        if let cap = c.caption { msg["caption"] = cap }
        return ["update_id": 1, "message": msg]
    }

    static let expectedName = ["photo": "photo-42.jpg", "voice": "voice-42.m4a", "document": "보고서.pdf"]

    func testAttachmentMatrix() async throws {
        var cases: [Case] = []
        for kind in ["photo", "voice", "document"] {
            for caption in [nil, "테스트 캡션"] as [String?] {
                for err in [0, 25] { cases.append(Case(kind: kind, caption: caption, fileError: err)) }
            }
        }
        for c in cases {
            let label = "\(c.kind) caption=\(c.caption != nil) error=\(c.fileError)"
            let h = try Harness.make()
            h.sender.fileEchoError = c.fileError
            h.sender.echoError = 0
            // 실측: 캡션은 text 를 비우고 attributedBody 에 NFD 로 적힌다
            h.sender.echoAsAttributedBody = true
            h.sender.echoTextTransform = { $0.decomposedStringWithCanonicalMapping }
            try await h.relay.start()
            MockTelegram.enqueue([Self.update(c)])
            await h.relay.tick()
            await h.relay.tick()

            // 순서: 파일이 먼저, 캡션 글이 뒤(chat.db 에도 첨부 행 → 글 행 순서로 두 행이 생긴다)
            XCTAssertEqual(h.sender.sent.map(\.kind), c.caption == nil ? ["file"] : ["file", "text"], label)
            let file = h.sender.sent[0].payload
            XCTAssertEqual(file, h.workDir.appendingPathComponent("outbox/42/\(Self.expectedName[c.kind]!)").path, label)
            XCTAssertEqual(h.sender.sentFileModes.first, 0o700, label)   // 메시지별 폴더는 0700
            if let cap = c.caption { XCTAssertEqual(h.sender.sent[1].payload, cap, label) }

            let statuses = try h.state.outbox(tgMessageID: 42).map(\.status)
            let fileStatus: OutboxStatus = c.fileError == 0 ? .confirmed : .failed
            XCTAssertEqual(statuses, c.caption == nil ? [fileStatus] : [fileStatus, .confirmed], label)

            // 자기 메아리는 텔레그램에 다시 올리지 않는다(사진·음성·파일 업로드 0건)
            for m in ["sendPhoto", "sendVoice", "sendAudio", "sendDocument", "sendVideo"] {
                XCTAssertTrue(MockTelegram.calls(m).isEmpty, "\(label) \(m)")
            }
            let notices = MockTelegram.calls("sendMessage").compactMap { $0.json["text"] as? String }
            if c.fileError == 0 {
                XCTAssertTrue(notices.isEmpty, "\(label) 성공은 알리지 않는다: \(notices)")
            } else {
                XCTAssertEqual(notices.count, 1, label)
                XCTAssertTrue(notices[0].contains("error=25") && notices[0].contains("첨부"), "\(label): \(notices[0])")
                let reply = MockTelegram.calls("sendMessage").last?.json["reply_parameters"] as? [String: Any]
                XCTAssertEqual(reply?["message_id"] as? Int64, 42, label)
            }
        }
    }

    // MARK: - 답글·반응 실측 모양

    /// 실측: 상대가 첨부 행에 답하면 thread_originator_part="0:0:1", 캡션 글 행에 답하면 "0:0:<글 길이>".
    /// 둘 다 같은 텔레그램 글(사진+캡션)에 답글로 이어진다.
    func testCounterpartRepliesToPhotoAndCaptionThreadOnTelegram() async throws {
        let h = try Harness.make()
        h.sender.echoAsAttributedBody = true
        h.sender.echoTextTransform = { $0.decomposedStringWithCanonicalMapping }
        try await h.relay.start()
        MockTelegram.enqueue([Self.update(Case(kind: "photo", caption: "테스트 캡션", fileError: 0))])
        await h.relay.tick()
        let rows = try h.fixture.db.query("SELECT guid FROM message WHERE is_from_me = 1 ORDER BY ROWID") { $0.text(0)! }
        XCTAssertEqual(rows.count, 2)
        try h.fixture.insert(text: "사진 답", threadOriginator: rows[0], threadPart: "0:0:1")
        try h.fixture.insert(text: "글 답", threadOriginator: rows[1], threadPart: "0:0:6")
        await h.relay.tick()
        let replies = MockTelegram.calls("sendMessage").suffix(2).map { ($0.json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64 }
        XCTAssertEqual(replies, [42, 42])
    }

    /// 실측: 상대의 반응 행은 text 가 비어 있지 않고(예: `Loved “…”`) associated_message_guid 가 `p:0/<36자 GUID>`,
    /// 기본 반응(2000~2005)은 associated_message_emoji 가 NULL 이다. 글로 중계하지 않고 반응으로 단다.
    func testCounterpartReactionRowWithTextBecomesReactionOnly() async throws {
        let h = try Harness.make()
        h.sender.echoAsAttributedBody = true
        try await h.relay.start()
        MockTelegram.enqueue([Self.update(Case(kind: "photo", caption: nil, fileError: 0))])
        await h.relay.tick()
        let fileGuid = try h.fixture.db.query("SELECT guid FROM message WHERE is_from_me = 1") { $0.text(0)! }[0]
        let before = MockTelegram.calls("sendMessage").count
        try h.fixture.insert(text: "Loved an image", assocType: 2000, assocGuid: "p:0/\(fileGuid)")
        await h.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage").count, before)   // 글로 보내지 않음
        let r = try XCTUnwrap(MockTelegram.calls("setMessageReaction").last)
        XCTAssertEqual(r.json["message_id"] as? Int64, 42)
    }

    // MARK: - 정리 타이밍

    func testCleanupWaitsForResultAndAge() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        MockTelegram.enqueue([Self.update(Case(kind: "photo", caption: nil, fileError: 0))])
        await h.relay.tick()
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])
        let outbox = h.workDir.appendingPathComponent("outbox")
        let msgDir = outbox.appendingPathComponent("42")
        let diagDir = outbox.appendingPathComponent(OutboxStaging.diagPrefix + "1")
        let other = outbox.appendingPathComponent("keep-me")
        for d in [diagDir, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        h.relay.cleanupOutboxFiles()                     // 확정됐어도 1시간 전엔 지우지 않는다
        XCTAssertTrue(FileManager.default.fileExists(atPath: msgDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagDir.path))

        let old = Date().addingTimeInterval(-3700)
        for d in [msgDir, diagDir, other] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: d.path)
        }
        h.relay.cleanupOutboxFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: msgDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))   // 모르는 폴더는 건드리지 않는다
    }
}
