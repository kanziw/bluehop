import Foundation

/// 사람이 읽는 출력의 언어. 기본은 한국어(`ko`). `--lang en` 이나 환경 변수 `BLUEHOP_LANG=en` 이면 영어.
/// `--json` 의 키·코드·verdict 는 언어와 상관없이 늘 같다.
public enum OutputLanguage: String {
    case ko, en

    public static let envKey = "BLUEHOP_LANG"

    /// `--lang` 값이 먼저, 없으면 환경 변수, 둘 다 없으면 한국어. 모르는 값은 사용법 오류(2).
    public static func resolve(flag: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> OutputLanguage {
        if let flag {
            guard let l = parse(flag) else { throw CLIError(.usage, "--lang 값은 ko 또는 en: \(flag)") }
            return l
        }
        if let env = environment[envKey], !env.isEmpty {
            guard let l = parse(env) else { throw CLIError(.usage, "\(envKey) 값은 ko 또는 en: \(env)") }
            return l
        }
        return .ko
    }

    static func parse(_ s: String) -> OutputLanguage? {
        switch s.lowercased() {
        case "ko", "ko_kr", "ko-kr", "kr": return .ko
        case "en", "en_us", "en-us", "en_gb", "en-gb": return .en
        default: return nil
        }
    }
}

/// 점검 실패 하나. `code` 는 `ErrorCodes.catalog` 의 키다.
public struct CheckFailure: Error, CustomStringConvertible {
    public var code: String
    public var message: String
    public var description: String { message }
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// `doctor --json`·`mapping test --json` 의 check `code` 와 `status --json` 의 `lastErrorCode`.
/// 에이전트가 문구 대신 이 값으로 분기하도록 만든 안정된 계약이다: 코드의 이름과 뜻을 바꾸거나 지우는 것은
/// 깨지는 변경이고, 새 코드를 더하는 것은 깨지는 변경이 아니다(모르는 코드는 `UNKNOWN` 처럼 다룰 것).
/// 표는 README "Machine-readable checks" 와 docs/AGENT-GUIDE.md 에 그대로 실려 있다.
public enum ErrorCodes {
    public static let ok = "OK"
    public static let unknown = "UNKNOWN"

    /// 코드 → 영어 설명(사람이 읽는 `--lang en` 출력과 JSON `message` 에 쓴다).
    public static let catalog: [(code: String, message: String)] = [
        ("OK", "Check passed."),
        ("CONFIG_MISSING", "The config file does not exist. Add a mapping with `bluehop mapping add`."),
        ("CONFIG_PERMISSIONS", "The config file, token file or folder is readable by others. chmod 600 the file or 700 the folder."),
        ("CONFIG_INVALID", "The config file is not valid (JSON shape, unknown version, empty ids or a group chat guid)."),
        ("CONFIG_CONFLICT", "The config links one iMessage chat or one bot to two mappings."),
        ("MAPPING_NOT_FOUND", "No mapping with that id."),
        ("TOKEN_UNREADABLE", "The bot token could not be read (Keychain item or token file missing or not readable)."),
        ("TOKEN_FORMAT", "The bot token does not look like a Telegram bot token."),
        ("TOKEN_BOT_MISMATCH", "The token belongs to a different bot than the one recorded in the config."),
        ("CHATDB_UNREADABLE", "The Messages database could not be opened. Full Disk Access for the bluehop binary is probably missing."),
        ("CHAT_NOT_FOUND", "The configured iMessage chat guid is not in the Messages database."),
        ("CHAT_NOT_ONE_TO_ONE", "The configured chat is not a 1:1 chat. Group chats cannot be linked."),
        ("CHAT_HANDLE_MISMATCH", "The chat's participant differs from the configured handle."),
        ("MESSAGES_AUTOMATION_DENIED", "Automation permission for Messages is missing. Allow it in System Settings, Privacy & Security, Automation."),
        ("MESSAGES_CHAT_NOT_FOUND", "Messages.app does not know the configured chat."),
        ("MESSAGES_ERROR", "Asking Messages.app about the chat failed."),
        ("TELEGRAM_UNAUTHORIZED", "Telegram rejected the bot token (revoked or mistyped). Create a new token and add the mapping again."),
        ("TELEGRAM_CONFLICT", "Another program polls the same bot, or a webhook is set (HTTP 409)."),
        ("TELEGRAM_RATE_LIMITED", "Telegram asked to retry later (rate limit)."),
        ("TELEGRAM_NETWORK", "api.telegram.org could not be reached."),
        ("TELEGRAM_ERROR", "Telegram returned an error."),
        ("TELEGRAM_SKIPPED", "Skipped because the bot token could not be read."),
        ("UNKNOWN", "Unexpected error. See `detail`."),
    ]

