import Foundation
import XCTest
@testable import BluehopCore

/// `doctor --json`·`status --json` 의 안정된 코드와 `--lang en`. 에이전트가 문구 대신 기대는 계약이라 고정한다.
final class MachineReadableTests: XCTestCase {
    func testErrorsMapToStableCodes() {
        XCTAssertEqual(ErrorCodes.of(ConfigError.missing("x")), "CONFIG_MISSING")
        XCTAssertEqual(ErrorCodes.of(ConfigError.insecurePermissions(path: "x", mode: 0o644)), "CONFIG_PERMISSIONS")
        XCTAssertEqual(ErrorCodes.of(ConfigError.invalid("x")), "CONFIG_INVALID")
        XCTAssertEqual(ErrorCodes.of(ConfigError.conflict("x")), "CONFIG_CONFLICT")
        XCTAssertEqual(ErrorCodes.of(ConfigError.token("Keychain")), "TOKEN_UNREADABLE")
        XCTAssertEqual(ErrorCodes.of(ConfigError.tokenFormat), "TOKEN_FORMAT")
        XCTAssertEqual(ErrorCodes.of(ConfigError.botMismatch(got: 1, want: 2)), "TOKEN_BOT_MISMATCH")
        XCTAssertEqual(ErrorCodes.of(ChatDBError.chatNotFound), "CHAT_NOT_FOUND")
        XCTAssertEqual(ErrorCodes.of(ChatDBError.notOneToOne(style: 43, participants: 3)), "CHAT_NOT_ONE_TO_ONE")
        XCTAssertEqual(ErrorCodes.of(ChatDBError.handleMismatch), "CHAT_HANDLE_MISMATCH")
        XCTAssertEqual(ErrorCodes.of(SQLiteError(message: "unable to open database file (rc=14)")), "CHATDB_UNREADABLE")
        XCTAssertEqual(ErrorCodes.of(TelegramError.api(method: "getMe", code: 401, description: "Unauthorized")), "TELEGRAM_UNAUTHORIZED")
        XCTAssertEqual(ErrorCodes.of(TelegramError.api(method: "getMe", code: 404, description: "Not Found")), "TELEGRAM_UNAUTHORIZED")
        XCTAssertEqual(ErrorCodes.of(TelegramError.api(method: "getUpdates", code: 409, description: "Conflict")), "TELEGRAM_CONFLICT")
        XCTAssertEqual(ErrorCodes.of(TelegramError.api(method: "getMe", code: 500, description: "x")), "TELEGRAM_ERROR")
        XCTAssertEqual(ErrorCodes.of(TelegramError.retryAfter(seconds: 3)), "TELEGRAM_RATE_LIMITED")
        XCTAssertEqual(ErrorCodes.of(TelegramError.network(method: "getMe", code: -1009)), "TELEGRAM_NETWORK")
        XCTAssertEqual(ErrorCodes.of(SendError("osascript 실패: execution error: Not authorized (-1743)")), "MESSAGES_AUTOMATION_DENIED")
        XCTAssertEqual(ErrorCodes.of(SendError("osascript 실패")), "MESSAGES_ERROR")
        XCTAssertEqual(ErrorCodes.of(CheckFailure("TELEGRAM_SKIPPED", "x")), "TELEGRAM_SKIPPED")
        XCTAssertEqual(ErrorCodes.of(CLIError(.notFound, "x")), "MAPPING_NOT_FOUND")
        XCTAssertEqual(ErrorCodes.of(NSError(domain: "x", code: 1)), "UNKNOWN")
    }

