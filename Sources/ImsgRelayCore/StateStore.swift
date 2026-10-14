import Foundation

/// 텔레그램 → iMessage 발송 한 건(한 텔레그램 메시지의 한 부분)의 상태.
public enum OutboxStatus: String {
    /// 보내기 직전에 기록. 이 상태로 남아 있으면 osascript 도중 죽은 것 — 다시 보내지 않는다.
    case sending
    /// osascript 가 성공을 돌려줌. chat.db 에 기록되기를 기다린다.
    case sent
    /// chat.db 에서 내 메시지로 확인됨.
    case confirmed
    case failed
}

public struct OutboxEntry: Equatable {
    public var tgMessageID: Int64
    public var part: Int
    public var kind: String   // "text" | "file"
    /// 메아리 맞춤 키: 글이면 보낸 글, 파일이면 파일 이름. 확인되면 지운다.
    public var matchKey: String?
    public var status: OutboxStatus
    public var createdAt: Double
    public var detail: String?
}

/// 로컬 상태 DB(0600). 커서·매핑·outbox. 메시지 본문은 outbox 의 메아리 맞춤 키로만 잠깐 둔다.
public final class StateStore {
    let db: SQLiteDB

    public init(path: String) throws {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: path)
        if !existed {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        db = try SQLiteDB(path: path, mode: .readWriteCreate)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try db.exec("PRAGMA journal_mode = WAL")
        try db.exec("""
            CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS mapping (
                imsg_guid TEXT NOT NULL, part INTEGER NOT NULL, tg_message_id INTEGER NOT NULL,
                direction TEXT NOT NULL, created_at REAL NOT NULL,
                PRIMARY KEY (imsg_guid, part));
            CREATE INDEX IF NOT EXISTS mapping_tg ON mapping(tg_message_id);
            CREATE TABLE IF NOT EXISTS outbox (
                tg_message_id INTEGER NOT NULL, part INTEGER NOT NULL, kind TEXT NOT NULL,
                match_key TEXT, status TEXT NOT NULL, created_at REAL NOT NULL, detail TEXT,
                matched_guid TEXT, notified INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (tg_message_id, part));
            CREATE TABLE IF NOT EXISTS pending_attachment (rowid INTEGER PRIMARY KEY, first_seen REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS reaction_state (target_tg INTEGER PRIMARY KEY, emoji TEXT NOT NULL);
            """)
    }

