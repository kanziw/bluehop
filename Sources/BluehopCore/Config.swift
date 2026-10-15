import Foundation
import Security

public enum ReactionMode: String, Codable { case ignore, text }

/// 0.4.x 의 단일 대화 설정(버전 표시 없음). 읽을 때만 쓰고, 읽으면 id `default` 매핑 하나로 바꾼다.
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
        public init(chatGuid: String, handle: String) {
            self.chatGuid = chatGuid
            self.handle = handle
        }
    }
    public struct Relay: Codable, Equatable {
        public var mirrorOwnMessages: Bool?
        public var telegramReactionMode: ReactionMode?
        public var outboxDirectory: String?
        public init(mirrorOwnMessages: Bool? = nil, telegramReactionMode: ReactionMode? = nil, outboxDirectory: String? = nil) {
            self.mirrorOwnMessages = mirrorOwnMessages
            self.telegramReactionMode = telegramReactionMode
            self.outboxDirectory = outboxDirectory
        }
    }
    public var telegram: Telegram
    public var imessage: IMessage
    public var relay: Relay?
}

/// 대화 하나(iMessage 1:1 ↔ 텔레그램 봇 방 하나)의 설정. 봇 토큰도 매핑마다 따로다.
public struct MappingConfig: Codable, Equatable {
    public struct Telegram: Codable, Equatable {
        public var chatId: Int64
        public var allowedUserId: Int64
        /// 토큰의 `:` 앞 숫자(getMe 의 id). 비밀이 아니고, 토큰을 읽지 않고도 "봇 하나에 매핑 하나"를 지키게 한다.
        public var botId: Int64?
        public var botUsername: String?
        /// "keychain" | "file"
        public var tokenSource: String
        /// Keychain 계정(서비스 `dev.kanziw.bluehop`). 비어 있으면 `bot-token:<id>`.
        public var tokenAccount: String?
        public var tokenFile: String?

        public init(chatId: Int64, allowedUserId: Int64, botId: Int64? = nil, botUsername: String? = nil,
                    tokenSource: String = "keychain", tokenAccount: String? = nil, tokenFile: String? = nil) {
            self.chatId = chatId
            self.allowedUserId = allowedUserId
            self.botId = botId
            self.botUsername = botUsername
            self.tokenSource = tokenSource
            self.tokenAccount = tokenAccount
            self.tokenFile = tokenFile
        }
    }

    public var id: String
    /// false 면 멈춘 매핑 — 일꾼을 아예 띄우지 않는다(텔레그램도 iMessage 도 안 읽음).
    public var enabled: Bool
    public var telegram: Telegram
    public var imessage: RelayConfig.IMessage
    public var relay: RelayConfig.Relay?

    public init(id: String, enabled: Bool = true, telegram: Telegram, imessage: RelayConfig.IMessage, relay: RelayConfig.Relay? = nil) {
        self.id = id
        self.enabled = enabled
        self.telegram = telegram
        self.imessage = imessage
        self.relay = relay
    }

    enum CodingKeys: String, CodingKey { case id, enabled, telegram, imessage, relay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        telegram = try c.decode(Telegram.self, forKey: .telegram)
        imessage = try c.decode(RelayConfig.IMessage.self, forKey: .imessage)
        relay = try c.decodeIfPresent(RelayConfig.Relay.self, forKey: .relay)
    }

    public var mirrorOwnMessages: Bool { relay?.mirrorOwnMessages ?? true }
    public var reactionMode: ReactionMode { relay?.telegramReactionMode ?? .ignore }

    /// 이 매핑의 봇 토큰이 든 Keychain 계정.
    public var keychainAccount: String { telegram.tokenAccount ?? MappingConfig.defaultTokenAccount(id) }

    public static func defaultTokenAccount(_ id: String) -> String { "bot-token:\(id)" }

    /// 0.4.x 설정을 매핑으로 바꿀 때 쓰는 id. 토큰은 옛 Keychain 계정을 그대로 쓴다.
    public static let legacyID = "default"
}

/// 설정 파일 전체(버전 2): 매핑 목록.
public struct BluehopConfig: Codable, Equatable {
    public static let currentVersion = 2
    public var version: Int
    public var mappings: [MappingConfig]

