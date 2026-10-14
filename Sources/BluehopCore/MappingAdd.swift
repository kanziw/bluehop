import Foundation
import Security

// MARK: - 봇 토큰 저장소

public protocol TokenStore: AnyObject {
    /// 토큰을 저장한다(같은 계정이 있으면 바꾼다).
    func save(token: String, account: String) throws
    /// 지웠으면 true, 원래 없었으면 false.
    @discardableResult func delete(account: String) throws -> Bool
}

/// macOS Keychain(서비스 `dev.kanziw.bluehop`). 저장은 `security -i` 에 표준입력으로 명령을 넘겨
/// 토큰이 argv(`ps`)에 보이지 않게 하고, `-T` 로 설치된 bluehop 과 지금 실행 중인 bluehop 을 믿을 앱으로 넣는다.
public final class KeychainTokenStore: TokenStore {
    public let trustedApps: [String]

    public init(trustedApps: [String] = KeychainTokenStore.defaultTrustedApps()) {
        self.trustedApps = trustedApps
    }

    /// 설치된 바이너리(있으면)와 지금 실행 중인 바이너리.
    public static func defaultTrustedApps() -> [String] {
        var apps: [String] = []
        if FileManager.default.isExecutableFile(atPath: Paths.installedBinary) { apps.append(Paths.installedBinary) }
        let me = (Bundle.main.executablePath.map { ($0 as NSString).resolvingSymlinksInPath }) ?? CommandLine.arguments[0]
        if !apps.contains(me) { apps.append(me) }
        return apps
    }

    /// `security -i` 한 줄 명령. 값에 따옴표·줄바꿈이 있으면 만들지 않는다(토큰·계정은 이미 형식 검사를 거친다).
    public static func addCommand(token: String, account: String, service: String, trusted: [String]) throws -> String {
        let unsafe = CharacterSet(charactersIn: "\"\\\n\r")
        for v in [token, account, service] + trusted where v.rangeOfCharacter(from: unsafe) != nil {
            throw ConfigError.invalid("Keychain 명령에 쓸 수 없는 문자가 있다")
        }
        var cmd = "add-generic-password -U -s \"\(service)\" -a \"\(account)\""
        for t in trusted { cmd += " -T \"\(t)\"" }
        cmd += " -w \"\(token)\"\n"
        return cmd
    }

    public func save(token: String, account: String) throws {
        let token = try ConfigLoader.validateToken(token)
        let cmd = try Self.addCommand(token: token, account: account, service: Paths.keychainService, trusted: trustedApps)
        let r = try ProcessRunner.run("/usr/bin/security", ["-i"], timeout: 60, stdin: Data(cmd.utf8))
        // security -i 는 명령이 실패해도 0 으로 끝날 수 있어 출력도 본다. 출력에는 토큰이 들어가지 않는다.
        let err = (r.stderr + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.status != 0 || !Self.exists(account: account) {
            throw ConfigError.token("Keychain 에 저장하지 못함 (security 종료 \(r.status)): \(err.prefix(200))")
        }
    }

    /// 항목이 있는지(속성만 본다 — 값을 읽지 않으므로 접근 허용 창이 뜨지 않는다).
    public static func exists(account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Paths.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    @discardableResult
    public func delete(account: String) throws -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Paths.keychainService,
            kSecAttrAccount as String: account,
        ]
        let st = SecItemDelete(q as CFDictionary)
        if st == errSecItemNotFound { return false }
        guard st == errSecSuccess else { throw ConfigError.token("Keychain 항목(계정 \(account))을 지우지 못함 (OSStatus \(st))") }
        return true
    }
}

// MARK: - 텔레그램 id 알아내기

public struct DetectedSender: Equatable {
    public var chatID: Int64
    public var userID: Int64
    public var name: String?
    public var date: Int64
}

public enum TelegramIDDetector {
    /// 봇에게 온 개인 대화 메시지 중 `maxAge` 초 안의 것만, 보낸 사람별로 하나씩(최근 순).
    /// 봇이 보낸 것·단체방·보낸 시각 없는 것은 뺀다.
    public static func candidates(_ messages: [TGMessage], now: Double, maxAge: Double) -> [DetectedSender] {
        var seen = Set<String>()
        var out: [DetectedSender] = []
        for m in messages.sorted(by: { ($0.date ?? 0) > ($1.date ?? 0) }) {
            guard let from = m.from, from.is_bot != true, let date = m.date else { continue }
            guard m.chat.type == nil || m.chat.type == "private" else { continue }
            guard now - Double(date) <= maxAge else { continue }
            let key = "\(m.chat.id)/\(from.id)"
            guard seen.insert(key).inserted else { continue }
            let name = from.username.map { "@" + $0 } ?? from.first_name
            out.append(DetectedSender(chatID: m.chat.id, userID: from.id, name: name, date: date))
        }
        return out
    }
}

