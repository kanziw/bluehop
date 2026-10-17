import Foundation
import XCTest
@testable import BluehopCore

/// `bluehop notify` 가 쓰는 `Notifier.send`: 가짜 HTTP(`MockTelegram`)로 각 매핑이 자기 토큰으로
/// `sendMessage` 를 정확히 한 번, 정확한 chat_id·text 로 부르는지, 하나가 실패해도 나머지는 계속 보내는지 본다.
final class NotifyTests: XCTestCase {
    override func setUp() { MockTelegram.reset() }

    func tg(_ token: String, chatID: Int64) -> TelegramClient {
        TelegramClient(token: token, chatID: chatID, base: URL(string: "https://mock.telegram.test")!, session: MockTelegram.session())
    }

    func testSendsToEachMappingWithItsOwnTokenAndChatID() async throws {
        let a = mapping("a", chat: 111, bot: 1)
        let b = mapping("b", chat: 222, bot: 2)
        let tokens = ["a": "1:tokenA", "b": "2:tokenB"]
        let results = await Notifier.send([a, b], text: "점검 필요",
                                          loadToken: { tokens[$0.id]! },
                                          telegramFor: { token, chatID in self.tg(token, chatID: chatID) })

        XCTAssertEqual(results.map(\.mappingID), ["a", "b"])
        XCTAssertTrue(results.allSatisfy(\.ok))
        XCTAssertTrue(results.allSatisfy { $0.messageID != nil })
        XCTAssertTrue(results.allSatisfy { $0.code == ErrorCodes.ok })

        let sentA = try XCTUnwrap(MockTelegram.calls("sendMessage", token: "1:tokenA").first)
        XCTAssertEqual(sentA.json["chat_id"] as? Int64, 111)
        XCTAssertEqual(sentA.json["text"] as? String, "점검 필요")

        let sentB = try XCTUnwrap(MockTelegram.calls("sendMessage", token: "2:tokenB").first)
        XCTAssertEqual(sentB.json["chat_id"] as? Int64, 222)
        XCTAssertEqual(sentB.json["text"] as? String, "점검 필요")
    }

    func testOneFailingMappingDoesNotStopTheOthers() async throws {
        let bad = mapping("bad", chat: 111, bot: 1)
        let good = mapping("good", chat: 222, bot: 2)
        MockTelegram.failuresByToken["1:bad"] = ["sendMessage": ["ok": false, "error_code": 401, "description": "Unauthorized"]]
        let tokens = ["bad": "1:bad", "good": "2:good"]

        let results = await Notifier.send([bad, good], text: "알림",
                                          loadToken: { tokens[$0.id]! },
                                          telegramFor: { token, chatID in self.tg(token, chatID: chatID) })

        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.mappingID, $0) })
        XCTAssertEqual(byID["bad"]?.ok, false)
        XCTAssertEqual(byID["bad"]?.code, "TELEGRAM_UNAUTHORIZED")
        XCTAssertEqual(byID["good"]?.ok, true)
        XCTAssertEqual(MockTelegram.calls("sendMessage", token: "2:good").count, 1)
    }

    func testTokenLoadFailureIsReportedWithoutLeakingTheToken() async throws {
        let m = mapping("x", chat: 111, bot: 1)
        let results = await Notifier.send([m], text: "알림",
                                          loadToken: { _ in throw ConfigError.tokenFormat },
                                          telegramFor: { token, chatID in self.tg(token, chatID: chatID) })
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].ok, false)
        XCTAssertEqual(results[0].code, "TOKEN_FORMAT")
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)
    }
}