    public init(version: Int = BluehopConfig.currentVersion, mappings: [MappingConfig]) {
        self.version = version
        self.mappings = mappings
    }

    public func mapping(_ id: String) -> MappingConfig? { mappings.first { $0.id == id } }
    public var enabledMappings: [MappingConfig] { mappings.filter(\.enabled) }

    /// 0.4.x 단일 설정 → 매핑 하나(`default`, 옛 Keychain 계정).
    public static func fromLegacy(_ c: RelayConfig) -> BluehopConfig {
        let tg = MappingConfig.Telegram(chatId: c.telegram.chatId, allowedUserId: c.telegram.allowedUserId,
                                        tokenSource: c.telegram.tokenSource,
                                        tokenAccount: c.telegram.tokenSource == "keychain" ? Paths.legacyKeychainAccount : nil,
                                        tokenFile: c.telegram.tokenFile)
        return BluehopConfig(version: currentVersion,
                             mappings: [MappingConfig(id: MappingConfig.legacyID, telegram: tg, imessage: c.imessage, relay: c.relay)])
    }
}

/// 읽은 설정과 그 출처. `legacy` 면 파일은 아직 0.4.x 모양이다(쓰기 전에 옮겨야 함).
public struct LoadedConfig {
    public var config: BluehopConfig
    public var legacy: Bool
    public var path: String
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    case insecurePermissions(path: String, mode: Int)
    case invalid(String)
    case token(String)
    /// 봇 토큰 모양이 아니다(`<숫자>:<영문·숫자·_->`).
    case tokenFormat
    /// 토큰의 봇이 설정에 기록된 봇(botId)과 다르다.
    case botMismatch(got: Int64, want: Int64)
    /// 매핑끼리 겹친다(같은 대화·같은 봇·같은 id). CLI 는 종료 코드 3 으로 알린다.
    case conflict(String)

    public var description: String {
        switch self {
        case .missing(let p): return "파일 없음: \(p)"
        case .insecurePermissions(let p, let m):
            return "권한이 너무 넓다: \(p) (\(String(m, radix: 8))). chmod 600(파일)/700(폴더) 후 다시 실행"
        case .invalid(let m): return "설정 오류: \(m)"
        case .token(let m): return "봇 토큰: \(m)"
        case .tokenFormat: return "봇 토큰: 형식이 맞지 않다"
        case .botMismatch(let got, let want): return "봇 토큰: 토큰의 봇(id \(got))이 설정의 botId(\(want))와 다르다"
        case .conflict(let m): return "매핑 충돌: \(m)"
        }
    }
}

public enum Paths {
    public static var home: String { NSHomeDirectory() }
    public static var supportDir: String { home + "/Library/Application Support/bluehop" }
    public static var configFile: String { supportDir + "/config.json" }
    public static var stateFile: String { supportDir + "/state.sqlite" }
    public static var tmpDir: String { supportDir + "/tmp" }
    /// 설치 위치의 바이너리. Keychain 항목이 이 바이너리를 믿게 하고, 전체 디스크 접근이 필요한 읽기를 launchd 로 돌릴 때 쓴다.
    public static var installedBinary: String { supportDir + "/bin/bluehop" }
    /// 텔레그램에서 받은 첨부를 보내기 전에 두는 곳. 메시지 앱(샌드박스)이 읽을 수 있는 폴더여야 한다 —
    /// `MessagesSandbox` 참고. `~/Library/Messages` 에는 쓰지 않으므로 그 옆의 메시지 앱 캐시 폴더를 쓴다.
    /// 매핑마다 그 아래 `<매핑 id>/` 폴더를 쓴다(텔레그램 message_id 는 봇마다 겹칠 수 있음).
    public static var defaultOutboxDir: String { home + "/Library/Caches/com.apple.MobileSMS/bluehop-outbox" }
    public static var chatDB: String { home + "/Library/Messages/chat.db" }
    public static var attachmentsRoot: String { home + "/Library/Messages/Attachments" }
    /// launchd 가 stdout·stderr 를 받아 적는 사람이 읽는 줄(`packaging/*.plist.template` 의 `StandardOutPath`).
    /// 이 파일은 bluehop 이 아니라 launchd 가 적으므로 스스로 돌지 않는다.
    public static var textLogFile: String { home + "/Library/Logs/bluehop.log" }
    /// 요청 하나(텔레그램 업데이트·메시지, iMessage 행)가 거친 단계를 한 줄씩 담는 구조화(JSON Lines) 로그.
    /// bluehop 이 직접 열고 크기 기준으로 스스로 돈다(`RotatingFileLog`) — 위 텍스트 로그와는 다른 파일.
    public static var eventLogFile: String { home + "/Library/Logs/bluehop-events.jsonl" }
    public static let keychainService = "dev.kanziw.bluehop"
    /// 0.4.x 의 단일 봇 토큰 계정. 옮겨 온 `default` 매핑이 계속 쓴다.
    public static let legacyKeychainAccount = "telegram-bot-token"
    public static let launchAgentLabel = "dev.kanziw.bluehop"

