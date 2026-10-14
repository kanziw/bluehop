import Foundation
import XCTest
@testable import BluehopCore

func mapping(_ id: String, guid: String = "any;-;+821011112222", handle: String = "+821011112222",
             chat: Int64 = 555, user: Int64 = 777, bot: Int64? = nil, account: String? = nil,
             enabled: Bool = true) -> MappingConfig {
    MappingConfig(id: id, enabled: enabled,
                  telegram: MappingConfig.Telegram(chatId: chat, allowedUserId: user, botId: bot, botUsername: bot.map { "bot\($0)_bot" },
                                                   tokenSource: "keychain", tokenAccount: account),
                  imessage: RelayConfig.IMessage(chatGuid: guid, handle: handle))
}

func writePrivate(_ s: String, in dir: URL, name: String = "config.json") -> String {
    let p = dir.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: p, contents: Data(s.utf8), attributes: [.posixPermissions: 0o600])
    return p
}

let legacyJSON = """
    {"telegram":{"chatId":555,"allowedUserId":777,"tokenSource":"keychain","tokenFile":null},
     "imessage":{"chatGuid":"any;-;+821011112222","handle":"+821011112222"},
     "relay":{"mirrorOwnMessages":false,"telegramReactionMode":"text","outboxDirectory":null}}
    """

