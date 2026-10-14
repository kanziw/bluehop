import Foundation
import BluehopCore

// MARK: - 공통

/// 설정을 읽는다. 파일이 없으면 오류(종료 1).
func loadConfig(_ ctx: Context) throws -> LoadedConfig {
    try ConfigLoader.loadFile(path: ctx.configPath)
}

/// --mapping 으로 매핑을 고른다. 없으면 매핑이 하나뿐일 때 그것.
func selectMapping(_ cfg: BluehopConfig, _ id: String?) throws -> MappingConfig {
    if let id {
        guard let m = cfg.mapping(id) else { throw CLIError(.notFound, "매핑 '\(id)' 가 없습니다 (bluehop mapping list)") }
        return m
    }
    if cfg.mappings.count == 1 { return cfg.mappings[0] }
    if cfg.mappings.isEmpty { throw CLIError(.notFound, "매핑이 없습니다 (bluehop mapping add)") }
    throw CLIError(.usage, "--mapping 이 필요합니다 (매핑 \(cfg.mappings.count)개: \(cfg.mappings.map(\.id).joined(separator: ", ")))")
}

/// 설치된 바이너리를 launchd 로 돌려 chat.db 를 읽을 수 있는가(터미널에 전체 디스크 접근이 없을 때).
var canUseOneShot: Bool {
    !LaunchdOneShot.isInsideOneShot && FileManager.default.isExecutableFile(atPath: Paths.installedBinary)
}

/// chat.db 를 열고 읽어 본다. 실패하면 nil 과 이유.
func openChatDB() -> (ChatDB?, String?) {
    do {
        let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
        try db.probe()
        return (db, nil)
    } catch {
        return (nil, "\(error)")
    }
}

let fdaHint = "전체 디스크 접근 권한이 이 프로그램(또는 터미널)에 있어야 합니다. 설치된 bluehop 이 있으면 scripts/agent-run.sh 로 실행하세요."

/// 같은 명령을 설치된 bluehop 으로 launchd 를 통해 다시 돌리고 출력·종료 코드를 그대로 넘긴다.
func rerunViaLaunchd(_ name: String, _ ctx: Context, reason: String) throws -> ExitCode {
    note("chat.db 를 이 터미널 권한으로 열 수 없어(\(reason.prefix(80))) 설치된 bluehop 을 launchd 로 한 번 실행합니다.")
    var args = name.split(separator: " ").map(String.init) + ctx.raw
    if ctx.args.value("--config") == nil, ctx.configPath != Paths.configFile { args += ["--config", ctx.configPath] }
    let r = try LaunchdOneShot.run(args: args)
    print(r.stdout, terminator: "")
    if !r.stderr.isEmpty { FileHandle.standardError.write(Data(r.stderr.utf8)) }
    return ExitCode(rawValue: r.status) ?? .failure
}

// MARK: - run

