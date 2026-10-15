import Foundation

/// 구조화 로그(사건 로그)의 등급. `info` 가 기본이고, 더 자세한 진단은 `debug` 로 켠다
/// (`EventLog.levelFromEnvironment` — 환경변수 `BLUEHOP_LOG_LEVEL=debug`).
public enum LogLevel: String, Comparable {
    case info
    case debug

    /// `debug` 가 더 자세한(그래서 기본으로는 가려지는) 쪽이라 더 낮은 등급이다 — 문턱을 `info` 로 두면
    /// `debug` 줄은 걸러지고, 문턱을 `debug` 로 낮추면 둘 다 나온다(`EventLog.log` 의 `level >= 문턱`).
    private var rank: Int { self == .debug ? 0 : 1 }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

/// 사건 로그 한 줄에 실을 수 있는 값. 본문·식별자를 그대로 담는 자리가 아니라 호출부가 길이·해시·개수 같은
/// 메타데이터로 미리 접어서 넘기게 한다(타입을 좁혀 실수로 아무 문자열이나 흘려 넣기 어렵게 함).
public enum LogValue {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        }
    }
}

extension LogValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension LogValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(Int64(value)) }
}

extension LogValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// 크기 기준으로 스스로 도는 로그 파일. `path`, `path.1` … `path.<keep-1>` 까지 두고 그보다 오래된 조각은
/// 지운다 — macOS 의 `aslmanager`·`newsyslog` 같은 바깥 도구 없이, 이 과정 혼자서 무한히 커지지 않게 한다.
/// 여러 매핑(스레드)이 같은 파일에 함께 쓰므로 모든 쓰기·회전을 하나의 잠금으로 막는다.
public final class RotatingFileLog {
    public let path: String
    let maxBytes: Int
    let keep: Int
    let lock = NSLock()
    var handle: FileHandle?
    var currentSize: Int

    /// - Parameters:
    ///   - maxBytes: 이 크기를 넘기기 전에 돈다(기본 10MB).
    ///   - keep: 지금 쓰는 파일 포함 몇 개까지 남기는가(기본 5 — `path` + `.1`…`.4`).
    public init(path: String, maxBytes: Int = 10 * 1024 * 1024, keep: Int = 5) {
        self.path = path
        self.maxBytes = max(64, maxBytes)
        self.keep = max(1, keep)
        let fm = FileManager.default
        try? ConfigLoader.ensurePrivateDir((path as NSString).deletingLastPathComponent)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        currentSize = ((try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    /// 한 줄(개행 없이 넘겨도 된다) 적는다. 적은 뒤 크기가 한도를 넘으면 다음 줄 전에 돈다.
    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let data = Data((line + "\n").utf8)
        if currentSize > 0, currentSize + data.count > maxBytes { rotate() }
        // `rotate()` 가 `self.handle` 를 새 파일로 바꿔치울 수 있으므로, 돈 뒤에 다시 읽어야 한다
        // (돌기 전에 꺼내 둔 손잡이로 쓰면 이미 옮겨지거나 지워진 옛 파일에 쓰게 된다).
        guard let handle else { return }
        handle.write(data)
        currentSize += data.count
    }

    private func rotate() {
        let fm = FileManager.default
        handle?.closeFile()
        try? fm.removeItem(atPath: "\(path).\(keep - 1)")
        for i in stride(from: keep - 2, through: 1, by: -1) {
            let from = "\(path).\(i)"
            guard fm.fileExists(atPath: from) else { continue }
            try? fm.removeItem(atPath: "\(path).\(i + 1)")
            try? fm.moveItem(atPath: from, toPath: "\(path).\(i + 1)")
        }
        if keep > 1 { try? fm.moveItem(atPath: path, toPath: "\(path).1") } else { try? fm.removeItem(atPath: path) }
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = FileHandle(forWritingAtPath: path)
        currentSize = 0
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        handle?.closeFile()
        handle = nil
    }
}

/// 요청 하나(텔레그램 업데이트·메시지, iMessage 행)가 거친 단계를 한 줄씩 남기는 구조화(JSON Lines) 로그.
/// 사람이 읽는 `log: (String) -> Void` 줄과는 별도 파일 — 그 줄은 바뀌지 않는다.
///
/// 개인정보 원칙: 메시지 본문·전화번호·Apple ID·봇 토큰은 **호출부가 절대 넘기지 않는다**(이 타입은 받은
/// 것을 그대로 적을 뿐 가리지 않는다 — 안전은 호출부 책임). 길이·해시·개수 같은 메타데이터만 싣는다.
/// 본문을 실어야 하는 드문 진단 상황은 `capturesBodies` 가 true 일 때만(`debug` 레벨이면서 `logBodies`
/// 를 명시적으로 켰을 때만) 호출부가 따로 판단해 본문 필드를 추가로 넣는다.
public final class EventLog {
    let file: RotatingFileLog
    let level: LogLevel
    let logBodies: Bool
    let clock: () -> Date

    public init(file: RotatingFileLog, level: LogLevel, logBodies: Bool, clock: @escaping () -> Date = Date.init) {
        self.file = file
        self.level = level
        self.logBodies = logBodies
        self.clock = clock
    }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// 본문을 실어도 되는가 — `debug` 레벨이면서 `logBodies` 를 명시적으로 켰을 때만.
    public var capturesBodies: Bool { logBodies && level == .debug }

    public func log(_ level: LogLevel, mapping: String, event: String, _ fields: [String: LogValue] = [:]) {
        guard level >= self.level else { return }
        var obj: [String: Any] = ["ts": Self.iso8601.string(from: clock()), "level": level.rawValue, "mapping": mapping, "event": event]
        for (k, v) in fields { obj[k] = v.jsonValue }
        guard JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        file.write(String(decoding: data, as: UTF8.self))
    }

    public func close() { file.close() }
}

public extension EventLog {
    /// `BLUEHOP_LOG_LEVEL=debug` 로 올린다. 그 밖의 값(없음 포함)은 `info`.
    static func levelFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LogLevel {
        (env["BLUEHOP_LOG_LEVEL"]?.lowercased() == "debug") ? .debug : .info
    }

    /// `BLUEHOP_LOG_BODIES=1`(`true`/`yes` 도) 로 본문 기록을 켠다. `debug` 레벨이 아니면 이 값과 상관없이
    /// 본문은 실리지 않는다(`EventLog.capturesBodies` 참고) — 레벨과 본문 스위치 둘 다 명시적으로 켜야 한다.
    static func bodiesEnabledFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        ["1", "true", "yes"].contains((env["BLUEHOP_LOG_BODIES"] ?? "").lowercased())
    }
}