    /// 설정 파일과 같은 폴더의 상태 DB.
    public static func stateFile(forConfig config: String) -> String {
        ((config as NSString).deletingLastPathComponent as NSString).appendingPathComponent("state.sqlite")
    }
}

/// 매핑 목록이 지켜야 하는 규칙. 읽을 때와 쓰기 전에 모두 검사한다.
public enum MappingRules {
    /// 글자로 시작한다 — 보낼 첨부 폴더 아래 숫자 이름 폴더(0.4.x 의 텔레그램 message_id 폴더)와 겹치지 않게.
    public static let idPattern = #"^[a-z][a-z0-9-]{0,31}$"#

    public static func isValidID(_ id: String) -> Bool {
        id.range(of: idPattern, options: .regularExpression) != nil
    }

    /// 봇 이름 같은 글에서 매핑 id 후보를 만든다(소문자·숫자·`-`, 32자 이하). 끝의 `bot` 은 뗀다.
    public static func slug(_ s: String) -> String {
        var t = s.lowercased()
        for suffix in ["_bot", "-bot", "bot"] where t.hasSuffix(suffix) && t.count > suffix.count {
            t = String(t.dropLast(suffix.count)); break
        }
        var out = ""
        for ch in t {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if !out.hasSuffix("-") && !out.isEmpty { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if let first = out.first, !first.isLetter { out = "chat-" + out }
        var cut = String(out.prefix(32))
        while cut.hasSuffix("-") { cut.removeLast() }
        return isValidID(cut) ? cut : "chat"
    }

    /// 이미 쓰는 id 와 겹치지 않게 `-2`, `-3` … 을 붙인다.
    public static func uniqueID(_ base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base.prefix(29))-\(n)") { n += 1 }
        return "\(base.prefix(29))-\(n)"
    }

    /// 대화 참가자 handle 을 비교용으로 접는다(대소문자·공백·`-`·괄호 무시).
    public static func normalizeHandle(_ h: String) -> String {
        h.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "(" && $0 != ")" }
    }

    /// 토큰 파일 경로를 비교용으로 펼친다.
    static func tokenIdentity(_ m: MappingConfig) -> String {
        if m.telegram.tokenSource == "file" {
            let p = ((m.telegram.tokenFile ?? "") as NSString).expandingTildeInPath
            return "file:" + (p as NSString).standardizingPath
        }
        return "keychain:" + m.keychainAccount
    }

    /// 매핑 하나만 보고 판단할 수 있는 규칙.
    public static func validate(_ m: MappingConfig) throws {
        guard isValidID(m.id) else {
            throw ConfigError.invalid("매핑 id '\(m.id)' 는 소문자로 시작하고 소문자·숫자·'-' 로 32자 이하여야 한다")
        }
        let c = m.telegram
        guard c.chatId != 0 else { throw ConfigError.invalid("[\(m.id)] telegram.chatId 가 비었다") }
        guard c.allowedUserId > 0 else { throw ConfigError.invalid("[\(m.id)] telegram.allowedUserId 가 비었다") }
        guard ["keychain", "file"].contains(c.tokenSource) else {
            throw ConfigError.invalid("[\(m.id)] telegram.tokenSource 는 keychain 또는 file")
        }
        if c.tokenSource == "file" && (c.tokenFile ?? "").isEmpty {
            throw ConfigError.invalid("[\(m.id)] tokenSource=file 이면 telegram.tokenFile 이 필요하다")
        }
        if let a = c.tokenAccount, a.isEmpty { throw ConfigError.invalid("[\(m.id)] telegram.tokenAccount 가 빈 글이다") }
        guard m.imessage.chatGuid.contains(";-;") else {
            throw ConfigError.invalid("[\(m.id)] imessage.chatGuid 는 1:1 대화 형식(…;-;…)이어야 한다 (단체방 ;+; 금지)")
        }
        guard !m.imessage.handle.isEmpty else { throw ConfigError.invalid("[\(m.id)] imessage.handle 이 비었다") }
    }