func cmdRun(_ ctx: Context) async throws -> ExitCode {
    let configPath = ctx.configPath
    let statePath = ctx.statePath
    try ConfigLoader.ensurePrivateDir((configPath as NSString).deletingLastPathComponent)
    _ = try StateStore(path: statePath)  // 옛 상태 DB 를 매핑별 스키마로 한 번 옮긴다(일꾼들이 동시에 열기 전에)
    let activityDB = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
    let activity = ChatActivity(chatDB: activityDB)
    let claims = BotClaims()
    let source = Supervisor.Source(
        load: { try ConfigLoader.load(path: configPath) },
        stamp: {
            guard let a = try? FileManager.default.attributesOfItem(atPath: configPath) else { return nil }
            let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (a[.size] as? NSNumber)?.intValue ?? 0
            let inode = (a[.systemFileNumber] as? NSNumber)?.intValue ?? 0
            return "\(m)/\(size)/\(inode)"
        })
    let supervisor = Supervisor(source: source, clock: SystemClock(), makeWorker: { m in
        MappingWorker(
            mapping: m, claims: claims, clock: SystemClock(),
            build: { m in
                let token = try ConfigLoader.loadToken(m)
                if let want = m.telegram.botId, let got = ConfigLoader.botID(ofToken: token), want != got {
                    throw ConfigError.token("토큰의 봇(id \(got))이 설정의 botId(\(want))와 다르다")
                }
                let chatDB = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
                let state = try StateStore(path: statePath, mappingID: m.id)
                let tg = TelegramClient(token: token, chatID: m.telegram.chatId)
                return Relay(chatDB: chatDB, state: state, telegram: tg, sender: AppleScriptSender(),
                             converter: SystemMediaConverter(), clock: SystemClock(), options: MappingOptions.make(m),
                             activity: activity, log: { log("[\(m.id)] \($0)") })
            },
            recordFailure: { id, message in
                guard let s = try? StateStore(path: statePath, mappingID: id) else { return }
                s.setHealthState("backoff")
                s.recordError(message, at: Date().timeIntervalSince1970)
            },
            afterStart: { relay in
                // 시작할 때 보내지 않고 대화 존재만 확인한다. launchd 로 돌 때 '자동 제어' 승인 창도 이때 뜬다.
                do {
                    if try !AppleScriptSender().chatExists(relay.options.chatGuid) {
                        log("[\(m.id)] 경고: 메시지 앱에서 설정한 chat id 를 찾지 못함 — 텔레그램 → iMessage 발송이 실패할 수 있음")
                    }
                } catch {
                    log("[\(m.id)] 경고: 메시지 앱 자동 제어 확인 실패: \(error)")
                }
            },
            log: { log("[\(m.id)] \($0)") })
    }, log: log)
    let cfg = try ConfigLoader.load(path: configPath)
    log("시작 v\(version) 매핑 \(cfg.mappings.count)개(켜짐 \(cfg.enabledMappings.count)개)")
    try await supervisor.runForever()
    return .ok
}

// MARK: - chats

func cmdChats(_ ctx: Context) async throws -> ExitCode {
    let limit = try ctx.args.int("--limit", default: 30, range: 1...1000)
    let (db, why) = openChatDB()
    guard let db else {
        if canUseOneShot { return try rerunViaLaunchd("chats", ctx, reason: why ?? "") }
        throw CLIError(.failure, "chat.db 를 열지 못함: \(why ?? "")\n\(fdaHint)")
    }
    let search = ctx.args.value("--search")
    let all = try db.listOneToOneChats(limit: search == nil ? limit : 1000)
    let list = Array(ChatListing.filter(all, search: search).prefix(limit))
    let cfg = (try? MappingAdder.loadOrEmpty(ctx.configPath)) ?? BluehopConfig(mappings: [])
    if ctx.json {
        say(JSONOut.render(ChatListing.json(list, cfg: cfg)))
        return .ok
    }
    if list.isEmpty { say("맞는 1:1 대화가 없습니다."); return .ok }
    let usage = ChatListing.usage(cfg)
    say("handle\tservice\t마지막\t매핑\tguid   (최근 순)")
    for c in list {
        say([c.handle, c.service ?? "-", c.lastMessageAt.map(JSONOut.localDate) ?? "-",
             ChatListing.mappedTo(c, usage) ?? "-", c.guid].joined(separator: "\t"))
    }
    return .ok
}

/// `mapping add` 가 쓰는 대화 목록: 직접 읽고, 권한이 없으면 launchd 로 `chats --json` 을 돌려 받는다.
func chatListAnyhow(_ ctx: Context) throws -> [ChatDB.ChatSummary] {
    let (db, why) = openChatDB()
    if let db { return try db.listOneToOneChats(limit: 1000) }
    guard canUseOneShot else { throw CLIError(.failure, "chat.db 를 열지 못함: \(why ?? "")\n\(fdaHint)") }
    note("chat.db 를 이 터미널 권한으로 열 수 없어 설치된 bluehop 을 launchd 로 실행해 대화 목록을 받습니다.")
    let r = try LaunchdOneShot.run(args: ["chats", "--json", "--limit", "1000"])
    guard r.status == 0, let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any],
          let chats = obj["chats"] as? [[String: Any]] else {
        throw CLIError(.failure, "설치된 bluehop 으로도 대화 목록을 읽지 못함: \(r.stderr.prefix(200))\n\(fdaHint)")
    }
    let iso = ISO8601DateFormatter()
    return chats.map {
        ChatDB.ChatSummary(guid: $0["guid"] as? String ?? "", handle: $0["handle"] as? String ?? "", lastRowID: 0,
                           service: $0["service"] as? String,
                           lastMessageAt: ($0["lastMessageAt"] as? String).flatMap { iso.date(from: $0)?.timeIntervalSince1970 })
    }
}