/// 설정: 0.4.x 단일 설정 읽기·옮기기, 매핑 목록 규칙.
final class MultiMappingConfigTests: XCTestCase {
    func testLegacyConfigIsReadAsDefaultMappingWithOldKeychainAccount() throws {
        let dir = makeTempDir()
        let p = writePrivate(legacyJSON, in: dir)
        let loaded = try ConfigLoader.loadFile(path: p)
        XCTAssertTrue(loaded.legacy)
        XCTAssertEqual(loaded.config.mappings.count, 1)
        let m = loaded.config.mappings[0]
        XCTAssertEqual(m.id, "default")
        XCTAssertTrue(m.enabled)
        XCTAssertEqual(m.keychainAccount, "telegram-bot-token")
        XCTAssertEqual(m.telegram.chatId, 555)
        XCTAssertFalse(m.mirrorOwnMessages)
        XCTAssertEqual(m.reactionMode, .text)
        // 읽기만으로는 파일을 바꾸지 않는다
        XCTAssertEqual(try String(contentsOfFile: p, encoding: .utf8), legacyJSON)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ConfigLoader.legacyBackupPath(p)))
    }

    func testFirstWriteMigratesToVersion2AndKeepsOneBackup() throws {
        let dir = makeTempDir()
        let p = writePrivate(legacyJSON, in: dir)
        var cfg = try ConfigLoader.load(path: p)
        cfg.mappings.append(mapping("work", guid: "any;-;+821033334444", handle: "+821033334444", bot: 222))
        let backup = try ConfigLoader.save(cfg, path: p)
        XCTAssertEqual(backup, ConfigLoader.legacyBackupPath(p))
        XCTAssertEqual(try String(contentsOfFile: backup!, encoding: .utf8), legacyJSON)
        let mode = try FileManager.default.attributesOfItem(atPath: backup!)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let again = try ConfigLoader.loadFile(path: p)
        XCTAssertFalse(again.legacy)
        XCTAssertEqual(again.config.version, 2)
        XCTAssertEqual(again.config.mappings.map(\.id), ["default", "work"])
        XCTAssertEqual(again.config.mapping("default")?.keychainAccount, "telegram-bot-token")
        XCTAssertEqual(again.config.mapping("work")?.keychainAccount, "bot-token:work")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: p)[.posixPermissions] as? Int, 0o600)

        // 두 번째 쓰기는 백업을 만들지 않는다(원본 0.4.x 백업 유지)
        var c2 = again.config
        c2.mappings[1].enabled = false
        XCTAssertNil(try ConfigLoader.save(c2, path: p))
        XCTAssertEqual(try String(contentsOfFile: backup!, encoding: .utf8), legacyJSON)
        XCTAssertEqual(try ConfigLoader.load(path: p).mapping("work")?.enabled, false)
        // 임시 파일이 남지 않는다
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["config.json", "config.json.v1-backup"])
    }

    func testVersion2RoundTripAndEnabledDefaultsToTrue() throws {
        let json = """
            {"version":2,"mappings":[{"id":"family","telegram":{"chatId":555,"allowedUserId":777,"tokenSource":"keychain"},
              "imessage":{"chatGuid":"any;-;+821011112222","handle":"+821011112222"}}]}
            """
        let (cfg, legacy) = try ConfigLoader.decode(Data(json.utf8))
        XCTAssertFalse(legacy)
        XCTAssertTrue(cfg.mappings[0].enabled)
        XCTAssertEqual(cfg.mappings[0].keychainAccount, "bot-token:family")
        let (back, _) = try ConfigLoader.decode(try ConfigLoader.encode(cfg))
        XCTAssertEqual(back, cfg)
    }

    func testUnknownVersionAndMissingMappingsAreRejected() {
        XCTAssertThrowsError(try MappingRules.validate(BluehopConfig(version: 3, mappings: [])))
        XCTAssertThrowsError(try ConfigLoader.decode(Data("{\"version\":2}".utf8)))
        XCTAssertThrowsError(try ConfigLoader.decode(Data("[1]".utf8)))
    }

    func testGuardRails() {
        let a = mapping("a", bot: 111)
        // 같은 id
        XCTAssertFalse(MappingRules.conflicts([a, mapping("a", guid: "any;-;+821033334444", handle: "+821033334444", bot: 222)]).isEmpty)
        // 같은 iMessage 대화(guid)
        XCTAssertTrue(MappingRules.conflicts([a, mapping("b", bot: 222)]).first?.contains("iMessage 대화") == true)
        // 다른 guid 라도 같은 상대 handle
        let sameHandle = mapping("b", guid: "iMessage;-;+821011112222", handle: "(+82) 10-1111-2222", bot: 222)
        XCTAssertTrue(MappingRules.conflicts([a, sameHandle]).first?.contains("handle") == true)
        // 같은 봇 id
        let sameBot = mapping("b", guid: "any;-;+821033334444", handle: "+821033334444", bot: 111)
        let msg = MappingRules.conflicts([a, sameBot])
        XCTAssertEqual(msg.count, 1)
        XCTAssertTrue(msg[0].contains("봇(id 111)") && msg[0].contains("쌍도 같다"))
        // 같은 Keychain 계정
        let sameAccount = mapping("b", guid: "any;-;+821033334444", handle: "+821033334444", bot: 222, account: "bot-token:a")
        XCTAssertTrue(MappingRules.conflicts([a, sameAccount]).first?.contains("Keychain") == true)
        // 서로 다른 대화·봇은 통과
        XCTAssertEqual(MappingRules.conflicts([a, mapping("b", guid: "any;-;+821033334444", handle: "+821033334444", bot: 222)]), [])
        // 저장도 막는다
        let dir = makeTempDir()
        XCTAssertThrowsError(try ConfigLoader.save(BluehopConfig(mappings: [a, sameBot]), path: dir.appendingPathComponent("c.json").path)) { e in
            guard case ConfigError.conflict = e else { return XCTFail("\(e)") }
            XCTAssertEqual(CLIError.from(e).code, .conflict)
        }
    }

    func testMappingIDRulesAndSlug() {
        XCTAssertTrue(MappingRules.isValidID("family"))
        XCTAssertTrue(MappingRules.isValidID("a1-b2"))
        XCTAssertFalse(MappingRules.isValidID("1abc"))       // 숫자로 시작하면 0.4.x 첨부 폴더와 헷갈린다
        XCTAssertFalse(MappingRules.isValidID("Family"))
        XCTAssertFalse(MappingRules.isValidID("a/b"))
        XCTAssertFalse(MappingRules.isValidID(String(repeating: "a", count: 33)))
        XCTAssertEqual(MappingRules.slug("Family_Relay_bot"), "family-relay")
        XCTAssertEqual(MappingRules.slug("mom_bot"), "mom")
        XCTAssertEqual(MappingRules.slug("42bot"), "chat-42")
        XCTAssertEqual(MappingRules.slug("___"), "chat")
        XCTAssertEqual(MappingRules.uniqueID("mom", taken: ["mom", "mom-2"]), "mom-3")
    }

    func testPerMappingOptionsUseOwnStagingFolder() {
        let a = MappingOptions.make(mapping("family"))
        let b = MappingOptions.make(mapping("work"))
        XCTAssertEqual(a.outboxDir.lastPathComponent, "family")
        XCTAssertEqual(b.outboxDir.lastPathComponent, "work")
        XCTAssertNotEqual(a.tmpDir, b.tmpDir)
        XCTAssertTrue(MessagesSandbox.canRead(a.outboxDir.path))
        XCTAssertNil(a.legacyOutboxRoot)
        // 옮겨 온 default 만 0.4.x 가 남긴 폴더를 정리한다
        XCTAssertEqual(MappingOptions.make(mapping("default")).legacyOutboxRoot?.path, Paths.defaultOutboxDir)
    }

    func testLoadTokenUsesPerMappingSourceAndBotID() throws {
        let dir = makeTempDir()
        let tok = writePrivate("424242:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n", in: dir, name: "token")
        var m = mapping("file")
        m.telegram.tokenSource = "file"
        m.telegram.tokenFile = tok
        let t = try ConfigLoader.loadToken(m)
        XCTAssertEqual(ConfigLoader.botID(ofToken: t), 424242)
        XCTAssertNil(ConfigLoader.botID(ofToken: "abc"))
    }

    func testPackagedExampleIsVersion2Shape() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repo.appendingPathComponent("packaging/config.example.json"))
        let (cfg, legacy) = try ConfigLoader.decode(data)
        XCTAssertFalse(legacy)
        XCTAssertEqual(cfg.mappings.map(\.id), ["family"])
        XCTAssertEqual(cfg.mappings[0].keychainAccount, "bot-token:family")
        XCTAssertThrowsError(try MappingRules.validate(cfg))   // 자리표시 값(0)은 그대로 쓸 수 없다
    }
}