    /// 매핑끼리의 충돌. 앞에 있는 매핑이 이긴다(메시지는 뒤 매핑을 가리킨다).
    /// - 같은 id
    /// - 같은 iMessage 대화(같은 chatGuid, 또는 같은 상대 handle)
    /// - 같은 봇 토큰(같은 Keychain 계정·토큰 파일, 또는 같은 botId). getUpdates 는 토큰마다 소비자가 하나뿐이다.
    ///   (봇, 텔레그램 방) 쌍의 유일성은 이 규칙에 포함된다.
    public static func conflicts(_ mappings: [MappingConfig]) -> [String] {
        var out: [String] = []
        var ids = Set<String>()
        var chatOwner: [String: String] = [:]
        var tokenOwner: [String: String] = [:]
        var botOwner: [Int64: (id: String, chatId: Int64)] = [:]
        for m in mappings {
            guard ids.insert(m.id).inserted else { out.append("id '\(m.id)' 가 두 번 나온다"); continue }
            let guidKey = "g:" + m.imessage.chatGuid
            let handleKey = "h:" + normalizeHandle(m.imessage.handle)
            if let o = chatOwner[guidKey] {
                out.append("[\(m.id)] iMessage 대화가 매핑 '\(o)' 와 같다")
            } else if let o = chatOwner[handleKey] {
                out.append("[\(m.id)] iMessage 상대(handle)가 매핑 '\(o)' 와 같다")
            }
            chatOwner[guidKey] = chatOwner[guidKey] ?? m.id
            chatOwner[handleKey] = chatOwner[handleKey] ?? m.id

            let tok = tokenIdentity(m)
            if let o = tokenOwner[tok] {
                out.append("[\(m.id)] 봇 토큰(\(tok.hasPrefix("file:") ? "같은 토큰 파일" : "같은 Keychain 계정"))이 매핑 '\(o)' 와 같다")
            } else {
                tokenOwner[tok] = m.id
            }
            if let b = m.telegram.botId {
                if let o = botOwner[b] {
                    let pair = o.chatId == m.telegram.chatId ? ", (봇, 텔레그램 방) 쌍도 같다" : ""
                    out.append("[\(m.id)] 봇(id \(b))이 매핑 '\(o.id)' 와 같다\(pair) — 봇 하나는 매핑 하나에만 쓸 수 있다")
                } else {
                    botOwner[b] = (m.id, m.telegram.chatId)
                }
            }
        }
        return out
    }

    public static func validate(_ c: BluehopConfig) throws {
        guard c.version == BluehopConfig.currentVersion else {
            throw ConfigError.invalid("알 수 없는 설정 버전 \(c.version) (이 bluehop 은 \(BluehopConfig.currentVersion))")
        }
        for m in c.mappings { try validate(m) }
        let found = conflicts(c.mappings)
        if !found.isEmpty { throw ConfigError.conflict(found.joined(separator: "; ")) }
    }
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

    /// 설정을 읽고 검사한다. 0.4.x 모양이면 매핑 `default` 하나로 읽는다(파일은 바꾸지 않음).
    public static func load(path: String = Paths.configFile) throws -> BluehopConfig {
        try loadFile(path: path).config
    }

    public static func loadFile(path: String = Paths.configFile) throws -> LoadedConfig {
        guard FileManager.default.fileExists(atPath: path) else { throw ConfigError.missing(path) }
        try checkPrivate((path as NSString).deletingLastPathComponent, maxMode: 0o700)
        try checkPrivate(path, maxMode: 0o600)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let (cfg, legacy) = try decode(data)
        try MappingRules.validate(cfg)
        return LoadedConfig(config: cfg, legacy: legacy, path: path)
    }