// MARK: - mapping list / pause / resume / remove

func cmdMappingList(_ ctx: Context) async throws -> ExitCode {
    let exists = FileManager.default.fileExists(atPath: ctx.configPath)
    let loaded: LoadedConfig? = exists ? try loadConfig(ctx) : nil
    let mappings = loaded?.config.mappings ?? []
    if ctx.json {
        say(JSONOut.render([
            "configPath": ctx.configPath, "configExists": exists,
            "configVersion": loaded.map { $0.legacy ? 1 : $0.config.version } as Any?,
            "legacy": loaded?.legacy ?? false,
            "mappings": mappings.map(JSONOut.mapping),
        ] as [String: Any?]))
        return .ok
    }
    guard !mappings.isEmpty else {
        say(exists ? "매핑이 없습니다. 추가: bluehop mapping add" : "설정 파일이 없습니다(\(ctx.configPath)). 추가: bluehop mapping add")
        return .ok
    }
    say("id\t상태\tiMessage\t텔레그램 봇\t텔레그램 방")
    for m in mappings {
        say([m.id, m.enabled ? "켜짐" : "멈춤", m.imessage.handle, m.telegram.botUsername.map { "@" + $0 } ?? "-",
             String(m.telegram.chatId)].joined(separator: "\t"))
    }
    if loaded?.legacy == true { note("(0.4.x 설정을 매핑 'default' 로 읽었습니다. 매핑을 바꾸는 명령이 처음 실행될 때 버전 2 로 옮기고 백업을 남깁니다)") }
    return .ok
}

func cmdSetEnabled(_ ctx: Context, _ enabled: Bool) throws -> ExitCode {
    let id = ctx.args.positionals[0]
    var cfg = try loadConfig(ctx).config
    guard let i = cfg.mappings.firstIndex(where: { $0.id == id }) else { throw CLIError(.notFound, "매핑 '\(id)' 가 없습니다") }
    let changed = cfg.mappings[i].enabled != enabled
    cfg.mappings[i].enabled = enabled
    let backup = changed ? try ConfigLoader.save(cfg, path: ctx.configPath) : nil
    if ctx.json {
        say(JSONOut.render(["ok": true, "id": id, "enabled": enabled, "changed": changed, "configBackup": backup] as [String: Any?]))
    } else {
        say(changed ? "매핑 '\(id)' 를 \(enabled ? "켰습니다" : "멈췄습니다"). 실행 중인 bluehop 이 약 5초 안에 반영합니다." : "매핑 '\(id)' 는 이미 \(enabled ? "켜져" : "멈춰") 있습니다.")
        if let backup { note("0.4.x 설정을 버전 2 로 옮겼습니다. 백업: \(backup)") }
    }
    return .ok
}

func cmdMappingRemove(_ ctx: Context) async throws -> ExitCode {
    let id = ctx.args.positionals[0]
    var cfg = try loadConfig(ctx).config
    guard let m = cfg.mapping(id) else { throw CLIError(.notFound, "매핑 '\(id)' 가 없습니다") }
    cfg.mappings.removeAll { $0.id == id }
    let backup = try ConfigLoader.save(cfg, path: ctx.configPath)
    var tokenDeleted = false
    if m.telegram.tokenSource == "keychain", !ctx.args.has("--keep-token") {
        tokenDeleted = try KeychainTokenStore().delete(account: m.keychainAccount)
    }
    var statePurged = false
    if ctx.args.has("--purge-state"), FileManager.default.fileExists(atPath: ctx.statePath) {
        try StateStore(path: ctx.statePath, mappingID: id).purgeAll()
        statePurged = true
    }
    if ctx.json {
        say(JSONOut.render(["ok": true, "id": id, "tokenDeleted": tokenDeleted, "statePurged": statePurged, "configBackup": backup] as [String: Any?]))
    } else {
        say("매핑 '\(id)' 를 지웠습니다. 실행 중인 bluehop 이 약 5초 안에 그 일꾼을 멈춥니다.")
        if tokenDeleted { say("Keychain 봇 토큰(계정 \(m.keychainAccount))도 지웠습니다.") }
        if m.telegram.tokenSource == "file" { say("토큰 파일은 건드리지 않았습니다: \(m.telegram.tokenFile ?? "")") }
        if let backup { note("0.4.x 설정을 버전 2 로 옮겼습니다. 백업: \(backup)") }
    }
    return .ok
}

