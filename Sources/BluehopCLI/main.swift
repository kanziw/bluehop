import Foundation
import BluehopCore

let version = "0.4.1"

func log(_ s: String) {
    let f = ISO8601DateFormatter()
    FileHandle.standardOutput.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write("오류: \(s)\n".data(using: .utf8)!)
    exit(1)
}

func usage() -> Never {
    print("""
    bluehop \(version) — 텔레그램 방 하나 ↔ iMessage 1:1 대화 하나 중계

    사용법:
      bluehop run                         중계 실행 (LaunchAgent 가 부른다)
      bluehop doctor [--messages] [--telegram]
                                          설정·권한·대화 점검 (보내지 않음)
                                          --messages: 메시지 앱에 대화가 있는지 확인(자동 제어 권한 필요)
                                          --telegram: 봇 토큰으로 getMe 호출
      bluehop telegram-ids [--token-file 경로]
                                          봇에게 보낸 최근 메시지의 chat id·user id (본문 없음)
      bluehop list-chats                  묶을 수 있는 1:1 대화 목록(guid, 상대 handle)
      bluehop resume [--skip-backlog]     안전 정지 해제
      bluehop selfcheck-attributed        설정한 대화에서 본문 추출 일치율(숫자만)
      bluehop diag-echo --after ROWID [--expect-file 경로]
                                          내 메시지 행의 본문 모양(길이·정규화·다른 코드포인트)만 출력
      bluehop diag-send-file --file 경로 [--caption 글] [--wait 초]
                                          실제 전송 경로(보낼 첨부 폴더 → 메시지 앱)로 설정한 대화에만 파일(+글)을 보내고
                                          chat.db 의 전송 상태(error·transfer_state·파일 위치)만 출력. ⚠️ 실제로 보낸다
      bluehop diag-audio                  설정한 대화의 오디오 첨부 행 메타(음성 메시지 플래그·mime·uti·코덱)만 출력
      bluehop version
    """)
    exit(2)
}

func makeOptions(_ cfg: RelayConfig) -> Relay.Options {
    let outbox = cfg.relay?.outboxDirectory.map { ($0 as NSString).expandingTildeInPath } ?? Paths.defaultOutboxDir
    var o = Relay.Options(chatGuid: cfg.imessage.chatGuid, handle: cfg.imessage.handle,
                          allowedUserID: cfg.telegram.allowedUserId, chatID: cfg.telegram.chatId,
                          outboxDir: URL(fileURLWithPath: outbox, isDirectory: true),
                          tmpDir: URL(fileURLWithPath: Paths.tmpDir, isDirectory: true))
    o.mirrorOwnMessages = cfg.mirrorOwnMessages
    o.reactionMode = cfg.reactionMode
    return o
}

func buildRelay() throws -> Relay {
    try ConfigLoader.ensurePrivateDir(Paths.supportDir)
    let cfg = try ConfigLoader.load()
    let token = try ConfigLoader.loadToken(cfg)
    let chatDB = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
    let state = try StateStore(path: Paths.stateFile)
    let tg = TelegramClient(token: token, chatID: cfg.telegram.chatId)
    return Relay(chatDB: chatDB, state: state, telegram: tg, sender: AppleScriptSender(),
                 converter: SystemMediaConverter(), clock: SystemClock(), options: makeOptions(cfg), log: log)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }

