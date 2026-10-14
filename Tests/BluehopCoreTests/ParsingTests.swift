import Foundation
import XCTest
@testable import BluehopCore

final class AttributedBodyTests: XCTestCase {
    func testShortText() {
        XCTAssertEqual(AttributedBody.extractText(AttributedBody.encodeForTesting("안녕 👋")), "안녕 👋")
    }

    func testLongTextUsesTwoByteLength() {
        let long = String(repeating: "가나다라마", count: 40)  // UTF-8 600 bytes → 0x81 길이
        let blob = AttributedBody.encodeForTesting(long)
        XCTAssertTrue([UInt8](blob).contains(0x81))
        XCTAssertEqual(AttributedBody.extractText(blob), long)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(AttributedBody.extractText(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(AttributedBody.extractText(Data("NSString".utf8)))
    }

    func testTruncatedLengthIsRejected() {
        var b = [UInt8](AttributedBody.encodeForTesting("hello world"))
        b.removeLast(12)  // 본문 일부와 꼬리를 잘라 길이가 넘치게
        XCTAssertNil(AttributedBody.extractText(Data(b)))
    }

    func testCleanRemovesObjectReplacement() {
        XCTAssertEqual(AttributedBody.clean("\u{FFFC}사진 \u{FFFC}"), "사진")
        XCTAssertEqual(AttributedBody.clean(nil), "")
    }
}

final class TapbackTests: XCTestCase {
    func testClassicTypes() {
        let t = Tapback.parse(type: 2000, associatedGuid: "p:0/ABC", emoji: nil)
        XCTAssertEqual(t, Tapback(action: .add, emoji: "❤️", targetGuid: "ABC", targetPart: 0))
        XCTAssertEqual(Tapback.parse(type: 2004, associatedGuid: "bp:XYZ", emoji: nil)?.emoji, "‼️")
        XCTAssertEqual(Tapback.parse(type: 3001, associatedGuid: "p:1/ABC", emoji: nil)?.action, .remove)
        XCTAssertEqual(Tapback.parse(type: 3001, associatedGuid: "p:1/ABC", emoji: nil)?.targetPart, 1)
    }

    func testCustomEmojiReaction() {
        let t = Tapback.parse(type: 2006, associatedGuid: "p:0/ABC", emoji: "🔥")
        XCTAssertEqual(t?.emoji, "🔥")
        XCTAssertNil(Tapback.parse(type: 2007, associatedGuid: "p:0/ABC", emoji: nil)?.emoji)  // 스티커
    }

    func testInvalid() {
        XCTAssertNil(Tapback.parse(type: 0, associatedGuid: "p:0/ABC", emoji: nil))
        XCTAssertNil(Tapback.parse(type: 2000, associatedGuid: nil, emoji: nil))
        XCTAssertNil(Tapback.parse(type: 2000, associatedGuid: "p:0/", emoji: nil))
    }

    func testTelegramMapping() {
        XCTAssertEqual(TelegramReactions.telegramEmoji(for: "❤️"), "❤")
        XCTAssertEqual(TelegramReactions.telegramEmoji(for: "👍"), "👍")
        XCTAssertEqual(TelegramReactions.telegramEmoji(for: "😂"), "🤣")
        XCTAssertEqual(TelegramReactions.telegramEmoji(for: "❓"), "🤔")
        XCTAssertEqual(TelegramReactions.telegramEmoji(for: "🔥"), "🔥")
        XCTAssertNil(TelegramReactions.telegramEmoji(for: "‼️"))
        XCTAssertNil(TelegramReactions.telegramEmoji(for: "🦖"))
    }
}

final class ChatDBTests: XCTestCase {
    func testResolveOneToOne() throws {
        let fx = try FixtureChatDB()
        let chat = try fx.reader().resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: "+82 10-1111-2222")
        XCTAssertEqual(chat.rowid, 1)
    }

    func testRejectGroupAndMismatch() throws {
        let fx = try FixtureChatDB()
        let r = try fx.reader()
        XCTAssertThrowsError(try r.resolveChat(guid: "any;+;chat123", expectedHandle: "+821033334444"))
        XCTAssertThrowsError(try r.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: "+821033334444"))
        XCTAssertThrowsError(try r.resolveChat(guid: "any;-;nobody", expectedHandle: "nobody"))
    }