// MARK: - mapping add

func readTokenFromStdin() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init),
          !line.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw CLIError(.usage, "표준입력에서 봇 토큰을 읽지 못했습니다")
    }
    return line
}

func cmdMappingAdd(_ ctx: Context) async throws -> ExitCode {
    let a = ctx.args
    if a.has("--token-stdin") && a.has("--token-file") { throw CLIError(.usage, "--token-stdin 과 --token-file 은 함께 쓸 수 없습니다") }
    let wait = try a.int("--wait", default: 120, range: 0...3600)
    // 표준입력을 토큰에 쓰면 더 묻지 않는다(터미널이 아님).
    let interactive = Terminal.isInteractive && !a.has("--token-stdin")
    let token: String
    var tokenFile: String?
    if a.has("--token-stdin") {
        token = try readTokenFromStdin()
    } else if let f = a.value("--token-file") {
        let path = (f as NSString).expandingTildeInPath
        do { token = try ConfigLoader.loadToken(source: "file", file: path) } catch { throw CLIError(.usage, "\(error)") }
        tokenFile = path
    } else if interactive {
        Terminal.installInterruptHandler()
        Terminal.write("@BotFather 에서 받은 새 봇 토큰을 붙여 넣으세요(화면에 보이지 않음).\n")
        guard let t = Terminal.readHidden(prompt: "봇 토큰: "), !t.isEmpty else { throw CLIError(.cancelled, "토큰 입력을 취소했습니다") }
        token = t
    } else {
        throw CLIError(.usage, "봇 토큰이 필요합니다: --token-stdin(표준입력) 또는 --token-file. 토큰은 명령줄 인자로 받지 않습니다")
    }
    if interactive { Terminal.installInterruptHandler() }

    var req = AddRequest(token: token)
    req.id = a.value("--id")
    req.chat = a.value("--chat")
    req.tokenFile = tokenFile
    req.telegramChat = try a.int64("--telegram-chat")
    req.allowedUser = try a.int64("--allowed-user")
    req.waitSeconds = wait
    req.dryRun = a.has("--dry-run")

    let adder = MappingAdder(
        configPath: ctx.configPath, tokens: KeychainTokenStore(),
        telegramFor: { TelegramClient(token: $0, chatID: 0) },
        chats: { try chatListAnyhow(ctx) }, clock: SystemClock(),
        interaction: interactive ? TerminalInteraction() : nil,
        progress: { note($0) })
    let result = try await adder.run(req)
    let m = result.mapping

    var doctor: [String: Any?]?
    if !result.dryRun && !a.has("--no-doctor") {
        note("새 매핑을 점검합니다(보내지 않음)…")
        doctor = try await doctorReport(ctx, only: m.id, messages: false, telegram: true)
    }
    let service = ServiceState.current()
    let doctorOK = (doctor?["ok"] as? Bool) ?? true
    if ctx.json {
        say(JSONOut.render([
            "ok": doctorOK, "dryRun": result.dryRun, "mapping": JSONOut.mapping(m), "configBackup": result.configBackup,
            "doctor": doctor as Any?, "service": ["loaded": service.loaded, "running": service.running] as [String: Any],
        ] as [String: Any?]))
    } else {
        if result.dryRun {
            say("(dry-run) 쓰지 않았습니다. 추가될 매핑:")
            say(JSONOut.render(JSONOut.mapping(m)))
        } else {
            say("✔ 매핑 '\(m.id)' 추가: \(m.imessage.handle) ↔ @\(m.telegram.botUsername ?? "?") (텔레그램 방 \(m.telegram.chatId))")
            if let b = result.configBackup { say("  0.4.x 설정을 버전 2 로 옮겼습니다. 백업: \(b)") }
            if let doctor { printDoctor(doctor) }
            say(service.running ? "실행 중인 bluehop 이 약 5초 안에 이 매핑을 시작합니다. 확인: bluehop status"
                                : "bluehop 이 실행 중이 아닙니다. 켜기: bash scripts/install.sh (또는 launchctl bootstrap)")
        }
    }
    return doctorOK ? .ok : .failure
}