switch cmd {
case "run":
    do {
        let relay = try buildRelay()
        try await relay.start()
        log("시작 v\(version) halted=\(relay.isHalted)")
        // 시작할 때 보내지 않고 대화 존재만 확인한다. launchd 로 돌 때 '자동 제어' 승인 창도 이때 뜬다.
        do {
            if try !AppleScriptSender().chatExists(relay.options.chatGuid) {
                log("경고: 메시지 앱에서 설정한 chat id 를 찾지 못함 — 텔레그램 → iMessage 발송이 실패할 수 있음")
            }
        } catch {
            log("경고: 메시지 앱 자동 제어 확인 실패: \(error)")
        }
        await relay.runForever()
    } catch {
        fail("\(error)")
    }

case "doctor":
    var ok = true
    func check(_ name: String, _ body: () throws -> String) {
        do { print("✔ \(name): \(try body())") } catch { ok = false; print("✘ \(name): \(error)") }
    }
    var cfg: RelayConfig?
    check("설정 파일 (0600)") { cfg = try ConfigLoader.load(); return Paths.configFile }
    if let cfg {
        check("봇 토큰") { _ = try ConfigLoader.loadToken(cfg); return "읽음 (\(cfg.telegram.tokenSource))" }
        check("chat.db 읽기 전용 열기 + 대화 검증") {
            let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
            let chat = try db.resolveChat(guid: cfg.imessage.chatGuid, expectedHandle: cfg.imessage.handle)
            return "1:1 대화 확인 (chat rowid \(chat.rowid))"
        }
        if args.contains("--messages") {
            check("메시지 앱에 대화 존재 (자동 제어)") {
                guard try AppleScriptSender().chatExists(cfg.imessage.chatGuid) else { throw SendError("메시지 앱에서 chat id 를 찾지 못함") }
                return "있음"
            }
        }
        if args.contains("--telegram") {
            var result: Result<String, Error>
            do {
                let tg = TelegramClient(token: try ConfigLoader.loadToken(cfg), chatID: cfg.telegram.chatId)
                result = .success(try await tg.getMe())
            } catch { result = .failure(error) }
            check("텔레그램 getMe") { "@" + (try result.get()) }
        }
    }
    exit(ok ? 0 : 1)

case "telegram-ids":
    do {
        var file: String?
        if let i = args.firstIndex(of: "--token-file"), i + 1 < args.count { file = args[i + 1] }
        let token = try ConfigLoader.loadToken(source: file == nil ? "keychain" : "file", file: file)
        let tg = TelegramClient(token: token, chatID: 0)
        print("봇: @\(try await tg.getMe())")
        let seen = try await tg.peekSenders()
        if seen.isEmpty { print("최근 메시지가 없습니다. 텔레그램에서 봇에게 아무 글이나 보낸 뒤 다시 실행하세요.") }
        var printed = Set<String>()
        for s in seen {
            let line = "chatId=\(s.chatID)\tallowedUserId=\(s.userID.map(String.init) ?? "?")\t(\(s.chatType ?? "?"))"
            if printed.insert(line).inserted { print(line) }
        }
    } catch { fail("\(error)") }

case "list-chats":
    do {
        let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
        print("chatGuid\thandle\t(최근 순)")
        for c in try db.listOneToOneChats() { print("\(c.guid)\t\(c.handle)") }
    } catch {
        fail("\(error)\n전체 디스크 접근 권한이 이 프로그램(또는 터미널)에 있어야 합니다.")
    }

case "resume":
    do {
        let relay = try buildRelay()
        try await relay.start()
        try relay.resume(skipBacklog: args.contains("--skip-backlog"))
        print("재개함. 실행 중인 중계기는 다음 루프부터 반영합니다.")
    } catch { fail("\(error)") }

case "selfcheck-attributed":
    do {
        let cfg = try ConfigLoader.load()
        let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
        let chat = try db.resolveChat(guid: cfg.imessage.chatGuid, expectedHandle: cfg.imessage.handle)
        let r = try db.attributedBodySelfCheck(chat: chat, limit: 500)
        print("text 있는 행 \(r.checked)건 중 추출 일치 \(r.matched)건 / text 빈 행 \(r.onlyBlob)건 중 추출 성공 \(r.onlyBlobExtracted)건")
    } catch { fail("\(error)") }

case "diag-echo":
    // 메아리 맞춤 진단: 본문 없이 길이·정규화·다른 코드포인트 위치만 출력한다.
    do {
        let cfg = try ConfigLoader.load()
        let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
        let chat = try db.resolveChat(guid: cfg.imessage.chatGuid, expectedHandle: cfg.imessage.handle)
        var after: Int64 = 0
        if let i = args.firstIndex(of: "--after"), i + 1 < args.count { after = Int64(args[i + 1]) ?? 0 }
        var expected: String?
        if let i = args.firstIndex(of: "--expect-file"), i + 1 < args.count {
            expected = try String(contentsOfFile: args[i + 1], encoding: .utf8).trimmingCharacters(in: .newlines)
        }
        for line in EchoDiagnostics.report(rows: try db.rawOwnRows(after: after, chat: chat), expected: expected) { print(line) }
    } catch { fail("\(error)") }

case "diag-send-file":
    // 첨부 전송 진단: 중계기와 같은 폴더·같은 발신기로 설정한 대화에만 보내고, 상태만 출력한다(본문 없음).
    do {
        func opt(_ k: String) -> String? {
            guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let file = opt("--file") else { fail("--file 이 필요합니다") }
        let caption = opt("--caption") ?? ""
        let wait = Double(opt("--wait") ?? "40") ?? 40
        let cfg = try ConfigLoader.load()
        let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
        let chat = try db.resolveChat(guid: cfg.imessage.chatGuid, expectedHandle: cfg.imessage.handle)
        let opts = makeOptions(cfg)
        try ConfigLoader.ensurePrivateDir(opts.outboxDir.path)
        let outbox = opts.outboxDir.path
        print("보낼 첨부 폴더를 메시지 앱이 읽을 수 있음: \(MessagesSandbox.canRead(outbox))")
        guard MessagesSandbox.canRead(outbox) else { fail("메시지 앱이 읽을 수 없는 폴더라 보내지 않음") }
        let dir = try OutboxStaging.freshDirectory(OutboxStaging.diagPrefix + String(Int(Date().timeIntervalSince1970)), in: opts.outboxDir)
        let staged = dir.appendingPathComponent((file as NSString).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: file), to: staged)
        let before = try db.maxRowID(chat: chat)
        let sender = AppleScriptSender()
        try sender.sendFile(staged.path, chatGuid: cfg.imessage.chatGuid)
        print("파일 보냄(메시지 앱이 명령을 받음)")
        if !caption.isEmpty {
            try sender.sendText(caption, chatGuid: cfg.imessage.chatGuid)
            print("글 보냄(메시지 앱이 명령을 받음)")
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
            print("rowid=\(r.rowid) error=\(r.error) is_sent=\(r.isSent) is_delivered=\(r.isDelivered) service=\(r.service ?? "?") 글=\(r.hasText) 첨부=[\(att)]")
            if r.error != 0 || r.attachments.contains(where: { $0.transferState != 5 }) { ok = false }
        }
        if rows.isEmpty { ok = false }
        print(ok ? "결과: 성공" : (settled ? "결과: 실패" : "결과: \(Int(wait))초 안에 확정되지 않음"))
        exit(ok ? 0 : 1)
    } catch { fail("\(error)") }

case "diag-audio":
    // 음성 말풍선 조사: 설정한 대화의 오디오 첨부 행 메타(플래그·형식·코덱)만 출력한다(본문·음성 내용 없음).
    do {
        let cfg = try ConfigLoader.load()
        let db = try ChatDB(path: Paths.chatDB, attachmentsRoot: Paths.attachmentsRoot)
        let chat = try db.resolveChat(guid: cfg.imessage.chatGuid, expectedHandle: cfg.imessage.handle)
        for r in try db.audioDiagRows(chat: chat) {
            let codec = r.path.map(AudioCodecProbe.describe) ?? "파일 없음"
            print("rowid=\(r.rowid) from_me=\(r.isFromMe) is_audio_message=\(r.isAudioMessage) expire_state=\(r.expireState) item_type=\(r.itemType) balloon=\(r.balloonBundleID ?? "-") mime=\(r.mimeType ?? "-") uti=\(r.uti ?? "-") 이름=\(ChatDB.transferNameClass(r.transferName)) 확장자=.\(r.fileExtension) bytes=\(r.totalBytes) 코덱=\(codec)")
        }
    } catch { fail("\(error)") }

case "version":
    print(version)

default:
    usage()
}
