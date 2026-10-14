import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

/// 얇은 SQLite 래퍼. 같은 스레드에서만 쓴다(중계 루프는 순차 실행).
public final class SQLiteDB {
    public enum Mode { case readOnly, readWriteCreate }

    let handle: OpaquePointer
    public let mode: Mode

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, mode: Mode) throws {
        var db: OpaquePointer?
        let flags: Int32
        switch mode {
        case .readOnly:
            // chat.db 는 이 플래그로만 연다. 원본에 절대 쓰지 않는다.
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        case .readWriteCreate:
            flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        }
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw SQLiteError(message: "\(msg) (rc=\(rc))")
        }
        self.handle = db
        self.mode = mode
        sqlite3_busy_timeout(db, 3000)
        if mode == .readOnly {
            // 읽기 전용 연결에서 실수로라도 쓰기가 일어나지 않도록 한 번 더 막는다.
            try exec("PRAGMA query_only = ON")
        }
    }

    deinit { sqlite3_close(handle) }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(message: msg)
        }
    }

    public enum Value {
        case int(Int64), text(String), blob(Data), null
    }

    public struct Row {
        let stmt: OpaquePointer
        public func int(_ i: Int32) -> Int64? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, i)
        }
        public func text(_ i: Int32) -> String? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        public func blob(_ i: Int32) -> Data? {
            guard sqlite3_column_type(stmt, i) != SQLITE_NULL else { return nil }
            let n = Int(sqlite3_column_bytes(stmt, i))
            guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: n)
        }
    }

    @discardableResult
    public func query<T>(_ sql: String, _ params: [Value] = [], map: (Row) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (idx, p) in params.enumerated() {
            let i = Int32(idx + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, i, v)
            case .text(let v): sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, i)
            }
        }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try map(Row(stmt: stmt)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        return out
    }

    public func run(_ sql: String, _ params: [Value] = []) throws {
        _ = try query(sql, params) { _ in () }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
