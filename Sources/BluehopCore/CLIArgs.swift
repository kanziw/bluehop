import Foundation

/// 종료 코드. README·AGENT-GUIDE·SKILL.md 의 표와 같아야 한다.
public enum ExitCode: Int32 {
    case ok = 0
    /// 점검 실패·네트워크·Keychain 등 실행 중 실패
    case failure = 1
    /// 모르는 명령·옵션, 값 빠짐, 잘못된 값
    case usage = 2
    /// 매핑 규칙 충돌(같은 대화·같은 봇·같은 id)
    case conflict = 3
    /// 없는 매핑 id·대화
    case notFound = 4
    /// 텔레그램 메시지를 기다리다 시간 초과
    case timeout = 5
    /// 사용자가 취소(Esc·Ctrl-C)
    case cancelled = 130
}

/// CLI 오류. `kind` 는 `--json` 출력의 error.kind 로 그대로 나간다.
public struct CLIError: Error, CustomStringConvertible {
    public var code: ExitCode
    public var message: String
    public var kind: String {
        switch code {
        case .ok: return "ok"
        case .failure: return "failure"
        case .usage: return "usage"
        case .conflict: return "conflict"
        case .notFound: return "not_found"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        }
    }
    public var description: String { message }
    public init(_ code: ExitCode, _ message: String) {
        self.code = code
        self.message = message
    }

    /// 다른 오류를 CLI 오류로 바꾼다(설정 충돌 → 3, 그 밖 → 1).
    public static func from(_ error: Error) -> CLIError {
        if let e = error as? CLIError { return e }
        if case ConfigError.conflict = error { return CLIError(.conflict, "\(error)") }
        return CLIError(.failure, "\(error)")
    }
}

public struct FlagSpec {
    public var name: String
    /// 값을 받는 옵션이면 값 이름(예: "ID"), 켜고 끄는 옵션이면 nil
    public var value: String?
    public var help: String
    public init(_ name: String, value: String? = nil, _ help: String) {
        self.name = name
        self.value = value
        self.help = help
    }
}

public struct CommandSpec {
    public var name: String
    public var summary: String
    /// 위치 인자 이름(예: ["ID"]). 이보다 많으면 오류.
    public var positionals: [String]
    /// 위치 인자가 꼭 있어야 하는 개수
    public var requiredPositionals: Int
    public var flags: [FlagSpec]
    public var details: String
    public var examples: [String]

    public init(_ name: String, _ summary: String, positionals: [String] = [], required: Int? = nil,
                flags: [FlagSpec] = [], details: String = "", examples: [String] = []) {
        self.name = name
        self.summary = summary
        self.positionals = positionals
        self.requiredPositionals = required ?? positionals.count
        self.flags = flags
        self.details = details
        self.examples = examples
    }

    public var usageLine: String {
        var parts = ["bluehop", name]
        parts += positionals.enumerated().map { i, p in i < requiredPositionals ? p : "[\(p)]" }
        if !flags.isEmpty { parts.append("[옵션]") }
        return parts.joined(separator: " ")
    }

    public func help(exitCodes: Bool = true) -> String {
        var out = "\(usageLine)\n\n\(summary)\n"
        if !details.isEmpty { out += "\n\(details)\n" }
        let all = flags + [FlagSpec("--help", "이 도움말")]
        out += "\n옵션:\n"
        let width = all.map { $0.name.count + ($0.value.map { $0.count + 1 } ?? 0) }.max() ?? 0
        for f in all {
            let left = f.name + (f.value.map { " " + $0 } ?? "")
            out += "  " + left.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + f.help + "\n"
        }
        if !examples.isEmpty {
            out += "\n예:\n" + examples.map { "  " + $0 }.joined(separator: "\n") + "\n"
        }
        if exitCodes { out += "\n" + CLIHelp.exitCodeTable }
        return out
    }
}

public struct ParsedArgs: Equatable {
    public var flags: [String: String] = [:]
    public var positionals: [String] = []
    public var wantsHelp = false

    public func has(_ name: String) -> Bool { flags[name] != nil }
    public func value(_ name: String) -> String? { flags[name] }

    /// 정수 값. 없으면 기본값, 숫자가 아니거나 범위 밖이면 사용법 오류.
    public func int(_ name: String, default d: Int, range: ClosedRange<Int>) throws -> Int {
        guard let v = flags[name] else { return d }
        guard let n = Int(v), range.contains(n) else {
            throw CLIError(.usage, "\(name) 값은 \(range.lowerBound)~\(range.upperBound) 사이 정수여야 합니다: \(v)")
        }
        return n
    }

    public func int64(_ name: String) throws -> Int64? {
        guard let v = flags[name] else { return nil }
        guard let n = Int64(v) else { throw CLIError(.usage, "\(name) 값은 정수여야 합니다: \(v)") }
        return n
    }
}

public enum ArgParser {
    /// `--flag value`, `--flag=value`, `--` 뒤는 모두 위치 인자. `-h`/`--help` 는 도움말.
    /// 모르는 옵션·남는 위치 인자·값 없는 옵션은 오류(종료 코드 2).
    public static func parse(_ args: [String], spec: CommandSpec) throws -> ParsedArgs {
        var out = ParsedArgs()
        let known = Dictionary(spec.flags.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var i = 0
        var onlyPositionals = false
        while i < args.count {
            let a = args[i]
            i += 1
            if !onlyPositionals && a == "--" { onlyPositionals = true; continue }
            if !onlyPositionals && (a == "--help" || a == "-h") { out.wantsHelp = true; continue }
            if !onlyPositionals && a.hasPrefix("-") && a != "-" {
                var name = a
                var inline: String?
                if let eq = a.firstIndex(of: "=") {
                    name = String(a[..<eq])
                    inline = String(a[a.index(after: eq)...])
                }
                guard let f = known[name] else {
                    throw CLIError(.usage, "모르는 옵션: \(name) (bluehop \(spec.name) --help 참고)")
                }
                if f.value != nil {
                    if let inline {
                        out.flags[name] = inline
                    } else {
                        guard i < args.count, !(args[i].hasPrefix("--") && args[i].count > 2) else {
                            throw CLIError(.usage, "\(name) 에 값(\(f.value!))이 필요합니다")
                        }
                        out.flags[name] = args[i]
                        i += 1
                    }
                } else {
                    guard inline == nil else { throw CLIError(.usage, "\(name) 는 값을 받지 않습니다") }
                    out.flags[name] = ""
                }
                continue
            }
            out.positionals.append(a)
        }
        if out.wantsHelp { return out }
        if out.positionals.count > spec.positionals.count {
            throw CLIError(.usage, "필요 없는 인자: \(out.positionals[spec.positionals.count...].joined(separator: " ")) (bluehop \(spec.name) --help 참고)")
        }
        if out.positionals.count < spec.requiredPositionals {
            let missing = spec.positionals[out.positionals.count..<spec.requiredPositionals].joined(separator: " ")
            throw CLIError(.usage, "인자가 빠졌습니다: \(missing) (bluehop \(spec.name) --help 참고)")
        }
        return out
    }
}

public enum CLIHelp {
    public static let exitCodeTable = """
        종료 코드: 0 성공 · 1 실패(점검 실패·네트워크·Keychain) · 2 사용법 오류(모르는 명령·옵션) · 3 충돌(같은 대화·같은 봇·같은 id)
                   4 없음(매핑 id·대화) · 5 시간 초과(텔레그램 메시지 기다림) · 130 사용자가 취소

        """
}