    // MARK: kv
    public func get(_ k: String) throws -> String? {
        try db.query("SELECT v FROM kv WHERE k = ?", [.text(k)]) { $0.text(0) }.first ?? nil
    }
    public func set(_ k: String, _ v: String?) throws {
        if let v {
            try db.run("INSERT INTO kv(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [.text(k), .text(v)])
        } else {
            try db.run("DELETE FROM kv WHERE k = ?", [.text(k)])
        }
    }

    public var imsgCursor: Int64? {
        get { (try? get("imsg_cursor")).flatMap { $0 }.flatMap { Int64($0) } }
    }
    public func setIMsgCursor(_ v: Int64) throws { try set("imsg_cursor", String(v)) }

    public var tgOffset: Int64 { (try? get("tg_offset")).flatMap { $0 }.flatMap { Int64($0) } ?? 0 }
    public func setTGOffset(_ v: Int64) throws { try set("tg_offset", String(v)) }
    /// 텔레그램 기준선을 한 번이라도 잡았는지(`tg_offset` 값이 0이어도 명시적으로 저장된 적 있는지).
    /// 값이 없을 때만 false — 첫 실행·상태 DB 초기화 뒤를 구분하는 유일한 신호다.
    public var hasTGBaseline: Bool { ((try? get("tg_offset")) ?? nil) != nil }

    public var haltReason: String? { (try? get("halted")) ?? nil }
    public func setHalted(_ reason: String?) throws { try set("halted", reason) }

    // MARK: mapping
    public func saveMapping(imsgGuid: String, part: Int, tgMessageID: Int64, direction: String, now: Double) throws {
        try db.run("""
            INSERT INTO mapping(imsg_guid, part, tg_message_id, direction, created_at) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(imsg_guid, part) DO UPDATE SET tg_message_id = excluded.tg_message_id
            """, [.text(imsgGuid), .int(Int64(part)), .int(tgMessageID), .text(direction), .int(Int64(now))])
    }

    /// guid(+part)에 대응하는 텔레그램 message_id. part 가 없거나 못 찾으면 가장 앞 부분.
    public func tgMessageID(forGuid guid: String, part: Int? = nil) throws -> Int64? {
        if let part, let exact = try db.query("SELECT tg_message_id FROM mapping WHERE imsg_guid = ? AND part = ?",
                                              [.text(guid), .int(Int64(part))], map: { $0.int(0) }).first ?? nil {
            return exact
        }
        return try db.query("SELECT tg_message_id FROM mapping WHERE imsg_guid = ? ORDER BY part LIMIT 1",
                            [.text(guid)]) { $0.int(0) }.first ?? nil
    }

    public func hasMapping(imsgGuid: String, part: Int) throws -> Bool {
        try db.query("SELECT 1 FROM mapping WHERE imsg_guid = ? AND part = ?", [.text(imsgGuid), .int(Int64(part))]) { _ in true }.first ?? false
    }

    public func imsgGuid(forTG id: Int64) throws -> String? {
        try db.query("SELECT imsg_guid FROM mapping WHERE tg_message_id = ? LIMIT 1", [.int(id)]) { $0.text(0) }.first ?? nil
    }

    // MARK: reaction state (봇이 텔레그램 메시지에 달아 둔 반응)
    public func reaction(onTG id: Int64) throws -> String? {
        try db.query("SELECT emoji FROM reaction_state WHERE target_tg = ?", [.int(id)]) { $0.text(0) }.first ?? nil
    }
    public func setReaction(onTG id: Int64, _ emoji: String?) throws {
        if let emoji {
            try db.run("INSERT INTO reaction_state(target_tg, emoji) VALUES(?, ?) ON CONFLICT(target_tg) DO UPDATE SET emoji = excluded.emoji",
                       [.int(id), .text(emoji)])
        } else {
            try db.run("DELETE FROM reaction_state WHERE target_tg = ?", [.int(id)])
        }
    }

    // MARK: outbox
    /// 이 텔레그램 메시지를 이미 다룬 적이 있는가(멱등성의 핵심).
    public func hasOutbox(tgMessageID: Int64) throws -> Bool {
        try db.query("SELECT 1 FROM outbox WHERE tg_message_id = ? LIMIT 1", [.int(tgMessageID)]) { _ in true }.first ?? false
    }

    public func insertOutbox(_ e: OutboxEntry) throws {
        try db.run("""
            INSERT INTO outbox(tg_message_id, part, kind, match_key, status, created_at, detail)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """, [.int(e.tgMessageID), .int(Int64(e.part)), .text(e.kind),
                  e.matchKey.map { .text($0) } ?? .null, .text(e.status.rawValue), .int(Int64(e.createdAt)),
                  e.detail.map { .text($0) } ?? .null])
    }

    public func updateOutbox(tgMessageID: Int64, part: Int, status: OutboxStatus, detail: String? = nil,
                             matchedGuid: String? = nil, clearKey: Bool = false) throws {
        try db.run("""
            UPDATE outbox SET status = ?, detail = COALESCE(?, detail), matched_guid = COALESCE(?, matched_guid),
                match_key = CASE WHEN ? THEN NULL ELSE match_key END
            WHERE tg_message_id = ? AND part = ?
            """, [.text(status.rawValue), detail.map { .text($0) } ?? .null, matchedGuid.map { .text($0) } ?? .null,
                  .int(clearKey ? 1 : 0), .int(tgMessageID), .int(Int64(part))])
    }

    public func outbox(tgMessageID: Int64) throws -> [OutboxEntry] {
        try db.query("""
            SELECT tg_message_id, part, kind, match_key, status, created_at, detail FROM outbox
            WHERE tg_message_id = ? ORDER BY part
            """, [.int(tgMessageID)], map: Self.mapOutbox)
    }

    /// 아직 확인되지 않은(메아리를 기다리거나 보내는 중인) 텔레그램 발송이 하나라도 있는가.
    /// 있으면 방금 본 `is_from_me` 행을 "iPhone 에서 직접 보낸 글"로 단정하기 전에 잠깐 기다린다
    /// (본문 비교가 아직 못 맞췄을 수 있음 — `Relay.relay` 의 메아리 유예).
    public func hasUnresolvedOutbox() throws -> Bool {
        try db.query("SELECT 1 FROM outbox WHERE status IN ('sending', 'sent') LIMIT 1") { _ in true }.first ?? false
    }

    /// 메아리를 기다리는(`sent`) 항목 중 kind·키가 같은 가장 오래된 것.
    public func oldestAwaitingEcho(kind: String, matchKey: String) throws -> OutboxEntry? {
        try db.query("""
            SELECT tg_message_id, part, kind, match_key, status, created_at, detail FROM outbox
            WHERE status IN ('sending', 'sent') AND kind = ? AND match_key = ? ORDER BY created_at, tg_message_id, part LIMIT 1
            """, [.text(kind), .text(matchKey)], map: Self.mapOutbox).first
    }

    /// 메아리를 기다리는 모든 항목(불일치 진단 로그용).
    public func awaitingEchoes() throws -> [OutboxEntry] {
        try db.query("""
            SELECT tg_message_id, part, kind, match_key, status, created_at, detail FROM outbox
            WHERE status IN ('sending', 'sent') ORDER BY created_at, tg_message_id, part LIMIT 20
            """, map: Self.mapOutbox)
    }

    /// 확인·실패가 정해졌지만 아직 사용자에게 알리지 않은 텔레그램 메시지들.
    public func unnotifiedTGMessages() throws -> [Int64] {
        try db.query("SELECT DISTINCT tg_message_id FROM outbox WHERE notified = 0 ORDER BY tg_message_id") { $0.int(0) ?? 0 }
    }

    public func markNotified(tgMessageID: Int64) throws {
        try db.run("UPDATE outbox SET notified = 1, match_key = NULL WHERE tg_message_id = ?", [.int(tgMessageID)])
    }

    /// 오래된 메아리 키를 지운다(본문을 오래 두지 않음).
    public func purgeOutboxKeys(olderThan cutoff: Double) throws {
        try db.run("UPDATE outbox SET match_key = NULL WHERE created_at < ? AND status IN ('confirmed','failed')", [.int(Int64(cutoff))])
    }

    private static func mapOutbox(_ r: SQLiteDB.Row) -> OutboxEntry {
        OutboxEntry(tgMessageID: r.int(0) ?? 0, part: Int(r.int(1) ?? 0), kind: r.text(2) ?? "",
                    matchKey: r.text(3), status: OutboxStatus(rawValue: r.text(4) ?? "") ?? .failed,
                    createdAt: Double(r.int(5) ?? 0), detail: r.text(6))
    }

    // MARK: pending attachments
    public func pendingSince(rowid: Int64, now: Double) throws -> Double {
        if let t = try db.query("SELECT first_seen FROM pending_attachment WHERE rowid = ?", [.int(rowid)], map: { $0.int(0) }).first ?? nil {
            return Double(t)
        }
        try db.run("INSERT INTO pending_attachment(rowid, first_seen) VALUES(?, ?)", [.int(rowid), .int(Int64(now))])
        return now
    }
    public func clearPending(rowid: Int64) throws {
        try db.run("DELETE FROM pending_attachment WHERE rowid = ?", [.int(rowid)])
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T { try db.transaction(body) }
}