// MARK: - 매핑 추가

/// 터미널에서 사람에게 묻는 부분. 사람이 없으면(에이전트·파이프) nil 을 넘기고, 그때 빠진 값은 오류가 된다.
public protocol AddInteraction: AnyObject {
    func pickChat(_ items: [ChatPicker.Item]) throws -> ChatPicker.Item
    func askID(suggested: String) throws -> String
    func confirmSender(_ s: DetectedSender, bot: String) throws -> Bool
}

public struct AddRequest {
    public var id: String?
    public var chat: String?
    public var token: String
    /// 토큰을 Keychain 대신 이 파일(0600)에 둔다.
    public var tokenFile: String?
    public var telegramChat: Int64?
    public var allowedUser: Int64?
    public var waitSeconds: Int = 120
    public var maxMessageAge: Double = 600
    public var dryRun = false

    public init(token: String) { self.token = token }
}

public struct AddResult {
    public var mapping: MappingConfig
    public var configBackup: String?
    public var dryRun: Bool
}

public final class MappingAdder {
    let configPath: String
    let tokens: TokenStore
    let telegramFor: (String) -> TelegramClient
    let chats: () throws -> [ChatDB.ChatSummary]
    let clock: Clock
    let interaction: AddInteraction?
    let progress: (String) -> Void

    public init(configPath: String, tokens: TokenStore, telegramFor: @escaping (String) -> TelegramClient,
                chats: @escaping () throws -> [ChatDB.ChatSummary], clock: Clock,
                interaction: AddInteraction?, progress: @escaping (String) -> Void) {
        self.configPath = configPath
        self.tokens = tokens
        self.telegramFor = telegramFor
        self.chats = chats
        self.clock = clock
        self.interaction = interaction
        self.progress = progress
    }

    /// 설정 파일이 없으면 빈 목록.
    public static func loadOrEmpty(_ path: String) throws -> BluehopConfig {
        guard FileManager.default.fileExists(atPath: path) else { return BluehopConfig(mappings: []) }
        return try ConfigLoader.load(path: path)
    }

    public func run(_ req: AddRequest) async throws -> AddResult {
        var cfg = try Self.loadOrEmpty(configPath)
        if let id = req.id { try checkID(id, in: cfg) }

        // 1) 토큰 → 봇
        let token = try ConfigLoader.validateToken(req.token)
        let tg = telegramFor(token)
        let bot: TelegramClient.BotInfo
        do { bot = try await tg.getMeInfo() } catch {
            throw CLIError(.failure, "봇 토큰 확인(getMe) 실패: \(error)")
        }
        progress("봇 확인: @\(bot.username) (id \(bot.id))")
        if let other = cfg.mappings.first(where: { $0.telegram.botId == bot.id }) {
            throw CLIError(.conflict, "봇 @\(bot.username) 은 이미 매핑 '\(other.id)' 가 쓴다 — 매핑마다 새 봇(@BotFather /newbot)이 필요합니다")
        }

        // 2) iMessage 대화
        let chat = try resolveChat(req.chat, cfg: cfg)
        progress("iMessage 대화: \(chat.handle)")

        // 3) 텔레그램 방·허용 사용자
        let (chatID, userID) = try await telegramIDs(req, tg: tg, bot: bot.username)

        // 4) id
        var id: String
        if let given = req.id {
            id = given
        } else {
            let suggested = MappingRules.uniqueID(MappingRules.slug(bot.username), taken: Set(cfg.mappings.map(\.id)))
            id = try interaction?.askID(suggested: suggested) ?? suggested
            try checkID(id, in: cfg)
        }

        // 5) 설정 조립·검사
        let useFile = req.tokenFile != nil
        let mapping = MappingConfig(
            id: id, enabled: true,
            telegram: MappingConfig.Telegram(chatId: chatID, allowedUserId: userID, botId: bot.id, botUsername: bot.username,
                                             tokenSource: useFile ? "file" : "keychain",
                                             tokenAccount: useFile ? nil : MappingConfig.defaultTokenAccount(id),
                                             tokenFile: req.tokenFile),
            imessage: RelayConfig.IMessage(chatGuid: chat.guid, handle: chat.handle))
        cfg.version = BluehopConfig.currentVersion
        cfg.mappings.append(mapping)
        do { try MappingRules.validate(cfg) } catch { throw CLIError.from(error) }
        if req.dryRun { return AddResult(mapping: mapping, configBackup: nil, dryRun: true) }

        // 6) 토큰 → 설정. 설정을 못 쓰면 방금 넣은 토큰을 지운다.
        if !useFile { try tokens.save(token: token, account: mapping.keychainAccount) }
        do {
            let backup = try ConfigLoader.save(cfg, path: configPath)
            return AddResult(mapping: mapping, configBackup: backup, dryRun: false)
        } catch {
            if !useFile { _ = try? tokens.delete(account: mapping.keychainAccount) }
            throw CLIError.from(error)
        }
    }