// MARK: - doctor

func cmdDoctor(_ ctx: Context) async throws -> ExitCode {
    let report = try await doctorReport(ctx, only: ctx.args.value("--mapping"), messages: ctx.args.has("--messages"),
                                        telegram: ctx.args.has("--telegram"))
    if ctx.json { say(JSONOut.render(report)) } else { printDoctor(report) }
    return (report["ok"] as? Bool) == true ? .ok : .failure
}

func cmdMappingTest(_ ctx: Context) async throws -> ExitCode {
    let report = try await doctorReport(ctx, only: ctx.args.positionals[0], messages: ctx.args.has("--messages"), telegram: true)
    if ctx.json { say(JSONOut.render(report)) } else { printDoctor(report) }
    return (report["ok"] as? Bool) == true ? .ok : .failure
}

/// 점검 결과(JSON 모양). chat.db 를 열 수 없고 설치된 bluehop 이 있으면 launchd 로 `doctor --json` 을 돌려 그 결과를 쓴다.
func doctorReport(_ ctx: Context, only: String?, messages: Bool, telegram: Bool) async throws -> [String: Any?] {
    var configCheck: [String: Any?] = ["name": "설정 파일 (0600)", "ok": false, "detail": ctx.configPath]
    let loaded: LoadedConfig
    do {
        loaded = try loadConfig(ctx)
        configCheck["ok"] = true
        configCheck["detail"] = "\(ctx.configPath) — 매핑 \(loaded.config.mappings.count)개\(loaded.legacy ? " (0.4.x 모양, default 로 읽음)" : "")"
    } catch {
        configCheck["detail"] = "\(error)"
        return ["ok": false, "config": configCheck, "mappings": [] as [Any]]
    }
    let targets: [MappingConfig]
    if let only {
        guard let m = loaded.config.mapping(only) else { throw CLIError(.notFound, "매핑 '\(only)' 가 없습니다") }
        targets = [m]
    } else {
        targets = loaded.config.mappings
    }
    let (db, why) = openChatDB()
    if db == nil, canUseOneShot {
        note("chat.db 를 이 터미널 권한으로 열 수 없어 설치된 bluehop 을 launchd 로 실행해 점검합니다.")
        var args = ["doctor", "--json", "--config", ctx.configPath]
        if let only { args += ["--mapping", only] }
        if messages { args.append("--messages") }
        if telegram { args.append("--telegram") }
        let r = try LaunchdOneShot.run(args: args)
        if let obj = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] {
            var out: [String: Any?] = [:]
            for (k, v) in obj { out[k] = v }
            out["via"] = "launchd"
            return out
        }
        note("launchd 로 점검하지 못함: \(r.stderr.prefix(200))")
    }
    var allOK = true
    var results: [[String: Any?]] = []
    for m in targets {
        var checks: [[String: Any?]] = []
        func check(_ name: String, _ body: () throws -> String) {
            do { checks.append(["name": name, "ok": true, "detail": try body()]) } catch {
                checks.append(["name": name, "ok": false, "detail": "\(error)"])
            }
        }
        var token: String?
        check("봇 토큰") {
            let t = try ConfigLoader.loadToken(m)
            token = t
            if let want = m.telegram.botId, let got = ConfigLoader.botID(ofToken: t), want != got {
                throw ConfigError.token("토큰의 봇(id \(got))이 설정의 botId(\(want))와 다르다")
            }
            return m.telegram.tokenSource == "file" ? "읽음 (파일)" : "읽음 (Keychain 계정 \(m.keychainAccount))"
        }
        check("chat.db 읽기 전용 열기 + 대화 검증") {
            guard let db else { throw CLIError(.failure, "chat.db 를 열지 못함: \(why ?? "") — \(fdaHint)") }
            let chat = try db.resolveChat(guid: m.imessage.chatGuid, expectedHandle: m.imessage.handle)
            return "1:1 대화 확인 (chat rowid \(chat.rowid))"
        }
        if messages {
            check("메시지 앱에 대화 존재 (자동 제어)") {
                guard try AppleScriptSender().chatExists(m.imessage.chatGuid) else { throw SendError("메시지 앱에서 chat id 를 찾지 못함") }
                return "있음"
            }
        }
        if telegram {
            var result: Result<TelegramClient.BotInfo, Error> = .failure(ConfigError.token("토큰을 읽지 못해 건너뜀"))
            if let token {
                do { result = .success(try await TelegramClient(token: token, chatID: m.telegram.chatId).getMeInfo()) } catch {
                    result = .failure(CLIError(.failure, TelegramErrorHint.explain(error)))
                }
            }
            check("텔레그램 getMe") {
                let info = try result.get()
                if let want = m.telegram.botId, want != info.id { throw ConfigError.token("봇 id 가 설정과 다르다") }
                return "@" + info.username
            }
        }
        let ok = checks.allSatisfy { ($0["ok"] as? Bool) == true }
        if !ok { allOK = false }
        results.append(["id": m.id, "enabled": m.enabled, "ok": ok, "checks": checks])
    }
    return ["ok": allOK, "config": configCheck, "mappings": results]
}