    func testQueriesAreScopedToChat() throws {
        let fx = try FixtureChatDB()
        try fx.insert(chat: 1, text: "mine")
        try fx.insert(chat: 2, text: "other-person")
        try fx.insert(chat: 3, text: "group")
        let r = try fx.reader()
        let chat = try r.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        let msgs = try r.messages(after: 0, chat: chat)
        XCTAssertEqual(msgs.map(\.text), ["mine"])
        XCTAssertNil(try r.message(guid: "GUID-2", chat: chat))  // 다른 대화의 guid 는 못 찾는다
    }

    func testTextFallsBackToAttributedBody() throws {
        let fx = try FixtureChatDB()
        try fx.insert(text: nil, blobText: "본문은 BLOB 에만")
        try fx.insert(text: "", blobText: "빈 text")
        let r = try fx.reader()
        let chat = try r.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        XCTAssertEqual(try r.messages(after: 0, chat: chat).map(\.text), ["본문은 BLOB 에만", "빈 text"])
    }

    func testAttachmentPathSafety() throws {
        let fx = try FixtureChatDB()
        let inside = fx.makeAttachmentFile("a.jpg")
        let outsideFile = fx.dir.appendingPathComponent("secret.txt")
        try "x".write(to: outsideFile, atomically: true, encoding: .utf8)
        // 첨부 폴더 안의 심볼릭 링크가 밖을 가리키는 경우
        let link = fx.attachmentsRoot.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        try fx.insert(text: "x", attachments: [("a.jpg", inside, "image/jpeg"), ("secret.txt", outsideFile.path, nil),
                                               ("link.txt", link.path, nil), ("missing.jpg", fx.attachmentsRoot.path + "/nope.jpg", nil)])
        let r = try fx.reader()
        let chat = try r.resolveChat(guid: FixtureChatDB.chatGuid, expectedHandle: FixtureChatDB.handle)
        let atts = try r.messages(after: 0, chat: chat)[0].attachments
        XCTAssertNotNil(atts[0].path)
        XCTAssertNil(atts[1].path)
        XCTAssertNil(atts[2].path)
        XCTAssertNil(atts[3].path)
    }

    func testReadOnlyConnectionCannotWrite() throws {
        let fx = try FixtureChatDB()
        let ro = try SQLiteDB(path: fx.path, mode: .readOnly)
        XCTAssertThrowsError(try ro.run("INSERT INTO handle(id) VALUES('x')"))
    }
}

final class ClassifierTests: XCTestCase {
    func testPlans() {
        XCTAssertEqual(AttachmentClassifier.plan(filename: "Audio Message.caf", mimeType: nil, uti: "com.apple.coreaudio-format", isAudioMessage: true, bytes: 10), .voice(convert: true))
        XCTAssertEqual(AttachmentClassifier.plan(filename: "IMG_1.HEIC", mimeType: "image/heic", uti: nil, isAudioMessage: false, bytes: 10), .photo(convertToJPEG: true))
        XCTAssertEqual(AttachmentClassifier.plan(filename: "a.jpg", mimeType: "image/jpeg", uti: nil, isAudioMessage: false, bytes: 10), .photo(convertToJPEG: false))
        XCTAssertEqual(AttachmentClassifier.plan(filename: "a.jpg", mimeType: "image/jpeg", uti: nil, isAudioMessage: false, bytes: 11_000_000), .document)
        XCTAssertEqual(AttachmentClassifier.plan(filename: "song.mp3", mimeType: "audio/mpeg", uti: nil, isAudioMessage: false, bytes: 10), .audio(convert: false))
        XCTAssertEqual(AttachmentClassifier.plan(filename: "v.mov", mimeType: "video/quicktime", uti: nil, isAudioMessage: false, bytes: 10), .video)
        XCTAssertEqual(AttachmentClassifier.plan(filename: "x.pdf", mimeType: "application/pdf", uti: nil, isAudioMessage: false, bytes: 10), .document)
    }

