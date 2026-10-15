import Foundation
import XCTest
@testable import BluehopCore

/// 구조화(JSON Lines) 사건 로그: 한 줄의 모양, 크기 기준 회전, 개인정보가 새지 않는지를 고정한다.
final class EventLogTests: XCTestCase {
    func tempLogPath() -> String {
        makeTempDir().appendingPathComponent("events.jsonl").path
    }

    // MARK: 줄 모양

    func testLineIsJSONWithExpectedFieldsAndISO8601UTCTimestamp() throws {
        let path = tempLogPath()
        let fixedDate = Date(timeIntervalSince1970: 1_800_000_123)
        let log = EventLog(file: RotatingFileLog(path: path), level: .info, logBodies: false, clock: { fixedDate })
        log.log(.info, mapping: "default", event: "tg_message_received", ["tg_message_id": .int(42), "text_len": .int(3)])

        let line = try XCTUnwrap(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").first)
        XCTAssertFalse(line.contains("\n"))  // 한 사건 = 한 줄
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(obj["level"] as? String, "info")
        XCTAssertEqual(obj["mapping"] as? String, "default")
        XCTAssertEqual(obj["event"] as? String, "tg_message_received")
        XCTAssertEqual(obj["tg_message_id"] as? Int64, 42)
        XCTAssertEqual(obj["text_len"] as? Int64, 3)
        // UTC, Z 로 끝나는 ISO8601(로컬 시간대·오프셋 표기가 아님)
        let ts = try XCTUnwrap(obj["ts"] as? String)
        XCTAssertTrue(ts.hasSuffix("Z"), ts)
        XCTAssertEqual(ISO8601DateFormatter().date(from: ts)?.timeIntervalSince1970, fixedDate.timeIntervalSince1970)
    }

    // MARK: 레벨

    func testDebugLineIsDroppedAtInfoLevelButKeptAtDebugLevel() throws {
        let path = tempLogPath()
        let infoOnly = EventLog(file: RotatingFileLog(path: path), level: .info, logBodies: false)
        infoOnly.log(.debug, mapping: "default", event: "echo_wait")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "")

        let debugLog = EventLog(file: RotatingFileLog(path: path), level: .debug, logBodies: false)
        debugLog.log(.debug, mapping: "default", event: "echo_wait")
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("echo_wait"))
    }

    func testLevelAndBodiesReadFromEnvironment() {
        XCTAssertEqual(EventLog.levelFromEnvironment([:]), .info)
        XCTAssertEqual(EventLog.levelFromEnvironment(["BLUEHOP_LOG_LEVEL": "debug"]), .debug)
        XCTAssertEqual(EventLog.levelFromEnvironment(["BLUEHOP_LOG_LEVEL": "DEBUG"]), .debug)
        XCTAssertEqual(EventLog.levelFromEnvironment(["BLUEHOP_LOG_LEVEL": "info"]), .info)
        XCTAssertFalse(EventLog.bodiesEnabledFromEnvironment([:]))
        XCTAssertTrue(EventLog.bodiesEnabledFromEnvironment(["BLUEHOP_LOG_BODIES": "1"]))
        XCTAssertTrue(EventLog.bodiesEnabledFromEnvironment(["BLUEHOP_LOG_BODIES": "true"]))
    }

    /// 본문은 `debug` 레벨 **그리고** `logBodies` 둘 다 켰을 때만 실어도 된다고 판정한다 — 하나만 켜면 안 된다.
    func testCapturesBodiesRequiresBothDebugLevelAndExplicitSwitch() {
        let path = tempLogPath()
        XCTAssertFalse(EventLog(file: RotatingFileLog(path: path), level: .info, logBodies: true).capturesBodies)
        XCTAssertFalse(EventLog(file: RotatingFileLog(path: path), level: .debug, logBodies: false).capturesBodies)
        XCTAssertTrue(EventLog(file: RotatingFileLog(path: path), level: .debug, logBodies: true).capturesBodies)
    }

    // MARK: 회전

    func testRotatesBySizeAndKeepsBoundedNumberOfFiles() throws {
        let path = tempLogPath()
        let file = RotatingFileLog(path: path, maxBytes: 500, keep: 3)
        for i in 0..<200 { file.write("line \(i) " + String(repeating: "x", count: 20)) }
        file.close()

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: path))
        XCTAssertTrue(fm.fileExists(atPath: path + ".1"))
        XCTAssertTrue(fm.fileExists(atPath: path + ".2"))
        XCTAssertFalse(fm.fileExists(atPath: path + ".3"))  // keep=3 을 넘는 조각은 없다

        for p in [path, path + ".1", path + ".2"] {
            let size = (try fm.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue ?? -1
            XCTAssertLessThanOrEqual(size, 500 + 64, p)  // 한도 + 마지막 한 줄 정도의 여유
        }
    }

    /// 돌고 나서도 가장 최신 줄은 현재 파일에, 더 오래된 줄은 `.1`에 있다(순서가 뒤집히지 않는다).
    func testRotationPreservesChronologicalOrderAcrossFiles() throws {
        let path = tempLogPath()
        let file = RotatingFileLog(path: path, maxBytes: 200, keep: 3)
        for i in 0..<40 { file.write("seq=\(i)") }
        file.close()

        let current = try String(contentsOfFile: path, encoding: .utf8)
        let previous = try String(contentsOfFile: path + ".1", encoding: .utf8)
        func firstSeq(_ s: String) -> Int { Int(s.split(separator: "\n").first?.split(separator: "=").last ?? "") ?? -1 }
        XCTAssertLessThan(firstSeq(previous), firstSeq(current))
    }

    // MARK: 개인정보

    /// 평소(레벨 기본값) 사건 로그엔 메시지 본문·전화번호·토큰이 실리지 않는다 — 메타데이터(길이 등)만.
    func testRelayTickNeverLeaksMessageBodyPhoneOrTokenIntoDefaultEventLog() async throws {
        let path = tempLogPath()
        let events = EventLog(file: RotatingFileLog(path: path), level: .info, logBodies: false)
        let secretBody = "내 비밀번호는 Sw0rdfish 야"
        let h = try Harness.make(events: events) { $0.echoGraceSeconds = 0 }
        try await h.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 7, text: secretBody)])
        await h.relay.tick()
        h.relay.events?.close()

        let logged = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(logged.contains(secretBody), logged)
        XCTAssertFalse(logged.contains("Sw0rdfish"), logged)
        XCTAssertFalse(logged.contains(Harness.token), logged)
        XCTAssertFalse(logged.contains("+8210"), logged)  // 전화번호 형태
        XCTAssertTrue(logged.contains("tg_message_received"), logged)  // 사건 자체는 남는다
    }

    /// `debug` + 본문 스위치를 둘 다 켰을 때만 `Relay` 가 실제로 받은 텔레그램 글을 사건 로그에 싣는다 —
    /// 둘 중 하나라도 꺼져 있으면(기본값) 같은 사건이라도 본문 없이, 길이만 남는다.
    func testTelegramMessageBodyOnlyAppearsWhenDebugLevelAndBodySwitchAreBothOn() async throws {
        let text = "디버그로만 보이는 본문"
        let defaultPath = tempLogPath()
        let defaultEvents = EventLog(file: RotatingFileLog(path: defaultPath), level: .info, logBodies: false)
        let hDefault = try Harness.make(events: defaultEvents)
        try await hDefault.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 1, text: text)])
        await hDefault.relay.tick()
        hDefault.relay.events?.close()
        let defaultLogged = try String(contentsOfFile: defaultPath, encoding: .utf8)
        XCTAssertFalse(defaultLogged.contains(text), defaultLogged)
        XCTAssertTrue(defaultLogged.contains("\"text_len\":"), defaultLogged)

        let debugPath = tempLogPath()
        let debugEvents = EventLog(file: RotatingFileLog(path: debugPath), level: .debug, logBodies: true)
        let hDebug = try Harness.make(events: debugEvents)
        try await hDebug.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 1, text: text)])
        await hDebug.relay.tick()
        hDebug.relay.events?.close()
        let debugLogged = try String(contentsOfFile: debugPath, encoding: .utf8)
        XCTAssertTrue(debugLogged.contains(text), debugLogged)
    }
}
