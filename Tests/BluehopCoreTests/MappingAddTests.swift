import Foundation
import XCTest
@testable import BluehopCore

final class FakeTokenStore: TokenStore {
    var saved: [String: String] = [:]
    var deleted: [String] = []
    func save(token: String, account: String) throws { saved[account] = token }
    func delete(account: String) throws -> Bool {
        deleted.append(account)
        return saved.removeValue(forKey: account) != nil
    }
}

final class ScriptedInteraction: AddInteraction {
    var pickIndex: Int?
    var id: String?
    var confirm = true
    var shownItems: [ChatPicker.Item] = []
    var asked: [String] = []
    func pickChat(_ items: [ChatPicker.Item]) throws -> ChatPicker.Item {
        shownItems = items
        guard let i = pickIndex else { throw CLIError(.cancelled, "취소") }
        return items[i]
    }
    func askID(suggested: String) throws -> String { asked.append(suggested); return id ?? suggested }
    func confirmSender(_ s: DetectedSender, bot: String) throws -> Bool { confirm }
}

/// `mapping add`: 토큰 → 봇 → 대화 → 텔레그램 id → 저장. 목 텔레그램·가짜 Keychain 으로.
final class MappingAddTests: XCTestCase {
    let newToken = "333333:CCCCTESTTOKENCCCCTESTTOKEN"
    let chats = [
        ChatDB.ChatSummary(guid: "any;-;+821033334444", handle: "+821033334444", lastRowID: 9),
        ChatDB.ChatSummary(guid: "SMS;-;+821033334444", handle: "+821033334444", lastRowID: 2),
        ChatDB.ChatSummary(guid: "any;-;+821011112222", handle: "+821011112222", lastRowID: 5),
    ]

    func makeAdder(_ dir: URL, tokens: FakeTokenStore = FakeTokenStore(), interaction: AddInteraction? = nil,
                   clock: FakeClock = FakeClock(), configName: String = "config.json") -> (MappingAdder, String) {
        let path = dir.appendingPathComponent(configName).path
        let adder = MappingAdder(configPath: path, tokens: tokens,
                                 telegramFor: { TelegramClient(token: $0, chatID: 0, base: URL(string: "https://mock.telegram.test")!, session: MockTelegram.session()) },
                                 chats: { self.chats }, clock: clock, interaction: interaction, progress: { _ in })
        return (adder, path)
    }

    func privateMessage(_ updateID: Int64, chat: Int64 = 555, from: Int64 = 777, date: Int64, bot: Bool = false, type: String = "private") -> [String: Any] {
        ["update_id": updateID, "message": ["message_id": updateID, "chat": ["id": chat, "type": type],
                                            "from": ["id": from, "is_bot": bot, "first_name": "나"], "date": date, "text": "hi"]]
    }

    override func setUp() { MockTelegram.reset() }

    func testDetectorKeepsRecentPrivateHumanSendersOnly() throws {
        let decode = { (u: [String: Any]) in try JSONDecoder().decode(TGUpdate.self, from: JSONSerialization.data(withJSONObject: u)).message! }
        let msgs = try [
            decode(privateMessage(1, date: 1000)),
            decode(privateMessage(2, date: 1050)),                 // 같은 사람 → 하나로
            decode(privateMessage(3, from: 888, date: 100)),      // 오래됨
            decode(privateMessage(4, from: 999, date: 1050, bot: true)),
            decode(privateMessage(5, chat: -100, from: 666, date: 1050, type: "group")),
        ]
        let c = TelegramIDDetector.candidates(msgs, now: 1100, maxAge: 600)
        XCTAssertEqual(c, [DetectedSender(chatID: 555, userID: 777, name: "나", date: 1050)])
    }

    func testNonInteractiveAddWithFlagsWritesKeychainThenConfig() async throws {
        let dir = makeTempDir()
        let tokens = FakeTokenStore()
        let (adder, path) = makeAdder(dir, tokens: tokens)
        var req = AddRequest(token: newToken + "\n")
        req.id = "work"
        req.chat = "(+82) 10-3333-4444"   // handle(= +821033334444) → 가장 최근 대화
        req.telegramChat = 555
        req.allowedUser = 777
        let r = try await adder.run(req)
        XCTAssertEqual(r.mapping.imessage.chatGuid, "any;-;+821033334444")
        XCTAssertEqual(r.mapping.telegram.botId, 333333)
        XCTAssertEqual(r.mapping.telegram.botUsername, "bot333333_bot")
        XCTAssertEqual(tokens.saved, ["bot-token:work": newToken])
        let cfg = try ConfigLoader.load(path: path)
        XCTAssertEqual(cfg.mappings.map(\.id), ["work"])
        XCTAssertEqual(cfg.mapping("work")?.keychainAccount, "bot-token:work")
        XCTAssertEqual(MockTelegram.calls("getMe").count, 1)
        XCTAssertTrue(MockTelegram.sentMethods.allSatisfy { $0 == "getMe" })   // 아무것도 보내지 않는다
    }