    func testSafeFilename() {
        XCTAssertEqual(AttachmentClassifier.safeFilename("../../etc/passwd", fallback: "f"), "_.._.._etc_passwd")
        XCTAssertEqual(AttachmentClassifier.safeFilename(".hidden", fallback: "f"), "_.hidden")
        XCTAssertEqual(AttachmentClassifier.safeFilename(nil, fallback: "f"), "f")
        XCTAssertEqual(AttachmentClassifier.safeFilename("보고서.pdf", fallback: "f"), "보고서.pdf")
    }

    func testQuotePrefix() {
        XCTAssertEqual(Relay.quotePrefix("짧은 글"), "↪ \"짧은 글\"")
        XCTAssertEqual(Relay.quotePrefix("줄\n바꿈"), "↪ \"줄 바꿈\"")
        XCTAssertEqual(Relay.quotePrefix(String(repeating: "가", count: 40)), "↪ \"" + String(repeating: "가", count: 30) + "…\"")
        XCTAssertEqual(Relay.quotePrefix(""), "↪ (첨부)")
    }
}

final class ConfigTests: XCTestCase {
    func sampleJSON(guid: String = "any;-;+821011112222") -> String {
        """
        {"telegram":{"chatId":555,"allowedUserId":777,"tokenSource":"file","tokenFile":"TOKENPATH"},
         "imessage":{"chatGuid":"\(guid)","handle":"+821011112222"}}
        """
    }

    func write(_ s: String, mode: Int, in dir: URL, name: String) -> String {
        let p = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: p, contents: s.data(using: .utf8), attributes: [.posixPermissions: mode])
        return p
    }

    func testLoadsPrivateConfigAndToken() throws {
        let dir = makeTempDir()
        let tokenPath = write("123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n", mode: 0o600, in: dir, name: "token")
        let p = write(sampleJSON().replacingOccurrences(of: "TOKENPATH", with: tokenPath), mode: 0o600, in: dir, name: "config.json")
        let cfg = try ConfigLoader.load(path: p)
        XCTAssertEqual(cfg.telegram.chatId, 555)
        XCTAssertTrue(cfg.mirrorOwnMessages)
        XCTAssertEqual(cfg.reactionMode, .ignore)
        XCTAssertEqual(try ConfigLoader.loadToken(cfg), "123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
    }

    func testRejectsLoosePermissions() throws {
        let dir = makeTempDir()
        let p = write(sampleJSON(), mode: 0o644, in: dir, name: "config.json")
        XCTAssertThrowsError(try ConfigLoader.load(path: p)) { e in
            guard case ConfigError.insecurePermissions = e else { return XCTFail("\(e)") }
        }
        let tokenPath = write("123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", mode: 0o644, in: dir, name: "token")
        let p2 = write(sampleJSON().replacingOccurrences(of: "TOKENPATH", with: tokenPath), mode: 0o600, in: dir, name: "c2.json")
        let cfg = try ConfigLoader.load(path: p2)
        XCTAssertThrowsError(try ConfigLoader.loadToken(cfg))
    }

    func testRejectsGroupChatGuidAndBadToken() throws {
        let dir = makeTempDir()
        let p = write(sampleJSON(guid: "any;+;chat123"), mode: 0o600, in: dir, name: "config.json")
        XCTAssertThrowsError(try ConfigLoader.load(path: p))
        let tokenPath = write("123:abc/../x", mode: 0o600, in: dir, name: "token")
        let p2 = write(sampleJSON().replacingOccurrences(of: "TOKENPATH", with: tokenPath), mode: 0o600, in: dir, name: "c2.json")
        XCTAssertThrowsError(try ConfigLoader.loadToken(try ConfigLoader.load(path: p2)))
    }
}