func printDoctor(_ r: [String: Any?]) {
    if let c = r["config"] as? [String: Any?] {
        say("\((c["ok"] as? Bool) == true ? "✔" : "✘") \(c["name"] as? String ?? "설정"): \(c["detail"] as? String ?? "")")
    } else if let c = r["config"] as? [String: Any] {
        say("\((c["ok"] as? Bool) == true ? "✔" : "✘") \(c["name"] as? String ?? "설정"): \(c["detail"] as? String ?? "")")
    }
    let maps: [[String: Any]] = (r["mappings"] as? [[String: Any?]])?.map { $0.compactMapValues { $0 } } ?? (r["mappings"] as? [[String: Any]]) ?? []
    for m in maps {
        say("[\(m["id"] as? String ?? "?")]\((m["enabled"] as? Bool) == false ? " (멈춤)" : "")")
        let checks: [[String: Any]] = (m["checks"] as? [[String: Any?]])?.map { $0.compactMapValues { $0 } } ?? (m["checks"] as? [[String: Any]]) ?? []
        for c in checks {
            say("  \((c["ok"] as? Bool) == true ? "✔" : "✘") \(c["name"] as? String ?? ""): \(c["detail"] as? String ?? "")")
        }
    }
}

// MARK: - status

func cmdStatus(_ ctx: Context) async throws -> ExitCode {
    let loaded = try loadConfig(ctx)
    let service = ServiceState.current()
    let now = Date().timeIntervalSince1970
    var rows: [MappingStatus] = []
    let hasState = FileManager.default.fileExists(atPath: ctx.statePath)
    for m in loaded.config.mappings {
        let health = hasState ? ((try? StateStore(path: ctx.statePath, mappingID: m.id))?.health() ?? StateStore.Health()) : StateStore.Health()
        rows.append(MappingStatus(id: m.id, enabled: m.enabled, health: health))
    }
    if ctx.json {
        say(JSONOut.render([
            "service": ["label": Paths.launchAgentLabel, "loaded": service.loaded, "running": service.running, "pid": service.pid] as [String: Any?],
            "mappings": rows.map { $0.json(now: now) },
        ] as [String: Any?]))
        return .ok
    }
    say("서비스 \(Paths.launchAgentLabel): \(service.running ? "실행 중 (pid \(service.pid.map(String.init) ?? "?"))" : service.loaded ? "등록됨, 멈춤" : "등록 안 됨")")
    if rows.isEmpty { say("매핑이 없습니다. 추가: bluehop mapping add") }
    for r in rows {
        let h = r.health
        var line = "[\(r.id)] \(r.verdict(now: now))"
        if let t = h.lastTelegramOK { line += " · 텔레그램 확인 \(Int(now - t))초 전" }
        if let reason = h.halted { line += " · 정지: \(reason)" }
        if let e = h.lastError { line += " · 오류: \(e)" }
        say(line)
    }
    return .ok
}

// MARK: - telegram-ids · resume · 진단