    /// JSON → 설정. `mappings` 가 있으면 버전 2, 없고 `telegram` 이 있으면 0.4.x.
    public static func decode(_ data: Data) throws -> (BluehopConfig, legacy: Bool) {
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) } catch {
            throw ConfigError.invalid("JSON 해석 실패: \(error.localizedDescription)")
        }
        guard let dict = obj as? [String: Any] else { throw ConfigError.invalid("최상위가 JSON 객체가 아니다") }
        do {
            if dict["mappings"] != nil {
                return (try JSONDecoder().decode(BluehopConfig.self, from: data), false)
            }
            if dict["telegram"] != nil {
                return (BluehopConfig.fromLegacy(try JSONDecoder().decode(RelayConfig.self, from: data)), true)
            }
        } catch let e as DecodingError {
            throw ConfigError.invalid("JSON 모양이 맞지 않다: \(describe(e))")
        }
        throw ConfigError.invalid("mappings 가 없다")
    }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .keyNotFound(let k, let ctx): return "키 없음 \((ctx.codingPath + [k]).map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "값이 맞지 않음 \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default: return "\(e)"
        }
    }

    public static func encode(_ c: BluehopConfig) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try enc.encode(c)
        data.append(0x0A)
        return data
    }

    /// 백업 파일 이름(0.4.x 설정을 처음 옮길 때 한 번 만든다).
    public static func legacyBackupPath(_ path: String) -> String { path + ".v1-backup" }

    /// 설정을 쓴다: 검사 → (0.4.x 모양이면 백업 한 번) → 같은 폴더의 0600 임시 파일 → rename.
    /// - Returns: 이번에 만든 백업 경로(없으면 nil).
    @discardableResult
    public static func save(_ c: BluehopConfig, path: String = Paths.configFile) throws -> String? {
        try MappingRules.validate(c)
        let dir = (path as NSString).deletingLastPathComponent
        try ensurePrivateDir(dir)
        let fm = FileManager.default
        var backup: String?
        if fm.fileExists(atPath: path) {
            let (_, legacy) = try decode(try Data(contentsOf: URL(fileURLWithPath: path)))
            let b = legacyBackupPath(path)
            if legacy && !fm.fileExists(atPath: b) {
                try fm.copyItem(atPath: path, toPath: b)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: b)
                backup = b
            }
        }
        let tmp = (dir as NSString).appendingPathComponent(".config.json.\(getpid()).tmp")
        guard fm.createFile(atPath: tmp, contents: try encode(c), attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError.invalid("임시 파일을 쓰지 못함: \(tmp)")
        }
        guard rename(tmp, path) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            throw ConfigError.invalid("설정 파일 교체 실패: \(err)")
        }
        return backup
    }

    // MARK: 봇 토큰

    public static func loadToken(_ m: MappingConfig) throws -> String {
        try loadToken(source: m.telegram.tokenSource, file: m.telegram.tokenFile, account: m.keychainAccount)
    }

    public static func loadToken(source: String, file: String?, account: String = Paths.legacyKeychainAccount) throws -> String {
        let raw: String
        if source == "file" {
            guard let file else { throw ConfigError.invalid("tokenFile 이 필요하다") }
            let p = (file as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: p) else { throw ConfigError.missing(p) }
            try checkPrivate(p, maxMode: 0o600)
            raw = try String(contentsOfFile: p, encoding: .utf8)
        } else {
            raw = try keychainToken(account: account)
        }
        return try validateToken(raw)
    }

    /// 봇 토큰 형식: <숫자>:<영문·숫자·_-> — 경로 조작 문자가 끼지 않게 확인한다. 앞뒤 공백은 지운다.
    public static func validateToken(_ raw: String) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.range(of: #"^[0-9]{5,}:[A-Za-z0-9_-]{20,}$"#, options: .regularExpression) != nil else {
            throw ConfigError.tokenFormat
        }
        return token
    }

    /// 토큰의 봇 id(`:` 앞 숫자). 비밀이 아니다.
    public static func botID(ofToken token: String) -> Int64? {
        token.split(separator: ":").first.flatMap { Int64($0) }
    }

    static func keychainToken(account: String) throws -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Paths.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        guard st == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
            throw ConfigError.token("Keychain(계정 \(account))에서 읽지 못함 (OSStatus \(st)). README '봇 토큰 넣기' 참고")
        }
        return s
    }
}