final class AppleScriptTests: XCTestCase {
    /// 고정 스크립트가 문법적으로 맞는지 컴파일만 해 본다(실행·발송 없음).
    func testScriptCompiles() throws {
        let out = makeTempDir().appendingPathComponent("s.scpt").path
        let r = try ProcessRunner.run("/usr/bin/osacompile", ["-o", out, "-e", AppleScriptSender.script], timeout: 30)
        XCTAssertEqual(r.status, 0, r.stderr)
    }

    func testValuesGoThroughArgvNotScript() {
        // 스크립트에 본문을 끼워 넣는 자리가 없어야 한다.
        XCTAssertFalse(AppleScriptSender.script.contains("\\("))
        XCTAssertTrue(AppleScriptSender.script.contains("item 3 of argv"))
    }
}

final class SafetyUnitTests: XCTestCase {
    func testRateLimiterWaits() async {
        let clock = FakeClock()
        let rl = RateLimiter(perMinute: 2, clock: clock)
        await rl.acquire(); await rl.acquire()
        XCTAssertEqual(clock.slept, 0)
        await rl.acquire()
        XCTAssertEqual(clock.slept, 30, accuracy: 0.01)
    }

    func testBreakerWindow() {
        let clock = FakeClock()
        let b = SafetyBreaker(limit: 2, windowSeconds: 60, clock: clock)
        XCTAssertTrue(b.allow()); XCTAssertTrue(b.allow()); XCTAssertFalse(b.allow())
        clock.now += 61
        XCTAssertTrue(b.allow())
    }
}

final class TelegramClientTests: XCTestCase {
    func testNetworkErrorDoesNotLeakToken() async {
        MockTelegram.reset()
        MockTelegram.networkDown = true
        let tg = TelegramClient(token: "123456:SECRETSECRETSECRETSECRET", chatID: 1,
                                base: URL(string: "https://mock.telegram.test")!, session: MockTelegram.session())
        do {
            _ = try await tg.sendMessage("x")
            XCTFail("should throw")
        } catch {
            XCTAssertFalse("\(error)".contains("SECRET"))
            XCTAssertFalse(String(describing: error).contains("mock.telegram.test"))
        }
        MockTelegram.networkDown = false
    }

    func testProductionBaseIsTelegramOnly() {
        XCTAssertEqual(TelegramClient.productionBase.host, "api.telegram.org")
        XCTAssertEqual(TelegramClient.productionBase.scheme, "https")
    }
}

final class EchoKeyTests: XCTestCase {
    func testNFDAndNFCHangulFoldToSameKey() {
        let nfc = "한국어 한 줄 글입니다"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars))
        XCTAssertEqual(EchoKey.normalize(nfd), EchoKey.normalize(nfc))
        XCTAssertEqual(EchoKey.normalize("Hi"), "Hi")
    }

    func testSmartPunctuationInvisiblesAndLineBreaksFold() {
        XCTAssertEqual(EchoKey.normalize("\u{201C}확인\u{201D} don\u{2019}t \u{2014} 음\u{2026}"), EchoKey.normalize("\"확인\" don't -- 음..."))
        XCTAssertEqual(EchoKey.normalize("\u{FEFF}가\u{200B}나\u{00A0}\u{00A0}다 \u{2028}라\u{FFFC}"), "가나 다\n라")
        XCTAssertEqual(EchoKey.normalize("a\u{0007}b\r\nc"), "ab\nc")
    }

    func testCleanComposesHangulForDisplay() {
        let nfd = "가나".decomposedStringWithCanonicalMapping
        XCTAssertEqual(Array(AttributedBody.clean(nfd).unicodeScalars), Array("가나".unicodeScalars))
    }

    func testFingerprintHasNoBody() {
        let f = EchoKey.fingerprint("비밀 본문")
        XCTAssertTrue(f.hasPrefix("len=5/h="))
        XCTAssertFalse(f.contains("비밀"))
    }
}
