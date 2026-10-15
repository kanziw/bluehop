import Foundation

/// `--json` 출력 도우미. nil 은 null 로, 키는 정렬해 늘 같은 모양으로 낸다.
public enum JSONOut {
    public static func render(_ obj: Any?) -> String {
        let clean = normalize(obj)
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func normalize(_ v: Any?) -> Any {
        guard let v else { return NSNull() }
        let mirror = Mirror(reflecting: v)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first else { return NSNull() }
            return normalize(inner.value)
        }
        switch v {
        case let d as [String: Any?]: return d.mapValues { normalize($0) }
        case let d as [String: Any]: return d.mapValues { normalize($0) }
        case let a as [Any?]: return a.map { normalize($0) }
        case let a as [Any]: return a.map { normalize($0) }
        default: return v
        }
    }

    public static func iso(_ t: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    public static func localDate(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    public static func error(_ e: CLIError) -> String {
        render(["ok": false, "error": ["kind": e.kind, "message": e.message, "exitCode": Int(e.code.rawValue)]] as [String: Any])
    }

    /// 매핑 설정을 밖으로 낼 모양(토큰 없음).
    public static func mapping(_ m: MappingConfig) -> [String: Any?] {
        [
            "id": m.id, "enabled": m.enabled,
            "imessage": ["chatGuid": m.imessage.chatGuid, "handle": m.imessage.handle] as [String: Any?],
            "telegram": [
                "chatId": m.telegram.chatId, "allowedUserId": m.telegram.allowedUserId,
                "botId": m.telegram.botId, "botUsername": m.telegram.botUsername,
                "tokenSource": m.telegram.tokenSource,
                "tokenAccount": m.telegram.tokenSource == "keychain" ? m.keychainAccount : nil,
                "tokenFile": m.telegram.tokenFile,
            ] as [String: Any?],
            "options": [
                "mirrorOwnMessages": m.mirrorOwnMessages, "telegramReactionMode": m.reactionMode.rawValue,
                "outboxDirectory": m.relay?.outboxDirectory,
            ] as [String: Any?],
        ]
    }
}

/// `bluehop status` 의 매핑 하나. 상태 DB 만 읽는다(chat.db·네트워크 안 씀).
public struct MappingStatus {
    public var id: String
    public var enabled: Bool
    public var health: StateStore.Health

    public init(id: String, enabled: Bool, health: StateStore.Health) {
        self.id = id
        self.enabled = enabled
        self.health = health
    }

    /// 텔레그램 확인이 이보다 오래되면 "멈춘 것 같음"으로 본다.
    public static let staleAfter: Double = 120

    /// ok · paused · halted · error · stale · unknown
    public func verdict(now: Double) -> String {
        if !enabled { return "paused" }
        if health.halted != nil { return "halted" }
        if let at = health.lastErrorAt, health.lastError != nil, now - at < 600 { return "error" }
        guard let ok = health.lastTelegramOK else { return "unknown" }
        return now - ok > Self.staleAfter ? "stale" : "ok"
    }

    public func json(now: Double) -> [String: Any?] {
        [
            "id": id, "enabled": enabled, "verdict": verdict(now: now),
            "workerState": health.state, "halted": health.halted,
            "lastTelegramPollAt": health.lastTelegramOK.map(JSONOut.iso),
            "lastIMessageScanAt": health.lastIMessageScan.map(JSONOut.iso),
            "lastError": health.lastError, "lastErrorAt": health.lastErrorAt.map(JSONOut.iso),
            "lastErrorCode": health.lastError == nil ? nil : (health.lastErrorCode ?? ErrorCodes.unknown),
        ]
    }
}

/// `bluehop status` 의 사람이 읽는 줄(한국어 기본, `--lang en` 이면 영어).
public enum StatusText {
    public static func lines(service: ServiceState, rows: [MappingStatus], now: Double, lang: OutputLanguage) -> [String] {
        var out: [String] = []
        let pid = service.pid.map(String.init) ?? "?"
        switch lang {
        case .ko:
            out.append("서비스 \(Paths.launchAgentLabel): \(service.running ? "실행 중 (pid \(pid))" : service.loaded ? "등록됨, 멈춤" : "등록 안 됨")")
            if rows.isEmpty { out.append("매핑이 없습니다. 추가: bluehop mapping add") }
        case .en:
            out.append("service \(Paths.launchAgentLabel): \(service.running ? "running (pid \(pid))" : service.loaded ? "loaded, not running" : "not loaded")")
            if rows.isEmpty { out.append("No mappings. Add one: bluehop mapping add") }
        }
        for r in rows {
            let h = r.health
            var line = "[\(r.id)] \(r.verdict(now: now))"
            switch lang {
            case .ko:
                if let t = h.lastTelegramOK { line += " · 텔레그램 확인 \(Int(now - t))초 전" }
                if let reason = h.halted { line += " · 정지: \(reason)" }
                if let e = h.lastError { line += " · 오류: \(e)" }
            case .en:
                if let t = h.lastTelegramOK { line += " · last Telegram poll \(Int(now - t))s ago" }
                if h.halted != nil { line += " · safety halt (reason in Korean: run with --json)" }
                if h.lastError != nil {
                    let code = h.lastErrorCode ?? ErrorCodes.unknown
                    line += " · error [\(code)]: \(ErrorCodes.message(code))"
                }
            }
            out.append(line)
        }
        return out
    }

    /// 로그 파일 위치 한 줄(사람이 읽는 `status` 출력에 붙인다 — `--json` 은 `logs` 키).
    public static func logsLine(lang: OutputLanguage) -> String {
        let level = "\(EventLog.levelFromEnvironment())"
        switch lang {
        case .ko: return "로그: \(Paths.textLogFile) · 사건(JSONL) \(Paths.eventLogFile) [\(level)]"
        case .en: return "logs: \(Paths.textLogFile) · events (JSONL) \(Paths.eventLogFile) [\(level)]"
        }
    }
}

/// LaunchAgent 가 도는지(`launchctl print` 출력에서 state·pid 만 읽는다).
public struct ServiceState: Equatable {
    public var loaded: Bool
    public var running: Bool
    public var pid: Int?

    public static func parse(launchctlPrint out: String, exitStatus: Int32) -> ServiceState {
        guard exitStatus == 0 else { return ServiceState(loaded: false, running: false, pid: nil) }
        var running = false
        var pid: Int?
        // 서비스 자신의 속성은 `<label> = {` 바로 안(깊이 1)에만 있다. 그 안의 하위 블록
        // (`resource coalition = { state = active … }` 등)에도 `state =`·`pid =` 줄이 있으므로
        // 깊이를 세어 그 줄들은 건너뛴다 — 안 그러면 마지막 하위 블록 값이 최상위 판정을 덮는다.
        var depth = 0
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "}" { depth = max(0, depth - 1); continue }
            if t.hasSuffix("{") { depth += 1; continue }
            guard depth <= 1 else { continue }
            if t.hasPrefix("state = ") { running = t == "state = running" }
            if t.hasPrefix("pid = "), pid == nil { pid = Int(t.dropFirst(6)) }
        }
        return ServiceState(loaded: true, running: running, pid: running ? pid : nil)
    }

    public static func current(label: String = Paths.launchAgentLabel) -> ServiceState {
        guard let r = try? ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 10) else {
            return ServiceState(loaded: false, running: false, pid: nil)
        }
        return parse(launchctlPrint: r.stdout, exitStatus: r.status)
    }
}

