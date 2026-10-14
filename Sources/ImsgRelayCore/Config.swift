import Foundation
import Security

public enum ReactionMode: String, Codable { case ignore, text }

public struct RelayConfig: Codable, Equatable {
    public struct Telegram: Codable, Equatable {
        public var chatId: Int64
        public var allowedUserId: Int64
        /// "keychain" | "file"
        public var tokenSource: String
        public var tokenFile: String?
    }
    public struct IMessage: Codable, Equatable {
        public var chatGuid: String
        public var handle: String
    }
    public struct Relay: Codable, Equatable {
        public var mirrorOwnMessages: Bool?
        public var telegramReactionMode: ReactionMode?
        public var outboxDirectory: String?
    }
    public var telegram: Telegram
    public var imessage: IMessage
    public var relay: Relay?

    public var mirrorOwnMessages: Bool { relay?.mirrorOwnMessages ?? true }
    public var reactionMode: ReactionMode { relay?.telegramReactionMode ?? .ignore }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    case insecurePermissions(path: String, mode: Int)
    case invalid(String)
    case token(String)

    public var description: String {
        switch self {
        case .missing(let p): return "파일 없음: \(p)"
        case .insecurePermissions(let p, let m):
            return "권한이 너무 넓다: \(p) (\(String(m, radix: 8))). chmod 600(파일)/700(폴더) 후 다시 실행"
        case .invalid(let m): return "설정 오류: \(m)"
        case .token(let m): return "봇 토큰: \(m)"
        }
    }
}

public enum Paths {
    public static var home: String { NSHomeDirectory() }
    public static var supportDir: String { home + "/Library/Application Support/imsg-relay" }
    public static var configFile: String { supportDir + "/config.json" }
    public static var stateFile: String { supportDir + "/state.sqlite" }
    public static var tmpDir: String { supportDir + "/tmp" }
    /// 텔레그램에서 받은 첨부를 보내기 전에 두는 곳. 메시지 앱(샌드박스)이 읽을 수 있는 폴더여야 한다 —
    /// `MessagesSandbox` 참고. `~/Library/Messages` 에는 쓰지 않으므로 그 옆의 메시지 앱 캐시 폴더를 쓴다.
    public static var defaultOutboxDir: String { home + "/Library/Caches/com.apple.MobileSMS/imsg-relay-outbox" }
    public static var chatDB: String { home + "/Library/Messages/chat.db" }
    public static var attachmentsRoot: String { home + "/Library/Messages/Attachments" }
    public static let keychainService = "dev.kanziw.imsg-relay"
    public static let keychainAccount = "telegram-bot-token"
}

public enum ConfigLoader {
    /// 그룹·기타 사용자 권한 비트가 하나라도 있으면 거부한다.
    public static func checkPrivate(_ path: String, maxMode: Int) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        if mode & ~maxMode & 0o777 != 0 || mode & 0o077 != 0 {
            throw ConfigError.insecurePermissions(path: path, mode: mode)
        }
        if let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value, owner != getuid() {
            throw ConfigError.invalid("\(path) 의 소유자가 현재 사용자가 아니다")
        }
    }

    public static func ensurePrivateDir(_ path: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try checkPrivate(path, maxMode: 0o700)
    }

    public static func load(path: String = Paths.configFile) throws -> RelayConfig {
        guard FileManager.default.fileExists(atPath: path) else { throw ConfigError.missing(path) }
        try checkPrivate((path as NSString).deletingLastPathComponent, maxMode: 0o700)
        try checkPrivate(path, maxMode: 0o600)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let cfg: RelayConfig
        do { cfg = try JSONDecoder().decode(RelayConfig.self, from: data) } catch {
            throw ConfigError.invalid("JSON 해석 실패: \(error)")
        }
        try validate(cfg)
        return cfg
    }

    public static func validate(_ c: RelayConfig) throws {
        guard c.telegram.chatId != 0 else { throw ConfigError.invalid("telegram.chatId 가 비었다") }
        guard c.telegram.allowedUserId > 0 else { throw ConfigError.invalid("telegram.allowedUserId 가 비었다") }
        guard ["keychain", "file"].contains(c.telegram.tokenSource) else {
            throw ConfigError.invalid("telegram.tokenSource 는 keychain 또는 file")
        }
        if c.telegram.tokenSource == "file" && (c.telegram.tokenFile ?? "").isEmpty {
            throw ConfigError.invalid("tokenSource=file 이면 telegram.tokenFile 이 필요하다")
        }
        guard c.imessage.chatGuid.contains(";-;") else {
            throw ConfigError.invalid("imessage.chatGuid 는 1:1 대화 형식(…;-;…)이어야 한다 (단체방 ;+; 금지)")
        }
        guard !c.imessage.handle.isEmpty else { throw ConfigError.invalid("imessage.handle 이 비었다") }
    }

    public static func loadToken(_ c: RelayConfig) throws -> String {
        try loadToken(source: c.telegram.tokenSource, file: c.telegram.tokenFile)
    }

    public static func loadToken(source: String, file: String?) throws -> String {
        let raw: String
        if source == "file" {
            guard let file else { throw ConfigError.invalid("tokenFile 이 필요하다") }
            let p = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: p) else { throw ConfigError.missing(p) }
            try checkPrivate(p, maxMode: 0o600)
            raw = try String(contentsOfFile: p, encoding: .utf8)
        } else {
            raw = try keychainToken()
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 봇 토큰 형식: <숫자>:<영문·숫자·_-> — 경로 조작 문자가 끼지 않게 확인한다.
        guard token.range(of: #"^[0-9]{5,}:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil else {
            throw ConfigError.token("형식이 맞지 않다")
        }
        return token
    }

    static func keychainToken() throws -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Paths.keychainService,
            kSecAttrAccount as String: Paths.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
            throw ConfigError.token("Keychain 에서 읽지 못함 (OSStatus \(st)). README '봇 토큰 넣기' 참고")
        }
        return s
    }
}