    public static func message(_ code: String) -> String {
        catalog.first { $0.code == code }?.message ?? catalog.first { $0.code == unknown }!.message
    }

    /// 오류 → 코드. 모르는 오류는 `UNKNOWN`.
    public static func of(_ error: Error) -> String {
        switch error {
        case let e as CheckFailure: return e.code
        case let e as ConfigError:
            switch e {
            case .missing: return "CONFIG_MISSING"
            case .insecurePermissions: return "CONFIG_PERMISSIONS"
            case .invalid: return "CONFIG_INVALID"
            case .conflict: return "CONFIG_CONFLICT"
            case .token: return "TOKEN_UNREADABLE"
            case .tokenFormat: return "TOKEN_FORMAT"
            case .botMismatch: return "TOKEN_BOT_MISMATCH"
            }
        case let e as ChatDBError:
            switch e {
            case .chatNotFound: return "CHAT_NOT_FOUND"
            case .notOneToOne: return "CHAT_NOT_ONE_TO_ONE"
            case .handleMismatch: return "CHAT_HANDLE_MISMATCH"
            }
        case is SQLiteError: return "CHATDB_UNREADABLE"
        case let e as TelegramError:
            switch e {
            case .api(_, let code, _) where code == 401 || code == 404: return "TELEGRAM_UNAUTHORIZED"
            case .api(_, 409, _): return "TELEGRAM_CONFLICT"
            case .retryAfter: return "TELEGRAM_RATE_LIMITED"
            case .network: return "TELEGRAM_NETWORK"
            default: return "TELEGRAM_ERROR"
            }
        case let e as SendError:
            return e.description.contains("-1743") ? "MESSAGES_AUTOMATION_DENIED" : "MESSAGES_ERROR"
        case let e as CLIError where e.code == .notFound: return "MAPPING_NOT_FOUND"
        default: return unknown
        }
    }
}

/// `doctor` 점검 한 줄의 모양(JSON). id 와 code 는 안정된 계약, name·detail 은 한국어, title·message 는 영어.
public enum DoctorCheck {
    /// check id → (한국어 이름, 영어 제목)
    public static let titles: [String: (ko: String, en: String)] = [
        "config": ("설정 파일 (0600)", "Config file (0600)"),
        "token": ("봇 토큰", "Bot token"),
        "chatdb": ("chat.db 읽기 전용 열기 + 대화 검증", "chat.db read-only open + chat check"),
        "messages": ("메시지 앱에 대화 존재 (자동 제어)", "Chat exists in Messages.app (Automation)"),
        "telegram": ("텔레그램 getMe", "Telegram getMe"),
    ]

    public static func passed(_ id: String, ko: String, en: String) -> [String: Any?] {
        ["id": id, "name": titles[id]?.ko ?? id, "title": titles[id]?.en ?? id, "ok": true,
         "code": ErrorCodes.ok, "detail": ko, "message": en]
    }

    public static func failed(_ id: String, _ error: Error) -> [String: Any?] {
        let code = ErrorCodes.of(error)
        return ["id": id, "name": titles[id]?.ko ?? id, "title": titles[id]?.en ?? id, "ok": false,
                "code": code, "detail": "\(error)", "message": ErrorCodes.message(code)]
    }

    /// 사람이 읽는 한 줄: "✔ 이름: 설명" 또는 영어로 "✘ Title [CODE]: message".
    public static func line(_ c: [String: Any], lang: OutputLanguage) -> String {
        let ok = (c["ok"] as? Bool) == true
        let mark = ok ? "✔" : "✘"
        switch lang {
        case .ko:
            return "\(mark) \(c["name"] as? String ?? ""): \(c["detail"] as? String ?? "")"
        case .en:
            let code = (c["code"] as? String).map { ok ? "" : " [\($0)]" } ?? ""
            return "\(mark) \(c["title"] as? String ?? c["name"] as? String ?? "")\(code): \(c["message"] as? String ?? c["detail"] as? String ?? "")"
        }
    }

    /// 실패한 점검의 코드를 순서대로, 겹치지 않게.
    public static func failingCodes(_ checks: [[String: Any?]]) -> [String] {
        var seen = Set<String>()
        return checks.compactMap { c -> String? in
            guard (c["ok"] as? Bool) != true, let code = c["code"] as? String, seen.insert(code).inserted else { return nil }
            return code
        }
    }
}