    func checkID(_ id: String, in cfg: BluehopConfig) throws {
        guard MappingRules.isValidID(id) else {
            throw CLIError(.usage, "매핑 id '\(id)' 는 소문자로 시작하고 소문자·숫자·'-' 로 32자 이하여야 합니다")
        }
        if cfg.mapping(id) != nil { throw CLIError(.conflict, "매핑 id '\(id)' 가 이미 있습니다") }
    }

    /// guid 또는 handle → 1:1 대화. 없으면 사람에게 고르게 하고, 사람이 없으면 사용법 오류.
    func resolveChat(_ query: String?, cfg: BluehopConfig) throws -> ChatDB.ChatSummary {
        let list: [ChatDB.ChatSummary]
        do { list = try chats() } catch {
            throw CLIError(.failure, "iMessage 대화 목록을 읽지 못함: \(error)")
        }
        let used = ChatListing.usage(cfg)
        func mappedTo(_ c: ChatDB.ChatSummary) -> String? {
            used.byGuid[c.guid] ?? used.byHandle[MappingRules.normalizeHandle(c.handle)]
        }
        if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            let found: ChatDB.ChatSummary?
            if q.contains(";-;") {
                found = list.first { $0.guid == q }
            } else if q.contains(";+;") {
                throw CLIError(.usage, "단체방은 묶을 수 없습니다(1:1 대화만)")
            } else {
                let n = MappingRules.normalizeHandle(q)
                found = list.first { MappingRules.normalizeHandle($0.handle) == n }  // 최근 순 목록의 첫 번째
            }
            guard let c = found else { throw CLIError(.notFound, "그 iMessage 1:1 대화를 찾지 못했습니다 (bluehop chats 로 확인)") }
            if let m = mappedTo(c) { throw CLIError(.conflict, "그 대화는 이미 매핑 '\(m)' 가 씁니다") }
            return c
        }
        guard let interaction else {
            throw CLIError(.usage, "--chat 이 필요합니다(터미널이 아니라 고를 수 없음). bluehop chats --json 으로 guid 를 찾으세요")
        }
        guard !list.isEmpty else { throw CLIError(.notFound, "iMessage 1:1 대화가 없습니다") }
        let items = ChatListing.items(list, cfg: cfg)
        let picked = try interaction.pickChat(items)
        guard let c = list.first(where: { $0.guid == picked.guid }) else { throw CLIError(.notFound, "고른 대화를 찾지 못했습니다") }
        return c
    }

    func telegramIDs(_ req: AddRequest, tg: TelegramClient, bot: String) async throws -> (Int64, Int64) {
        switch (req.telegramChat, req.allowedUser) {
        case let (c?, u?):
            guard c != 0, u > 0 else { throw CLIError(.usage, "--telegram-chat 은 0 이 아니고 --allowed-user 는 양수여야 합니다") }
            return (c, u)
        case (nil, nil):
            break
        default:
            throw CLIError(.usage, "--telegram-chat 과 --allowed-user 는 함께 주거나 둘 다 빼세요(빼면 봇에게 온 메시지로 알아냄)")
        }
        progress("텔레그램에서 @\(bot) 에게 아무 글이나 보내세요. \(req.waitSeconds)초 기다립니다(최근 \(Int(req.maxMessageAge / 60))분 안의 메시지도 씁니다). 이 글은 iMessage 로 보내지 않습니다.")
        let deadline = clock.now + Double(req.waitSeconds)
        var rejected = Set<String>()
        repeat {
            let remaining = max(0, Int(deadline - clock.now))
            let msgs: [TGMessage]
            do { msgs = try await tg.peekMessages(timeout: min(10, remaining)) } catch {
                throw CLIError(.failure, "봇 메시지 확인(getUpdates) 실패: \(TelegramErrorHint.explain(error))")
            }
            let found = TelegramIDDetector.candidates(msgs, now: clock.now, maxAge: req.maxMessageAge)
                .filter { !rejected.contains("\($0.chatID)/\($0.userID)") }
            if found.count > 1 {
                let list = found.map { "chat \($0.chatID) / user \($0.userID)" }.joined(separator: ", ")
                throw CLIError(.conflict, "여러 사람이 봇에게 글을 보냈습니다(\(list)). --telegram-chat 과 --allowed-user 로 정해 주세요")
            }
            if let s = found.first {
                if let interaction, try !interaction.confirmSender(s, bot: bot) {
                    rejected.insert("\(s.chatID)/\(s.userID)")
                } else {
                    progress("텔레그램 확인: chat \(s.chatID), 허용 사용자 \(s.userID)")
                    return (s.chatID, s.userID)
                }
            }
            if clock.now >= deadline { break }
            await clock.sleep(seconds: 1)
        } while clock.now < deadline
        throw CLIError(.timeout, "\(req.waitSeconds)초 안에 봇(@\(bot))에게 온 메시지가 없습니다. 봇에게 글을 보낸 뒤 다시 실행하거나 --telegram-chat·--allowed-user 를 주세요")
    }
}