/// 설치된 바이너리를 launchd 일회성 작업으로 실행한다. 터미널에서 바로 실행하면 macOS 가 전체 디스크 접근을
/// 터미널 앱의 것으로 판단하므로, chat.db 읽기만 이 길로 다시 돌린다(`scripts/agent-run.sh` 와 같은 방식).
public enum LaunchdOneShot {
    /// 이 값이 있으면 일회성 작업 안이다(다시 넘기지 않는다).
    public static let envMarker = "BLUEHOP_ONESHOT"

    public static var isInsideOneShot: Bool { ProcessInfo.processInfo.environment[envMarker] == "1" }

    public static func plist(label: String, binary: String, args: [String], output: String) throws -> Data {
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary] + args,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": output,
            "StandardErrorPath": output + ".err",
            "EnvironmentVariables": [envMarker: "1"],
            "Umask": 63,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public struct Result { public var status: Int32; public var stdout: String; public var stderr: String }

    public static func run(binary: String = Paths.installedBinary, args: [String], timeout: Double = 90) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw CLIError(.failure, "설치된 바이너리가 없습니다: \(binary) (scripts/install.sh)")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("bluehop-oneshot-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let label = "\(Paths.launchAgentLabel).oneshot.\(getpid())"
        let domain = "gui/\(getuid())"
        let out = work.appendingPathComponent("out.log").path
        let plistPath = work.appendingPathComponent("\(label).plist").path
        try plist(label: label, binary: binary, args: args, output: out).write(to: URL(fileURLWithPath: plistPath))
        _ = try? ProcessRunner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 10)
        let boot = try ProcessRunner.run("/bin/launchctl", ["bootstrap", domain, plistPath], timeout: 20)
        guard boot.status == 0 else { throw CLIError(.failure, "launchctl bootstrap 실패: \(boot.stderr.prefix(200))") }
        defer { _ = try? ProcessRunner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 10) }
        let deadline = Date().addingTimeInterval(timeout)
        var exit: Int32?
        while Date() < deadline {
            let p = (try? ProcessRunner.run("/bin/launchctl", ["print", "\(domain)/\(label)"], timeout: 10))?.stdout ?? ""
            if p.contains("state = not running"), let line = p.split(separator: "\n").first(where: { $0.contains("last exit code") }) {
                exit = Int32(line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 1
                break
            }
            usleep(300_000)
        }
        guard let exit else { throw CLIError(.timeout, "launchd 일회성 작업이 \(Int(timeout))초 안에 끝나지 않았습니다") }
        let o = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        let e = (try? String(contentsOfFile: out + ".err", encoding: .utf8)) ?? ""
        return Result(status: exit, stdout: o, stderr: e)
    }
}