    func testDetectsTelegramIDsFromRecentMessage() async throws {
        let dir = makeTempDir()
        let clock = FakeClock()
        let (adder, path) = makeAdder(dir, clock: clock)
        MockTelegram.enqueue([privateMessage(1, date: Int64(clock.now) - 30)], token: newToken)
        var req = AddRequest(token: newToken)
        req.chat = "any;-;+821011112222"
        let r = try await adder.run(req)
        XCTAssertEqual(r.mapping.telegram.chatId, 555)
        XCTAssertEqual(r.mapping.telegram.allowedUserId, 777)
        XCTAssertEqual(r.mapping.id, "bot333333")        // 봇 이름에서 만든 id
        let peek = try XCTUnwrap(MockTelegram.calls("getUpdates", token: newToken).first)
        XCTAssertNil(peek.json["offset"])                 // 확인 처리(offset)하지 않는다
        XCTAssertNotNil(try ConfigLoader.load(path: path).mapping("bot333333"))
    }

    func testTimesOutWithoutMessage() async throws {
        let (adder, _) = makeAdder(makeTempDir())
        var req = AddRequest(token: newToken)
        req.chat = "any;-;+821011112222"
        req.waitSeconds = 3
        do {
            _ = try await adder.run(req)
            XCTFail("시간 초과여야 함")
        } catch let e as CLIError {
            XCTAssertEqual(e.code, .timeout)
        }
    }

    func testSeveralSendersIsAConflict() async throws {
        let clock = FakeClock()
        let (adder, _) = makeAdder(makeTempDir(), clock: clock)
        MockTelegram.enqueue([privateMessage(1, date: Int64(clock.now)), privateMessage(2, chat: 556, from: 778, date: Int64(clock.now))], token: newToken)
        var req = AddRequest(token: newToken)
        req.chat = "any;-;+821011112222"
        do { _ = try await adder.run(req); XCTFail() } catch let e as CLIError { XCTAssertEqual(e.code, .conflict) }
    }

    func testInteractivePickerSkipsMappedChatsAndAsksID() async throws {
        let dir = makeTempDir()
        let existing = BluehopConfig(mappings: [mapping("family", bot: 111)])
        try ConfigLoader.save(existing, path: dir.appendingPathComponent("config.json").path)
        let ui = ScriptedInteraction()
        ui.pickIndex = 0
        ui.id = "work"
        let (adder, path) = makeAdder(dir, interaction: ui)
        var req = AddRequest(token: newToken)
        req.telegramChat = 555
        req.allowedUser = 777
        let r = try await adder.run(req)
        XCTAssertEqual(ui.shownItems.map(\.mappedTo), [nil, nil, "family"])
        XCTAssertEqual(ui.asked, ["bot333333"])
        XCTAssertEqual(r.mapping.id, "work")
        XCTAssertEqual(try ConfigLoader.load(path: path).mappings.map(\.id), ["family", "work"])
    }