public enum TelegramErrorHint {
    public static func explain(_ error: Error) -> String {
        Relay.explainTelegramFailure(error)
    }
}

// MARK: - 대화 목록과 매핑 표시

public enum ChatListing {
    public struct Usage { public var byGuid: [String: String]; public var byHandle: [String: String] }

    public static func usage(_ cfg: BluehopConfig) -> Usage {
        var g: [String: String] = [:], h: [String: String] = [:]
        for m in cfg.mappings {
            g[m.imessage.chatGuid] = g[m.imessage.chatGuid] ?? m.id
            let n = MappingRules.normalizeHandle(m.imessage.handle)
            h[n] = h[n] ?? m.id
        }
        return Usage(byGuid: g, byHandle: h)
    }

    public static func mappedTo(_ c: ChatDB.ChatSummary, _ u: Usage) -> String? {
        u.byGuid[c.guid] ?? u.byHandle[MappingRules.normalizeHandle(c.handle)]
    }

    /// 검색어가 handle·guid 에 들어 있는 대화(공백·`-`·괄호·대소문자 무시).
    public static func filter(_ list: [ChatDB.ChatSummary], search: String?) -> [ChatDB.ChatSummary] {
        guard let s = search.map(MappingRules.normalizeHandle), !s.isEmpty else { return list }
        return list.filter { MappingRules.normalizeHandle($0.handle).contains(s) || MappingRules.normalizeHandle($0.guid).contains(s) }
    }

    public static func items(_ list: [ChatDB.ChatSummary], cfg: BluehopConfig) -> [ChatPicker.Item] {
        let u = usage(cfg)
        return list.map { c in
            ChatPicker.Item(guid: c.guid, handle: c.handle, detail: detail(c), mappedTo: mappedTo(c, u))
        }
    }

    static func detail(_ c: ChatDB.ChatSummary) -> String {
        var parts: [String] = []
        if let s = c.service { parts.append(s) }
        if let t = c.lastMessageAt { parts.append("마지막 " + JSONOut.localDate(t)) }
        return parts.joined(separator: " · ")
    }

    public static func json(_ list: [ChatDB.ChatSummary], cfg: BluehopConfig) -> [String: Any?] {
        let u = usage(cfg)
        return ["chats": list.map { c -> [String: Any?] in
            ["guid": c.guid, "handle": c.handle, "service": c.service,
             "lastMessageAt": c.lastMessageAt.map(JSONOut.iso), "mappedTo": mappedTo(c, u)]
        }]
    }
}
