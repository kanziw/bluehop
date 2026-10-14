import Foundation
import XCTest
@testable import BluehopCore

/// 상태 DB: 0.4.x(매핑 구분 없음) → 매핑별 스키마, 매핑끼리 섞이지 않음.
final class StateMigrationTests: XCTestCase {
    /// 0.4.x 와 같은 스키마로 만든 상태 DB.
    func makeLegacyState(at path: String) throws {
        let db = try SQLiteDB(path: path, mode: .readWriteCreate)
        try db.exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
            CREATE TABLE mapping (imsg_guid TEXT NOT NULL, part INTEGER NOT NULL, tg_message_id INTEGER NOT NULL,
                direction TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY (imsg_guid, part));
            CREATE INDEX mapping_tg ON mapping(tg_message_id);
            CREATE TABLE outbox (tg_message_id INTEGER NOT NULL, part INTEGER NOT NULL, kind TEXT NOT NULL,
                match_key TEXT, status TEXT NOT NULL, created_at REAL NOT NULL, detail TEXT,
                matched_guid TEXT, notified INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (tg_message_id, part));
            CREATE TABLE pending_attachment (rowid INTEGER PRIMARY KEY, first_seen REAL NOT NULL);
            CREATE TABLE reaction_state (target_tg INTEGER PRIMARY KEY, emoji TEXT NOT NULL);
            INSERT INTO kv VALUES ('imsg_cursor', '42'), ('tg_offset', '1001'), ('halted', '이유');
            INSERT INTO mapping VALUES ('GUID-A', 0, 77, 'im->tg', 1800000000);
            INSERT INTO outbox VALUES (10, 0, 'text', NULL, 'confirmed', 1800000000, NULL, 'GUID-B', 1);
            INSERT INTO pending_attachment VALUES (5, 1800000000);
            INSERT INTO reaction_state VALUES (77, '❤');
            """)
    }

    func testLegacyStateMovesUnderDefaultWithBackup() throws {
        let dir = makeTempDir()
        let path = dir.appendingPathComponent("state.sqlite").path
        try makeLegacyState(at: path)

        let s = try StateStore(path: path)
        XCTAssertEqual(s.mappingID, "default")
        XCTAssertEqual(s.imsgCursor, 42)
        XCTAssertEqual(s.tgOffset, 1001)
        XCTAssertTrue(s.hasTGBaseline)
        XCTAssertEqual(s.haltReason, "이유")
        XCTAssertEqual(try s.tgMessageID(forGuid: "GUID-A"), 77)
        XCTAssertEqual(try s.imsgGuid(forTG: 77), "GUID-A")
        XCTAssertTrue(try s.hasOutbox(tgMessageID: 10))
        XCTAssertEqual(try s.reaction(onTG: 77), "❤")
        XCTAssertEqual(try s.pendingSince(rowid: 5, now: 1_900_000_000), 1_800_000_000)

        // 옮기기 전 사본(0600)
        let backup = path + ".v1-backup"
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup)[.posixPermissions] as? Int, 0o600)
        let old = try SQLiteDB(path: backup, mode: .readOnly)
        XCTAssertEqual(try old.query("SELECT v FROM kv WHERE k = 'imsg_cursor'") { $0.text(0) }.first ?? nil, "42")

        // 다른 매핑은 빈 상태로 시작한다
        let other = try StateStore(path: path, mappingID: "work")
        XCTAssertNil(other.imsgCursor)
        XCTAssertFalse(other.hasTGBaseline)
        XCTAssertNil(other.haltReason)
        XCTAssertFalse(try other.hasOutbox(tgMessageID: 10))

        // 다시 열어도 다시 옮기지 않는다(값 그대로)
        let again = try StateStore(path: path)
        XCTAssertEqual(again.imsgCursor, 42)
        XCTAssertEqual(try again.knownMappingIDs(), ["default"])
    }

    func testViewsAreIsolatedPerMapping() throws {
        let path = makeTempDir().appendingPathComponent("state.sqlite").path
        let a = try StateStore(path: path, mappingID: "a")
        let b = try StateStore(path: path, mappingID: "b")
        try a.setIMsgCursor(10)
        try b.setIMsgCursor(20)
        try a.setTGOffset(5)
        try a.setHalted("a 만 정지")
        // 봇이 달라 같은 텔레그램 message_id 가 두 매핑에 다 있을 수 있다
        try a.insertOutbox(OutboxEntry(tgMessageID: 7, part: 0, kind: "text", matchKey: "hi", status: .sent, createdAt: 1, detail: nil))
        try b.insertOutbox(OutboxEntry(tgMessageID: 7, part: 0, kind: "text", matchKey: "hi", status: .sent, createdAt: 1, detail: nil))
        try a.updateOutbox(tgMessageID: 7, part: 0, status: .confirmed, clearKey: true)
        try a.saveMapping(imsgGuid: "G", part: 0, tgMessageID: 7, direction: "tg->im", now: 1)

        XCTAssertEqual(a.imsgCursor, 10)
        XCTAssertEqual(b.imsgCursor, 20)
        XCTAssertEqual(b.tgOffset, 0)
        XCTAssertFalse(b.hasTGBaseline)
        XCTAssertNil(b.haltReason)
        XCTAssertEqual(try a.outbox(tgMessageID: 7).first?.status, .confirmed)
        XCTAssertEqual(try b.outbox(tgMessageID: 7).first?.status, .sent)
        XCTAssertNil(try a.oldestAwaitingEcho(kind: "text", matchKey: "hi"))
        XCTAssertNotNil(try b.oldestAwaitingEcho(kind: "text", matchKey: "hi"))
        XCTAssertFalse(try a.hasUnresolvedOutbox())
        XCTAssertTrue(try b.hasUnresolvedOutbox())
        XCTAssertNil(try b.tgMessageID(forGuid: "G"))

        try b.purgeAll()
        XCTAssertNil(b.imsgCursor)
        XCTAssertEqual(a.imsgCursor, 10)
        XCTAssertEqual(try a.knownMappingIDs(), ["a"])
    }

    func testHealthRecords() throws {
        let s = try StateStore(path: makeTempDir().appendingPathComponent("state.sqlite").path, mappingID: "x")
        XCTAssertEqual(s.health(), StateStore.Health())
        s.setHealthState("running")
        s.markTelegramOK(100)
        s.recordError("나쁜 일", at: 120)
        var h = s.health()
        XCTAssertEqual(h.state, "running")
        XCTAssertEqual(h.lastTelegramOK, 100)
        XCTAssertEqual(h.lastError, "나쁜 일")
        XCTAssertEqual(h.lastErrorAt, 120)
        s.recordError(nil, at: 130)
        h = s.health()
        XCTAssertNil(h.lastError)
        XCTAssertNil(h.lastErrorAt)
    }

    func testStatusVerdicts() {
        let now = 1000.0
        func v(_ h: StateStore.Health, enabled: Bool = true) -> String { MappingStatus(id: "x", enabled: enabled, health: h).verdict(now: now) }
        XCTAssertEqual(v(StateStore.Health(), enabled: false), "paused")
        XCTAssertEqual(v(StateStore.Health(halted: "정지")), "halted")
        XCTAssertEqual(v(StateStore.Health(lastTelegramOK: 990, lastError: "x", lastErrorAt: 995)), "error")
        XCTAssertEqual(v(StateStore.Health(lastTelegramOK: 990)), "ok")
        XCTAssertEqual(v(StateStore.Health(lastTelegramOK: 800)), "stale")
        XCTAssertEqual(v(StateStore.Health()), "unknown")
        let j = MappingStatus(id: "x", enabled: true, health: StateStore.Health(lastTelegramOK: 990)).json(now: now)
        XCTAssertEqual(j["verdict"] as? String, "ok")
        XCTAssertNotNil(j["lastTelegramPollAt"] as? String)
    }
}