func cmdTelegramIDs(_ ctx: Context) async throws -> ExitCode {
    let token: String
    if ctx.args.has("--token-stdin") {
        token = try ConfigLoader.validateToken(try readTokenFromStdin())
    } else if let f = ctx.args.value("--token-file") {
        token = try ConfigLoader.loadToken(source: "file", file: f)
    } else {
        token = try ConfigLoader.loadToken(try selectMapping(try loadConfig(ctx).config, ctx.args.value("--mapping")))
    }
    let tg = TelegramClient(token: token, chatID: 0)
    let bot = try await tg.getMeInfo()
    let msgs = try await tg.peekMessages(timeout: 0)
    var seen = Set<String>()
    var rows: [[String: Any?]] = []
    for m in msgs {
        let key = "\(m.chat.id)/\(m.from?.id ?? 0)"
        guard seen.insert(key).inserted else { continue }
        rows.append(["chatId": m.chat.id, "allowedUserId": m.from?.id, "chatType": m.chat.type])
    }
    if ctx.json {
        say(JSONOut.render(["bot": ["id": bot.id, "username": bot.username] as [String: Any], "senders": rows] as [String: Any?]))
        return .ok
    }
    say("봇: @\(bot.username)")
    if rows.isEmpty { say("최근 메시지가 없습니다. 텔레그램에서 봇에게 아무 글이나 보낸 뒤 다시 실행하세요.") }
    for r in rows {
        say("chatId=\(r["chatId"] as? Int64 ?? 0)\tallowedUserId=\((r["allowedUserId"] as? Int64).map(String.init) ?? "?")\t(\(r["chatType"] as? String ?? "?"))")
    }
    return .ok
}

func cmdResume(_ ctx: Context) async throws -> ExitCode {
    let m = try selectMapping(try loadConfig(ctx).config, ctx.args.value("--mapping"))
    let state = try StateStore(path: ctx.statePath, mappingID: m.id)
    if ctx.args.has("--skip-backlog") {
        let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
        let chat = try db.resolveChat(guid: m.imessage.chatGuid, expectedHandle: m.imessage.handle)
        try state.setIMsgCursor(try db.maxRowID(chat: chat))
    }
    try state.setHalted(nil)
    say("[\(m.id)] 재개함\(ctx.args.has("--skip-backlog") ? " (밀린 iMessage 건너뜀)" : ""). 실행 중인 중계기는 다음 루프부터 반영합니다.")
    return .ok
}

/// 진단 명령 공통: 매핑 하나의 대화.
func diagTarget(_ ctx: Context) throws -> (MappingConfig, ChatDB, ChatInfo) {
    let m = try selectMapping(try loadConfig(ctx).config, ctx.args.value("--mapping"))
    let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
    let chat = try db.resolveChat(guid: m.imessage.chatGuid, expectedHandle: m.imessage.handle)
    return (m, db, chat)
}

func cmdSelfcheck(_ ctx: Context) async throws -> ExitCode {
    let (_, db, chat) = try diagTarget(ctx)
    let r = try db.attributedBodySelfCheck(chat: chat, limit: 500)
    say("text 있는 행 \(r.checked)건 중 추출 일치 \(r.matched)건 / text 빈 행 \(r.onlyBlob)건 중 추출 성공 \(r.onlyBlobExtracted)건")
    return .ok
}

func cmdDiagEcho(_ ctx: Context) async throws -> ExitCode {
    // 메아리 맞춤 진단: 본문 없이 길이·정규화·다른 코드포인트 위치만 출력한다.
    let (_, db, chat) = try diagTarget(ctx)
    let after = try ctx.args.int64("--after") ?? 0
    var expected: String?
    if let f = ctx.args.value("--expect-file") {
        expected = try String(contentsOfFile: f, encoding: .utf8).trimmingCharacters(in: .newlines)
    }
    for line in EchoDiagnostics.report(rows: try db.rawOwnRows(after: after, chat: chat), expected: expected) { say(line) }
    return .ok
}