    func testRefusesSameBotSameChatAndBadIDs() async throws {
        let dir = makeTempDir()
        try ConfigLoader.save(BluehopConfig(mappings: [mapping("family", bot: 333333)]), path: dir.appendingPathComponent("config.json").path)
        let tokens = FakeTokenStore()
        let (adder, _) = makeAdder(dir, tokens: tokens)
        func attempt(_ edit: (inout AddRequest) -> Void) async -> ExitCode? {
            var req = AddRequest(token: newToken)
            req.telegramChat = 555
            req.allowedUser = 777
            req.chat = "any;-;+821033334444"
            edit(&req)
            do { _ = try await adder.run(req); return nil } catch let e as CLIError { return e.code } catch { return .failure }
        }
        let sameBot = await attempt { _ in }
        XCTAssertEqual(sameBot, .conflict)
        MockTelegram.reset()
        let other = "444444:DDDDTESTTOKENDDDDTESTTOKEN"
        let sameChat = await attempt { $0.token = other; $0.chat = "+821011112222" }
        XCTAssertEqual(sameChat, .conflict)
        let group = await attempt { $0.token = other; $0.chat = "any;+;chat123" }
        XCTAssertEqual(group, .usage)
        let missing = await attempt { $0.token = other; $0.chat = "any;-;+15555550123" }
        XCTAssertEqual(missing, .notFound)
        let badID = await attempt { $0.token = other; $0.id = "Bad ID" }
        XCTAssertEqual(badID, .usage)
        let dupID = await attempt { $0.token = other; $0.id = "family" }
        XCTAssertEqual(dupID, .conflict)
        let halfIDs = await attempt { $0.token = other; $0.allowedUser = nil }
        XCTAssertEqual(halfIDs, .usage)
        let badToken = await attempt { $0.token = "not-a-token" }
        XCTAssertEqual(badToken, .failure)
        XCTAssertTrue(tokens.saved.isEmpty)
    }

    func testNoChatWithoutTerminalIsUsageError() async throws {
        let (adder, _) = makeAdder(makeTempDir())
        var req = AddRequest(token: newToken)
        req.telegramChat = 555
        req.allowedUser = 777
        do { _ = try await adder.run(req); XCTFail() } catch let e as CLIError { XCTAssertEqual(e.code, .usage) }
    }

    func testDryRunWritesNothing() async throws {
        let dir = makeTempDir()
        let tokens = FakeTokenStore()
        let (adder, path) = makeAdder(dir, tokens: tokens)
        var req = AddRequest(token: newToken)
        req.chat = "any;-;+821011112222"
        req.telegramChat = 555
        req.allowedUser = 777
        req.dryRun = true
        let r = try await adder.run(req)
        XCTAssertTrue(r.dryRun)
        XCTAssertTrue(tokens.saved.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testAddMigratesLegacyConfigWithBackup() async throws {
        let dir = makeTempDir()
        let path = writePrivate(legacyJSON, in: dir)
        let (adder, _) = makeAdder(dir)
        var req = AddRequest(token: newToken)
        req.chat = "any;-;+821033334444"
        req.telegramChat = 555
        req.allowedUser = 777
        req.id = "work"
        let r = try await adder.run(req)
        XCTAssertEqual(r.configBackup, ConfigLoader.legacyBackupPath(path))
        let loaded = try ConfigLoader.loadFile(path: path)
        XCTAssertFalse(loaded.legacy)
        XCTAssertEqual(loaded.config.mappings.map(\.id), ["default", "work"])
        XCTAssertEqual(loaded.config.mapping("default")?.keychainAccount, "telegram-bot-token")
    }

    func testTokenIsRemovedWhenConfigCannotBeWritten() async throws {
        let dir = makeTempDir()
        // 설정 폴더 권한이 넓으면 저장이 거부된다 → 방금 넣은 토큰을 지운다
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let tokens = FakeTokenStore()
        let (adder, _) = makeAdder(dir, tokens: tokens)
        var req = AddRequest(token: newToken)
        req.chat = "any;-;+821011112222"
        req.telegramChat = 555
        req.allowedUser = 777
        req.id = "x"
        do { _ = try await adder.run(req); XCTFail() } catch {}
        XCTAssertEqual(tokens.deleted, ["bot-token:x"])
        XCTAssertTrue(tokens.saved.isEmpty)
    }

    func testTokenFileModeKeepsKeychainUntouched() async throws {
        let dir = makeTempDir()
        let tokens = FakeTokenStore()
        let (adder, path) = makeAdder(dir, tokens: tokens)
        let tokenPath = writePrivate(newToken, in: dir, name: "tok")
        var req = AddRequest(token: newToken)
        req.tokenFile = tokenPath
        req.chat = "any;-;+821011112222"
        req.telegramChat = 555
        req.allowedUser = 777
        req.id = "filebot"
        _ = try await adder.run(req)
        XCTAssertTrue(tokens.saved.isEmpty)
        let m = try XCTUnwrap(ConfigLoader.load(path: path).mapping("filebot"))
        XCTAssertEqual(m.telegram.tokenSource, "file")
        XCTAssertEqual(try ConfigLoader.loadToken(m), newToken)
    }
}