    func testCatalogIsCompleteUniqueAndEnglish() {
        let codes = ErrorCodes.catalog.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        for c in codes {
            XCTAssertNotNil(c.range(of: "^[A-Z][A-Z0-9_]+$", options: .regularExpression), c)
            XCTAssertFalse(ErrorCodes.message(c).unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }, c)
        }
        // 지우거나 이름을 바꾸면 깨지는 변경: 아래 목록은 줄일 수 없다.
        let frozen = ["OK", "CONFIG_MISSING", "CONFIG_PERMISSIONS", "CONFIG_INVALID", "CONFIG_CONFLICT", "MAPPING_NOT_FOUND",
                      "TOKEN_UNREADABLE", "TOKEN_FORMAT", "TOKEN_BOT_MISMATCH", "CHATDB_UNREADABLE", "CHAT_NOT_FOUND",
                      "CHAT_NOT_ONE_TO_ONE", "CHAT_HANDLE_MISMATCH", "MESSAGES_AUTOMATION_DENIED", "MESSAGES_CHAT_NOT_FOUND",
                      "MESSAGES_ERROR", "TELEGRAM_UNAUTHORIZED", "TELEGRAM_CONFLICT", "TELEGRAM_RATE_LIMITED", "TELEGRAM_NETWORK",
                      "TELEGRAM_ERROR", "TELEGRAM_SKIPPED", "UNKNOWN"]
        XCTAssertEqual(Set(frozen).subtracting(codes), [])
        // README 의 표와 같아야 한다
        let readme = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("README.md")
        let text = (try? String(contentsOf: readme, encoding: .utf8)) ?? ""
        for c in codes { XCTAssertTrue(text.contains("`\(c)`"), "README 에 코드 \(c) 가 없다") }
    }

    func testLanguageResolution() throws {
        XCTAssertEqual(try OutputLanguage.resolve(flag: nil, environment: [:]), .ko)
        XCTAssertEqual(try OutputLanguage.resolve(flag: nil, environment: ["BLUEHOP_LANG": "en"]), .en)
        XCTAssertEqual(try OutputLanguage.resolve(flag: "ko", environment: ["BLUEHOP_LANG": "en"]), .ko)
        XCTAssertEqual(try OutputLanguage.resolve(flag: "EN", environment: [:]), .en)
        XCTAssertThrowsError(try OutputLanguage.resolve(flag: "fr", environment: [:])) { XCTAssertEqual(($0 as? CLIError)?.code, .usage) }
        XCTAssertThrowsError(try OutputLanguage.resolve(flag: nil, environment: ["BLUEHOP_LANG": "fr"]))
    }

    func testDoctorCheckShapeAndLines() {
        let ok = DoctorCheck.passed("token", ko: "읽음 (파일)", en: "read (file)")
        XCTAssertEqual(ok["code"] as? String, "OK")
        XCTAssertEqual(ok["id"] as? String, "token")
        XCTAssertEqual(ok["name"] as? String, "봇 토큰")
        XCTAssertEqual(ok["title"] as? String, "Bot token")
        let bad = DoctorCheck.failed("chatdb", ChatDBError.chatNotFound)
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertEqual(bad["code"] as? String, "CHAT_NOT_FOUND")
        XCTAssertEqual(bad["detail"] as? String, ChatDBError.chatNotFound.description)
        XCTAssertEqual(Set((bad.keys)), ["id", "name", "title", "ok", "code", "detail", "message"])
        let plain = bad.compactMapValues { $0 }
        XCTAssertEqual(DoctorCheck.line(plain, lang: .ko), "✘ chat.db 읽기 전용 열기 + 대화 검증: \(ChatDBError.chatNotFound.description)")
        XCTAssertEqual(DoctorCheck.line(plain, lang: .en),
                       "✘ chat.db read-only open + chat check [CHAT_NOT_FOUND]: " + ErrorCodes.message("CHAT_NOT_FOUND"))
        XCTAssertEqual(DoctorCheck.line(ok.compactMapValues { $0 }, lang: .en), "✔ Bot token: read (file)")
        XCTAssertEqual(DoctorCheck.failingCodes([ok, bad, bad]), ["CHAT_NOT_FOUND"])
    }

    func testStatusRecordsErrorCodeAndPrintsEnglish() throws {
        let s = try StateStore(path: makeTempDir().appendingPathComponent("state.sqlite").path, mappingID: "family")
        s.recordError("telegram getUpdates 실패 409: Conflict", code: "TELEGRAM_CONFLICT", at: 100)
        var h = s.health()
        XCTAssertEqual(h.lastErrorCode, "TELEGRAM_CONFLICT")
        let row = MappingStatus(id: "family", enabled: true, health: h)
        XCTAssertEqual(row.json(now: 120)["lastErrorCode"] as? String, "TELEGRAM_CONFLICT")
        let en = StatusText.lines(service: ServiceState(loaded: false, running: false, pid: nil), rows: [row], now: 120, lang: .en)
        XCTAssertEqual(en[0], "service dev.kanziw.bluehop: not loaded")
        XCTAssertTrue(en[1].hasPrefix("[family] error · error [TELEGRAM_CONFLICT]: "), en[1])
        XCTAssertFalse(en.joined().unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }, en.joined())
        // 코드 없이 남긴 오류는 UNKNOWN, 오류가 지워지면 코드도 지운다
        s.recordError("나쁜 일", at: 130)
        h = s.health()
        XCTAssertEqual(h.lastErrorCode, "UNKNOWN")
        s.recordError(nil, at: 140)
        XCTAssertNil(s.health().lastErrorCode)
        XCTAssertNil(MappingStatus(id: "family", enabled: true, health: s.health()).json(now: 150)["lastErrorCode"] ?? nil)
    }
}