func cmdDiagSendFile(_ ctx: Context) async throws -> ExitCode {
    // 첨부 전송 진단: 중계기와 같은 폴더·같은 발신기로 매핑한 대화에만 보내고, 상태만 출력한다(본문 없음).
    guard let file = ctx.args.value("--file") else { throw CLIError(.usage, "--file 이 필요합니다") }
    let caption = ctx.args.value("--caption") ?? ""
    let wait = Double(try ctx.args.int("--wait", default: 40, range: 1...600))
    let (m, db, chat) = try diagTarget(ctx)
    let opts = MappingOptions.make(m)
    try ConfigLoader.ensurePrivateDir(opts.outboxDir.path)
    let outbox = opts.outboxDir.path
    say("보낼 첨부 폴더를 메시지 앱이 읽을 수 있음: \(MessagesSandbox.canRead(outbox))")
    guard MessagesSandbox.canRead(outbox) else { throw CLIError(.failure, "메시지 앱이 읽을 수 없는 폴더라 보내지 않음") }
    let dir = try OutboxStaging.freshDirectory(OutboxStaging.diagPrefix + String(Int(Date().timeIntervalSince1970)), in: opts.outboxDir)
    let staged = dir.appendingPathComponent((file as NSString).lastPathComponent)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: staged)
    let before = try db.maxRowID(chat: chat)
    let sender = AppleScriptSender()
    try sender.sendFile(staged.path, chatGuid: m.imessage.chatGuid)
    say("파일 보냄(메시지 앱이 명령을 받음)")
    if !caption.isEmpty {
        try sender.sendText(caption, chatGuid: m.imessage.chatGuid)
        say("글 보냄(메시지 앱이 명령을 받음)")
    }
    func place(_ path: String) -> String {
        if path.hasPrefix(Paths.attachmentsRoot + "/") { return "메시지 첨부 폴더" }
        if path.hasPrefix(outbox + "/") { return "보낼 첨부 폴더" }
        return "기타 위치"
    }
    let deadline = Date().addingTimeInterval(wait)
    var settled = false
    var rows: [ChatDB.SendDiagRow] = []
    while Date() < deadline {
        rows = try db.sendDiagRows(after: before, chat: chat)
        let fileRows = rows.filter { !$0.attachments.isEmpty }
        let failed = rows.contains { $0.error != 0 } || fileRows.contains { $0.attachments.contains { $0.transferState == 6 } }
        let fileDone = !fileRows.isEmpty && fileRows.allSatisfy { $0.isSent && $0.attachments.allSatisfy { $0.transferState == 5 } }
        let textDone = caption.isEmpty || rows.contains { $0.attachments.isEmpty && $0.hasText && $0.isSent }
        if failed || (fileDone && textDone) { settled = true; break }
        usleep(500_000)
    }
    var ok = settled
    for r in rows {
        let att = r.attachments.map { "transfer_state=\($0.transferState) mime=\($0.mimeType ?? "?") 위치=\(place($0.filename))" }.joined(separator: "; ")
        say("rowid=\(r.rowid) error=\(r.error) is_sent=\(r.isSent) is_delivered=\(r.isDelivered) service=\(r.service ?? "?") 글=\(r.hasText) 첨부=[\(att)]")
        if r.error != 0 || r.attachments.contains(where: { $0.transferState != 5 }) { ok = false }
    }
    if rows.isEmpty { ok = false }
    say(ok ? "결과: 성공" : (settled ? "결과: 실패" : "결과: \(Int(wait))초 안에 확정되지 않음"))
    return ok ? .ok : .failure
}

func cmdDiagAudio(_ ctx: Context) async throws -> ExitCode {
    // 음성 말풍선 조사: 매핑한 대화의 오디오 첨부 행 메타(플래그·형식·코덱)만 출력한다(본문·음성 내용 없음).
    let (_, db, chat) = try diagTarget(ctx)
    for r in try db.audioDiagRows(chat: chat) {
        let codec = r.path.map(AudioCodecProbe.describe) ?? "파일 없음"
        say("rowid=\(r.rowid) from_me=\(r.isFromMe) is_audio_message=\(r.isAudioMessage) expire_state=\(r.expireState) item_type=\(r.itemType) balloon=\(r.balloonBundleID ?? "-") mime=\(r.mimeType ?? "-") uti=\(r.uti ?? "-") 이름=\(ChatDB.transferNameClass(r.transferName)) 확장자=.\(r.fileExtension) bytes=\(r.totalBytes) 코덱=\(codec)")
    }
    return .ok
}
