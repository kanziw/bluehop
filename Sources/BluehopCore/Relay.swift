import Foundation

/// 양방향 중계 엔진. 한 루프(`tick`)가 텔레그램 → iMessage, iMessage → 텔레그램, 발송 확인을 차례로 처리한다.
public final class Relay {
    public struct Options {
        public var chatGuid: String
        public var handle: String
        public var allowedUserID: Int64
        public var chatID: Int64
        public var mirrorOwnMessages = true
        public var reactionMode: ReactionMode = .ignore
        public var outboxDir: URL
        public var tmpDir: URL
        public var limits = SafetyLimits()
        /// 텔레그램 → iMessage 발송을 chat.db 에서 확인할 때까지 기다리는 최대 초
        public var confirmTimeout: Double = 60
        /// iMessage 첨부 파일이 디스크에 내려올 때까지 기다리는 최대 초
        public var attachmentWait: Double = 300
        public var pollTimeout = 2
        /// 멈춰 있던 사이 쌓인 텔레그램 글이 이보다 오래됐으면(보낸 시각 기준) iMessage 로 보내지 않고
        /// ⚠️ 로 알린다 — 늦게 도착한 지시가 엉뚱한 때 나가는 것을 막기 위함(사고 2026-10-14).
        public var lateMessageThreshold: Double = 600
        /// 확인 안 된 텔레그램 발송이 남아 있을 때, 새로 본 `is_from_me` 행을 "직접 보낸 글"로
        /// 단정하기 전에 메아리 맞춤을 다시 시도할 수 있게 기다리는 최대 초(사고 2026-10-14 재발 2건).
        public var echoGraceSeconds: Double = 5
        /// osascript 가 시간 제한으로 강제 종료돼 전달 여부를 알 수 없을 때(`OutboxStatus.ambiguousTimeout`),
        /// 곧바로 실패로 알리지 않고 chat.db 메아리 맞춤을 계속 시도하는 최대 초. `confirmTimeout` 과 기본값을
        /// 맞춘다 — osascript 가 분명히 성공했을 때 받아들이는 노출(같은 글을 사람이 직접 보내면 메아리로
        /// 잘못 삼켜질 수 있는 창)과 같은 크기만 추가로 받아들인다는 뜻이다.
        public var sendTimeoutGrace: Double = 60
        /// 첨부를 둔 폴더가 메시지 앱(샌드박스)이 읽을 수 없는 곳이면 보내지 않고 ⚠️ 로 알린다.
        /// 보내 봐야 chat.db 에 error=25 로 실패가 남을 뿐이다(사고 2026-10-14). 테스트는 임시 폴더를 쓰므로 끈다.
        public var requireMessagesReadableOutbox = true
        /// 0.4.x 는 보낼 첨부를 매핑 폴더 없이 바로 이 폴더 아래(숫자 이름)에 두었다. 설정하면 그 남은 폴더도 정리한다.
        public var legacyOutboxRoot: URL?

        public init(chatGuid: String, handle: String, allowedUserID: Int64, chatID: Int64, outboxDir: URL, tmpDir: URL) {
            self.chatGuid = chatGuid
            self.handle = handle
            self.allowedUserID = allowedUserID
            self.chatID = chatID
            self.outboxDir = outboxDir
            self.tmpDir = tmpDir
        }
    }

    public static let ownPrefix = "🙋 나: "

    let chatDB: ChatDB
    let state: StateStore
    let telegram: TelegramClient
    let sender: MessagesSender
    let converter: MediaConverter
    let clock: Clock
    public var options: Options
    let log: (String) -> Void
    /// 구조화(JSON Lines) 사건 로그 — 사람이 읽는 `log` 와 별도, 디버깅용 상관 ID(요청 id·rowid)를 싣는다.
    /// nil 이면(기본값, 대부분의 테스트) 아무것도 적지 않는다.
    let events: EventLog?

    let toTGLimiter: RateLimiter
    let toIMLimiter: RateLimiter
    let toTGBreaker: SafetyBreaker
    let toIMBreaker: SafetyBreaker

    /// 여러 매핑이 chat.db 변화를 함께 확인하는 공용 감시(없으면 매 루프 직접 조회).
    let activity: ChatActivity?

    public private(set) var chat: ChatInfo?
    var failedAttempts: [Int64: Int] = [:]
    var editNoticeSent: Set<Int64> = []
    /// 바로 앞에 텔레그램에 올린 iMessage 글이 답글로 이어 붙은 원글(`tg:<텔레그램 id>` 또는 `im:<guid>`).
    /// 상대가 한 글에 여러 말풍선으로 연달아 답하면 첫 말풍선만 원글에 답글로 걸고, 사이에 다른 글이
    /// 끼지 않은 나머지는 그냥 이어 보낸다. 메모리에만 둔다 — 재시작 뒤 첫 말풍선이 한 번 더 답글로
    /// 걸리는 것 말고는 잃는 것이 없다(답글 관계 매핑은 그대로 저장된다).
    var lastIMThread: String?
    var lastCleanup: Double = 0
    /// 연속된 getUpdates 실패 횟수(일꾼마다 따로 물러선다).
    var telegramFailures = 0
    var lastHealthWrite: Double = 0
    var lastScanWrite: Double = 0

    public init(chatDB: ChatDB, state: StateStore, telegram: TelegramClient, sender: MessagesSender,
                converter: MediaConverter, clock: Clock, options: Options, activity: ChatActivity? = nil,
                events: EventLog? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.activity = activity
        self.chatDB = chatDB
        self.state = state
        self.telegram = telegram
        self.sender = sender
        self.converter = converter
        self.clock = clock
        self.options = options
        self.events = events
        self.log = log
        toTGLimiter = RateLimiter(perMinute: options.limits.toTelegramPerMinute, clock: clock)
        toIMLimiter = RateLimiter(perMinute: options.limits.toIMessagePerMinute, clock: clock)
        toTGBreaker = SafetyBreaker(limit: options.limits.toTelegramPerWindow, windowSeconds: options.limits.windowSeconds, clock: clock)
        toIMBreaker = SafetyBreaker(limit: options.limits.toIMessagePerWindow, windowSeconds: options.limits.windowSeconds, clock: clock)
    }

    /// 구조화 사건 로그 한 줄 — 매핑 id 는 자동으로 싣는다. `events` 가 nil 이면 아무 일도 하지 않는다.
    func logEvent(_ level: LogLevel, _ event: String, _ fields: [String: LogValue] = [:]) {
        events?.log(level, mapping: state.mappingID, event: event, fields)
    }

    /// 본문을 실어도 되는가(`debug` 레벨이면서 `BLUEHOP_LOG_BODIES` 를 명시적으로 켰을 때만) — 이 둘을
    /// 함께 만족할 때만, 아래에서 고른 몇 자리(수신한 글)에 한해 본문 필드를 덧붙인다.
    var capturesBodies: Bool { events?.capturesBodies ?? false }

    // MARK: - 시작

    /// 대화를 검증하고 커서 기준선을 잡는다. 밀린 메시지가 많으면 정지 상태로 시작한다.
    public func start() async throws {
        let chat = try chatDB.resolveChat(guid: options.chatGuid, expectedHandle: options.handle)
        self.chat = chat
        logEvent(.info, "relay_start", ["chat_rowid": .int(chat.rowid)])
        activity?.watch(chat.rowid)
        for dir in [options.outboxDir, options.tmpDir] {
            try ConfigLoader.ensurePrivateDir(dir.path)
        }
        if !MessagesSandbox.canRead(options.outboxDir.path) {
            log("경고: 첨부 폴더를 메시지 앱이 읽을 수 없음 — 사진·파일을 iMessage 로 보낼 수 없음(설정 outboxDirectory 확인)")
        }
        if state.imsgCursor == nil {
            // 첫 실행: 과거 대화를 쏟지 않도록 현재 끝을 기준선으로 잡는다.
            let maxID = try chatDB.maxRowID(chat: chat)
            try state.setIMsgCursor(maxID)
            log("기준선 커서 설정 rowid=\(maxID)")
        }
        let backlog = try chatDB.countAfter(state.imsgCursor ?? 0, chat: chat)
        if backlog > options.limits.maxBacklog, state.haltReason == nil {
            await halt("밀린 iMessage \(backlog)건 (한도 \(options.limits.maxBacklog)) — /resume skip 으로 건너뛰거나 /resume all 로 모두 보내기")
        }
        if !state.hasTGBaseline {
            await establishTelegramBaseline()
        }
    }

    /// 텔레그램도 iMessage 커서처럼 시작 시점 기준선이 필요하다 — `getUpdates` 는 offset 이 없으면
    /// 처음부터(설정 과정에서 보낸 글까지) 돌려주므로, 기준선 없이 받으면 켜기 전 백로그가 그대로
    /// iMessage 로 나간다(사고 2026-10-14: 설정 중 보낸 'Hi' 가 켜자마자 전송됨).
    /// 첫 실행(또는 상태 DB 초기화 뒤)엔 쌓인 업데이트를 전부 확인 처리(offset=최신+1)만 하고 보내지 않는다.
    /// - Returns: 기준선을 잡았으면 true. 실패는 상태 DB 에 오류로 남긴다(물러서기는 부른 쪽이 정한다).
    @discardableResult
    func establishTelegramBaseline() async -> Bool {
        let updates: [TGUpdate]
        do {
            updates = try await telegram.getUpdates(offset: 0, timeout: 0)
        } catch {
            telegramFailures += 1
            state.recordError(Self.explainTelegramFailure(error), code: ErrorCodes.of(error), at: clock.now)
            log("텔레그램 기준선 설정 실패, 다음 틱에 재시도: \(Self.explainTelegramFailure(error))")
            return false
        }
        let nextOffset = (updates.map(\.update_id).max() ?? -1) + 1
        do {
            try state.setTGOffset(nextOffset)
        } catch {
            log("텔레그램 기준선 저장 실패, 다음 틱에 재시도: \(error)")
            return false
        }
        noteTelegramOK()
        log("텔레그램 기준선 설정, 켜기 전 메시지 \(updates.count)건 건너뜀 offset=\(nextOffset)")
        if !updates.isEmpty {
            _ = try? await telegram.sendMessage("ℹ️ 켜기 전 메시지 \(updates.count)개는 보내지 않았습니다.")
        }
        return true
    }

    public var isHalted: Bool { state.haltReason != nil }

    func halt(_ reason: String) async {
        guard state.haltReason == nil else { return }
        try? state.setHalted(reason)
        log("안전 정지: \(reason)")
        logEvent(.info, "relay_halt", ["reason": .string(reason)])
        _ = try? await telegram.sendMessage("⏸ bluehop 안전 정지\n\(reason)\n재개: /resume")
    }

    /// 정지를 푼다. skipBacklog 면 iMessage 커서를 현재 끝으로 옮긴다.
    public func resume(skipBacklog: Bool) throws {
        if skipBacklog, let chat {
            try state.setIMsgCursor(try chatDB.maxRowID(chat: chat))
        }
        try state.setHalted(nil)
        log("재개 skipBacklog=\(skipBacklog)")
        logEvent(.info, "relay_resume", ["skip_backlog": .bool(skipBacklog)])
    }

    // MARK: - 루프

    /// 취소될 때까지 돈다. 취소는 await 지점에서만 반영되므로 이미 시작한 발송은 끝나고 outbox 에 기록된다.
    public func runForever() async {
        while !Task.isCancelled {
            await tick()
            await Task.yield()
        }
    }

    /// 일꾼 상태를 상태 DB 에 남긴다(`bluehop status` 가 읽는다). 정상 신호는 10초에 한 번만 쓴다.
    func noteTelegramOK() {
        if telegramFailures > 0 {
            telegramFailures = 0
            state.recordError(nil, at: clock.now)
        }
        if clock.now - lastHealthWrite >= 10 {
            lastHealthWrite = clock.now
            state.markTelegramOK(clock.now)
        }
    }

    /// getUpdates 실패: 그 일꾼만 3초부터 두 배씩 최대 60초까지 쉰다(다른 매핑은 영향 없음).
    func noteTelegramFailure(_ error: Error) async {
        telegramFailures += 1
        let why = Self.explainTelegramFailure(error)
        let backoff = Self.telegramBackoff(failures: telegramFailures)
        state.recordError(why, code: ErrorCodes.of(error), at: clock.now)
        log("getUpdates 실패(\(telegramFailures)회): \(why)")
        logEvent(.info, "tg_poll_error", ["attempt": .int(Int64(telegramFailures)), "code": .string(ErrorCodes.of(error)),
                                          "backoff_seconds": .double(backoff)])
        await clock.sleep(seconds: backoff)
    }

    static func telegramBackoff(failures: Int) -> Double {
        min(60, 3 * pow(2, Double(max(0, failures - 1))))
    }

    static func explainTelegramFailure(_ error: Error) -> String {
        if case TelegramError.api(_, let code, _) = error {
            if code == 401 || code == 404 { return "\(error) — 봇 토큰이 거부됨(폐기·오타). 새 토큰으로 매핑을 다시 추가" }
            if code == 409 { return "\(error) — 같은 봇 토큰으로 다른 곳이 getUpdates 중(웹훅 또는 다른 프로그램)" }
        }
        return "\(error)"
    }

    public func tick() async {
        await pollTelegram()
        if !isHalted {
            await pollIMessage()
        }
        await settleOutbox()
        try? state.purgeOutboxKeys(olderThan: clock.now - 3600)
        if clock.now - lastCleanup > 600 {
            lastCleanup = clock.now
            cleanupOutboxFiles()
        }
    }

    // MARK: - 텔레그램 → iMessage

    func pollTelegram() async {
        // start() 에서 기준선 설정이 네트워크 오류로 실패했을 수 있다 — 여기서 재시도(이 턴은 보내지 않음).
        if !state.hasTGBaseline {
            if !(await establishTelegramBaseline()), !Task.isCancelled {
                await clock.sleep(seconds: Self.telegramBackoff(failures: telegramFailures))
            }
            return
        }
        let updates: [TGUpdate]
        do {
            updates = try await telegram.getUpdates(offset: state.tgOffset, timeout: options.pollTimeout)
        } catch TelegramError.retryAfter(let s) {
            await clock.sleep(seconds: Double(s)); return
        } catch {
            if Task.isCancelled { return }
            await noteTelegramFailure(error)
            return
        }
        noteTelegramOK()
        for u in updates {
            await handle(update: u)
            // 처리 뒤에 offset 을 올린다. 처리 도중 죽어도 outbox 가 같은 메시지 재발송을 막는다.
            try? state.setTGOffset(u.update_id + 1)
        }
    }

    func isAllowed(chat: TGChat, from: TGUser?) -> Bool {
        chat.id == options.chatID && from?.id == options.allowedUserID && from?.is_bot != true
    }

    func handle(update u: TGUpdate) async {
        if let m = u.message {
            guard isAllowed(chat: m.chat, from: m.from) else { return }  // 다른 방·다른 사람: 내용을 보지 않는다
            await handle(message: m)
        } else if let m = u.edited_message {
            guard isAllowed(chat: m.chat, from: m.from) else { return }
            if !editNoticeSent.contains(m.message_id) {
                editNoticeSent.insert(m.message_id)
                _ = try? await telegram.sendMessage("✏️ 수정한 내용은 iMessage 로 다시 보내지 않습니다.", replyTo: m.message_id)
            }
        } else if let r = u.message_reaction {
            guard isAllowed(chat: r.chat, from: r.user) else { return }
            await handle(reaction: r, updateID: u.update_id)
        }
    }

    func handle(message m: TGMessage) async {
        let rawText = m.text ?? m.caption ?? ""
        var receivedFields: [String: LogValue] = ["tg_message_id": .int(m.message_id), "text_len": .int(Int64(rawText.count)),
                                                   "has_attachment": .bool(m.photo != nil || m.voice != nil || m.video_note != nil
                                                                           || m.audio != nil || m.document != nil || m.video != nil || m.animation != nil)]
        if capturesBodies { receivedFields["text"] = .string(rawText) }
        logEvent(.info, "tg_message_received", receivedFields)
        if m.text != nil, rawText.hasPrefix("/"), !rawText.hasPrefix("//") {
            await handle(command: rawText, messageID: m.message_id)
            return
        }
        // 텔레그램 쪽에 내 글이 끼었으니, 다음 iMessage 답글은 다시 원글에 답글로 건다.
        lastIMThread = nil
        // 멱등성: 이미 다룬 텔레그램 메시지는 어떤 이유로든 다시 보내지 않는다.
        if (try? state.hasOutbox(tgMessageID: m.message_id)) ?? true { return }

        // 중계기가 멈춰 있던 사이 쌓였다가 늦게 처리되는 글은, 늦게 도착한 지시가 엉뚱한 때 나가는 것을
        // 막기 위해 보내지 않는다(사고 2026-10-14 재발 방지 규칙). date 없는 테스트 fixture 는 건너뜀.
        if let date = m.date {
            let age = clock.now - Double(date)
            if age > options.lateMessageThreshold {
                try? recordRejected(m.message_id, "오래된 메시지(\(Int(age))초 전)")
                _ = try? await telegram.sendMessage("⚠️ 오래돼서 안 보냄 (\(Int(age / 60))분 전 메시지)", replyTo: m.message_id)
                return
            }
        }

        if let reason = state.haltReason {
            try? recordRejected(m.message_id, "정지 중")
            _ = try? await telegram.sendMessage("⏸ 정지 중이라 iMessage 로 보내지 않았습니다. (\(reason))", replyTo: m.message_id)
            return
        }

        var text = rawText.hasPrefix("//") ? String(rawText.dropFirst()) : rawText
        if let reply = m.reply_to_message {
            text = Self.quotePrefix(stripOwn(reply.text ?? reply.caption ?? "")) + (text.isEmpty ? "" : "\n" + text)
        }
        text = AttributedBody.clean(text)
        if text.count > options.limits.maxOutgoingTextLength {
            try? recordRejected(m.message_id, "글이 너무 김")
            _ = try? await telegram.sendMessage("⚠️ 글이 너무 길어(\(text.count)자, 한도 \(options.limits.maxOutgoingTextLength)자) 보내지 않았습니다.", replyTo: m.message_id)
            return
        }
        if m.sticker != nil {
            try? recordRejected(m.message_id, "스티커")
            _ = try? await telegram.sendMessage("⚠️ 스티커는 iMessage 로 보내지 않습니다.", replyTo: m.message_id)
            return
        }

        // 1) 첨부를 먼저 모두 내려받는다. 하나라도 실패하면 아무것도 보내지 않는다(반쪽 발송 방지).
        var files: [URL] = []
        do {
            files = try await stageAttachments(of: m)
            if !files.isEmpty {
                logEvent(.info, "attachment_relayed", ["direction": .string("tg_to_im"), "tg_message_id": .int(m.message_id), "count": .int(Int64(files.count))])
            }
        } catch {
            try? recordRejected(m.message_id, "첨부 받기 실패")
            _ = try? await telegram.sendMessage("⚠️ 첨부를 받지 못해 아무것도 보내지 않았습니다: \(error)", replyTo: m.message_id)
            logEvent(.info, "attachment_relay_failed", ["direction": .string("tg_to_im"), "tg_message_id": .int(m.message_id)])
            return
        }
        guard !files.isEmpty || !text.isEmpty else { return }
        if !files.isEmpty, options.requireMessagesReadableOutbox, !MessagesSandbox.canRead(options.outboxDir.path) {
            try? recordRejected(m.message_id, "첨부 폴더를 메시지 앱이 읽을 수 없음")
            _ = try? await telegram.sendMessage("⚠️ 첨부를 둔 폴더를 메시지 앱이 읽을 수 없어(샌드박스) 아무것도 보내지 않았습니다. 설정 outboxDirectory 를 비워 기본 폴더를 쓰세요.", replyTo: m.message_id)
            return
        }

        // 2) 보내기 전에 모든 부분을 'sending' 으로 기록 → 중간에 죽어도 다시 보내지 않는다.
        var parts: [(kind: String, payload: String, key: String)] = files.map { ("file", $0.path, $0.lastPathComponent) }
        if !text.isEmpty { parts.append(("text", text, text)) }
        let now = clock.now
        do {
            try state.transaction {
                for (i, p) in parts.enumerated() {
                    try state.insertOutbox(OutboxEntry(tgMessageID: m.message_id, part: i, kind: p.kind, matchKey: EchoKey.normalize(p.key),
                                                       status: .sending, createdAt: now, detail: nil))
                }
            }
        } catch {
            log("outbox 기록 실패 tg=\(m.message_id): \(error)")
            return  // 기록 못 하면 보내지 않는다
        }

        // 3) 차례로 보낸다. 실패하면 남은 부분도 보내지 않는다.
        var stop: String?
        for (i, p) in parts.enumerated() {
            if let s = stop {
                try? state.updateOutbox(tgMessageID: m.message_id, part: i, status: .failed, detail: s, clearKey: true)
                continue
            }
            guard toIMBreaker.allow() else {
                stop = "안전 정지"
                try? state.updateOutbox(tgMessageID: m.message_id, part: i, status: .failed, detail: stop, clearKey: true)
                await halt("10분 동안 iMessage 로 \(options.limits.toIMessagePerWindow)건 넘게 보내려 함")
                continue
            }
            await toIMLimiter.acquire()
            let t0 = clock.now
            logEvent(.debug, "im_send_start", ["tg_message_id": .int(m.message_id), "part": .int(Int64(i)), "kind": .string(p.kind)])
            do {
                if p.kind == "file" {
                    try sender.sendFile(p.payload, chatGuid: options.chatGuid)
                } else {
                    try sender.sendText(p.payload, chatGuid: options.chatGuid)
                }
                try? state.updateOutbox(tgMessageID: m.message_id, part: i, status: .sent)
                log("iMessage 로 보냄 tg=\(m.message_id) part=\(i) kind=\(p.kind)")
                logEvent(.info, "im_send_ok", ["tg_message_id": .int(m.message_id), "part": .int(Int64(i)), "kind": .string(p.kind),
                                               "ms": .int(Int64((clock.now - t0) * 1000))])
            } catch let error as SendError where error.isAmbiguousTimeout {
                // 메시지 앱에 전달됐는지 확인 못 함 — 곧바로 실패로 단정하지 않고 매칭 키를 그대로 둔 채
                // sendTimeoutGrace 동안 메아리 맞춤을 계속한다(남은 부분은 이 발송이 불확실한 채로 더
                // 보내지 않는다 — 반쪽 발송 방지는 그대로 지킨다).
                stop = "이전 부분 응답 없음(확인 안 됨)"
                try? state.updateOutbox(tgMessageID: m.message_id, part: i, status: .ambiguousTimeout, detail: "\(error)")
                log("iMessage 보내기 응답 없음(불확실) tg=\(m.message_id) part=\(i): \(error)")
                logEvent(.info, "im_send_ambiguous_timeout", ["tg_message_id": .int(m.message_id), "part": .int(Int64(i)), "kind": .string(p.kind),
                                                               "ms": .int(Int64((clock.now - t0) * 1000)), "grace_seconds": .double(options.sendTimeoutGrace)])
            } catch {
                stop = "메시지 앱 보내기 실패"
                try? state.updateOutbox(tgMessageID: m.message_id, part: i, status: .failed, detail: "\(error)", clearKey: true)
                log("iMessage 보내기 실패 tg=\(m.message_id) part=\(i): \(error)")
                logEvent(.info, "im_send_failed", ["tg_message_id": .int(m.message_id), "part": .int(Int64(i)), "kind": .string(p.kind),
                                                    "ms": .int(Int64((clock.now - t0) * 1000)), "detail": .string("\(error)".prefix(200).description)])
            }
        }
    }

    func recordRejected(_ tgMessageID: Int64, _ why: String) throws {
        try state.insertOutbox(OutboxEntry(tgMessageID: tgMessageID, part: 0, kind: "rejected", matchKey: nil,
                                           status: .failed, createdAt: clock.now, detail: why))
        try state.markNotified(tgMessageID: tgMessageID)
    }

    func stripOwn(_ s: String) -> String {
        s.hasPrefix(Self.ownPrefix) ? String(s.dropFirst(Self.ownPrefix.count)) : s
    }

    /// 텔레그램 첨부를 메시지별 폴더에 내려받는다. 음성(ogg)은 m4a 로 바꾼다.
    func stageAttachments(of m: TGMessage) async throws -> [URL] {
        var refs: [(id: String, name: String, size: Int64?, isVoice: Bool)] = []
        if let photos = m.photo, !photos.isEmpty {
            let best = photos.filter { ($0.file_size ?? 0) <= TelegramClient.maxDownloadBytes }
                .max { ($0.width ?? 0) * ($0.height ?? 0) < ($1.width ?? 0) * ($1.height ?? 0) } ?? photos.last!
            refs.append((best.file_id, "photo-\(m.message_id).jpg", best.file_size, false))
        }
        if let v = m.voice { refs.append((v.file_id, "voice-\(m.message_id).ogg", v.file_size, true)) }
        if let v = m.video_note { refs.append((v.file_id, "video-\(m.message_id).mp4", v.file_size, false)) }
        for f in [m.audio, m.document, m.video, m.animation].compactMap({ $0 }) {
            refs.append((f.file_id, AttachmentClassifier.safeFilename(f.file_name, fallback: "file-\(m.message_id)"), f.file_size, false))
        }
        guard !refs.isEmpty else { return [] }
        let dir = try OutboxStaging.freshDirectory(String(m.message_id), in: options.outboxDir)
        var out: [URL] = []
        for r in refs {
            if let s = r.size, s > TelegramClient.maxDownloadBytes { throw TelegramError.tooLarge(bytes: s) }
            let data = try await telegram.download(fileID: r.id)
            let url = dir.appendingPathComponent(r.name)
            try data.write(to: url, options: .atomic)
            if r.isVoice {
                out.append(try converter.toM4A(url, outputDir: dir))
                try? FileManager.default.removeItem(at: url)
            } else {
                out.append(url)
            }
        }
        return out
    }

    func handle(command raw: String, messageID: Int64) async {
        let parts = raw.split(separator: " ").map(String.init)
        let cmd = parts.first?.split(separator: "@").first.map(String.init) ?? ""
        switch cmd {
        case "/status":
            let reason = state.haltReason.map { "⏸ 정지: \($0)" } ?? "▶️ 동작 중"
            let backlog = chat.flatMap { try? chatDB.countAfter(state.imsgCursor ?? 0, chat: $0) } ?? 0
            _ = try? await telegram.sendMessage("\(reason)\n밀린 iMessage: \(backlog)건\n최근 10분: → 텔레그램 \(toTGBreaker.recentCount)건, → iMessage \(toIMBreaker.recentCount)건", replyTo: messageID)
        case "/pause":
            try? state.setHalted("/pause 로 멈춤")
            _ = try? await telegram.sendMessage("⏸ 정지했습니다. 재개: /resume", replyTo: messageID)
        case "/resume":
            let arg = parts.count > 1 ? parts[1] : ""
            let backlog = chat.flatMap { try? chatDB.countAfter(state.imsgCursor ?? 0, chat: $0) } ?? 0
            if arg != "skip" && arg != "all" && backlog > options.limits.maxBacklog {
                _ = try? await telegram.sendMessage("밀린 iMessage \(backlog)건이 있습니다. /resume skip (건너뛰기) 또는 /resume all (모두 보내기)", replyTo: messageID)
                return
            }
            try? resume(skipBacklog: arg == "skip")
            _ = try? await telegram.sendMessage("▶️ 재개했습니다\(arg == "skip" ? " (밀린 메시지 건너뜀)" : "").", replyTo: messageID)
        default:
            _ = try? await telegram.sendMessage("명령: /status /pause /resume\n'/' 로 시작하는 글을 보내려면 '//' 로 시작하세요.", replyTo: messageID)
        }
    }

    func handle(reaction r: TGMessageReactionUpdated, updateID: Int64) async {
        guard options.reactionMode == .text, !isHalted else { return }
        let added = r.new_reaction.compactMap(\.emoji).filter { e in !r.old_reaction.contains { $0.emoji == e } }
        guard let emoji = added.first else { return }  // 취소는 iMessage 에서 되돌릴 수 없어 무시
        let syntheticID = -updateID  // 반응에는 message_id 가 없어 update_id 로 멱등 키를 만든다
        if (try? state.hasOutbox(tgMessageID: syntheticID)) ?? true { return }
        logEvent(.info, "tg_reaction_received", ["tg_message_id": .int(r.message_id), "tg_update_id": .int(updateID)])
        var quoted = ""
        if let guid = try? state.imsgGuid(forTG: r.message_id), let chat,
           let original = try? chatDB.message(guid: guid, chat: chat) {
            quoted = original.text
        }
        let text = "\(emoji) " + Self.quotePrefix(stripOwn(quoted))
        do {
            try state.insertOutbox(OutboxEntry(tgMessageID: syntheticID, part: 0, kind: "text", matchKey: EchoKey.normalize(text),
                                               status: .sending, createdAt: clock.now, detail: "reaction:\(r.message_id)"))
        } catch { return }
        guard toIMBreaker.allow() else {
            try? state.updateOutbox(tgMessageID: syntheticID, part: 0, status: .failed, detail: "안전 정지", clearKey: true)
            await halt("10분 동안 iMessage 로 \(options.limits.toIMessagePerWindow)건 넘게 보내려 함")
            return
        }
        await toIMLimiter.acquire()
        do {
            try sender.sendText(text, chatGuid: options.chatGuid)
            try? state.updateOutbox(tgMessageID: syntheticID, part: 0, status: .sent)
        } catch {
            try? state.updateOutbox(tgMessageID: syntheticID, part: 0, status: .failed, detail: "\(error)", clearKey: true)
        }
    }

    /// 발송 결과를 정리해 사용자에게 알린다: 실패가 있을 때만 ⚠️ 답글로 알린다. 자동 재시도는 하지 않는다.
    /// 성공은 표시하지 않는다 — 사용자 글에 달리는 반응은 상대가 단 것만 남아야 헷갈리지 않는다.
    func settleOutbox() async {
        guard let ids = try? state.unnotifiedTGMessages() else { return }
        let now = clock.now
        for id in ids {
            guard var entries = try? state.outbox(tgMessageID: id), !entries.isEmpty else { continue }
            for (i, e) in entries.enumerated() {
                let age = now - e.createdAt
                switch e.status {
                case .sent where age > options.confirmTimeout:
                    try? state.updateOutbox(tgMessageID: id, part: e.part, status: .failed,
                                            detail: "\(Int(options.confirmTimeout))초 안에 메시지 앱 기록에서 확인되지 않음")
                    entries[i].status = .failed
                    logEvent(.info, "echo_giveup", ["tg_message_id": .int(id), "part": .int(Int64(e.part)), "from_status": .string("sent")])
                case .sending where age > options.confirmTimeout:
                    try? state.updateOutbox(tgMessageID: id, part: e.part, status: .failed,
                                            detail: "보내는 도중 중계기가 멈춤")
                    entries[i].status = .failed
                    logEvent(.info, "echo_giveup", ["tg_message_id": .int(id), "part": .int(Int64(e.part)), "from_status": .string("sending")])
                case .ambiguousTimeout where age > options.sendTimeoutGrace:
                    try? state.updateOutbox(tgMessageID: id, part: e.part, status: .failed,
                                            detail: "\(Int(options.sendTimeoutGrace))초 안에 메시지 앱 응답을 확인하지 못함")
                    entries[i].status = .failed
                    logEvent(.info, "echo_giveup", ["tg_message_id": .int(id), "part": .int(Int64(e.part)), "from_status": .string("ambiguousTimeout")])
                default: break
                }
            }
            let undecided = entries.contains { $0.status == .sending || $0.status == .sent || $0.status == .ambiguousTimeout }
            if undecided { continue }
            let failed = (try? state.outbox(tgMessageID: id))?.filter { $0.status == .failed } ?? []
            if !failed.isEmpty {
                let why = failed.compactMap(\.detail).first ?? "알 수 없음"
                let target: Int64? = id > 0 ? id : nil
                let what = id > 0 ? "이 메시지" : "반응"
                do {
                    try await telegram.sendMessage("⚠️ \(what)를 iMessage 로 보내지 못했거나 확인하지 못했습니다: \(why)\n자동으로 다시 보내지 않았습니다. 필요하면 iPhone 에서 확인 후 다시 보내 주세요.", replyTo: target)
                    logEvent(.info, "warn_sent", ["tg_message_id": .int(id)])
                } catch {
                    continue  // 알림을 못 보냈으면 다음 루프에 다시 시도
                }
            }
            try? state.markNotified(tgMessageID: id)
        }
    }

    /// 보낸 첨부 사본은 1시간 뒤에 지운다. 메시지 앱이 chat.db 에 기록한 뒤에도 업로드 중일 수 있어 바로 지우지 않고,
    /// 발송 결과가 아직 확인되지 않은(sending·sent) 메시지의 폴더는 시간이 지나도 남겨 둔다.
    func cleanupOutboxFiles(olderThan age: TimeInterval = 3600) {
        let fm = FileManager.default
        if let root = options.legacyOutboxRoot, let names = try? fm.contentsOfDirectory(atPath: root.path) {
            // 0.4.x 가 남긴 숫자 이름 폴더. 매핑 id 는 글자로 시작하므로 매핑 폴더와 겹치지 않는다.
            for name in names where Int64(name) != nil {
                let url = root.appendingPathComponent(name)
                if let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(m) > age {
                    try? fm.removeItem(at: url)
                }
            }
        }
        guard let names = try? fm.contentsOfDirectory(atPath: options.outboxDir.path) else { return }
        for name in names where Int64(name) != nil || name.hasPrefix(OutboxStaging.diagPrefix) {
            if let id = Int64(name), Self.isAwaitingResult((try? state.outbox(tgMessageID: id)) ?? []) { continue }
            let url = options.outboxDir.appendingPathComponent(name)
            if let m = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(m) > age {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func isAwaitingResult(_ entries: [OutboxEntry]) -> Bool {
        entries.contains { $0.status == .sending || $0.status == .sent || $0.status == .ambiguousTimeout }
    }

    // MARK: - iMessage → 텔레그램

    enum Outcome { case done, wait, retry }

    func pollIMessage() async {
        guard let chat else { return }
        let cursor = state.imsgCursor ?? 0
        if clock.now - lastScanWrite >= 10 {
            lastScanWrite = clock.now
            state.markIMessageScan(clock.now)
        }
        // 공용 감시가 "이 대화엔 커서 뒤 행이 없다"고 하면 행을 읽지 않는다. 기다리는 행(첨부·메아리 유예)이 있으면
        // 그 행이 커서 뒤에 있으므로 여기서 걸러지지 않는다.
        if let activity, let latest = activity.latestRowID(chat: chat.rowid), latest <= cursor { return }
        let messages: [IMMessage]
        do {
            messages = try chatDB.messages(after: cursor, chat: chat)
        } catch {
            log("chat.db 읽기 실패: \(error)")
            return
        }
        for m in messages {
            if isHalted { return }
            let outcome: Outcome
            do {
                outcome = try await relay(m)
            } catch TelegramError.retryAfter(let s) {
                await clock.sleep(seconds: Double(s)); return
            } catch {
                let n = (failedAttempts[m.rowid] ?? 0) + 1
                failedAttempts[m.rowid] = n
                log("rowid=\(m.rowid) 중계 실패(\(n)회): \(error)")
                if n < 5 { return }
                _ = try? await telegram.sendMessage("⚠️ iMessage 1건을 텔레그램으로 옮기지 못하고 건너뜀 (\(error))")
                outcome = .done
            }
            switch outcome {
            case .wait, .retry: return
            case .done:
                failedAttempts[m.rowid] = nil
                try? state.clearPending(rowid: m.rowid)
                try? state.setIMsgCursor(m.rowid)
            }
        }
    }

    func relay(_ m: IMMessage) async throws -> Outcome {
        var rowFields: [String: LogValue] = ["imsg_rowid": .int(m.rowid), "is_from_me": .bool(m.isFromMe), "text_len": .int(Int64(m.text.count))]
        if capturesBodies { rowFields["text"] = .string(m.text) }
        logEvent(.debug, "imsg_row_received", rowFields)
        if m.isRetracted || m.itemType != 0 { return .done }
        if m.isReaction { return try await relayReaction(m) }
        if m.associatedType != 0 { return .done }

        if m.isFromMe, try matchEcho(m) { return .done }
        if m.isFromMe, try state.hasUnresolvedOutbox() {
            // 아직 확인 못 한 텔레그램 발송이 있다 — 본문 비교가 못 맞춘 것일 수 있으니(사고 2026-10-14)
            // 곧바로 "직접 보낸 글"로 미러하지 않고 잠깐 기다려 메아리 맞춤에 재시도 기회를 준다.
            // 그래도 끝내 안 맞으면(정말 iPhone 에서 보낸 다른 글) 유예가 끝난 뒤 정상적으로 미러한다.
            let since = try state.pendingSince(rowid: m.rowid, now: clock.now)
            if clock.now - since < options.echoGraceSeconds {
                logEvent(.debug, "echo_wait", ["imsg_rowid": .int(m.rowid), "waited_seconds": .double(clock.now - since)])
                return .wait
            }
            logEchoMiss(m)
            logEvent(.info, "echo_unmatched", ["imsg_rowid": .int(m.rowid)])
        }
        if m.isFromMe && !options.mirrorOwnMessages { return .done }

        // 첨부가 아직 안 내려왔으면 기다린다(커서 정지).
        let missing = m.attachments.filter { $0.path == nil }
        if !missing.isEmpty {
            let since = try state.pendingSince(rowid: m.rowid, now: clock.now)
            if clock.now - since < options.attachmentWait {
                logEvent(.debug, "attachment_wait", ["imsg_rowid": .int(m.rowid), "waited_seconds": .double(clock.now - since)])
                return .wait
            }
        }

        var replyTo: Int64?
        var quote = ""
        if let origin = m.threadOriginatorGuid {
            let part = m.threadOriginatorPart?.split(separator: ":").first.flatMap { Int($0) }
            replyTo = try state.tgMessageID(forGuid: origin, part: part)
            if replyTo == nil, let chat, let original = try chatDB.message(guid: origin, chat: chat) {
                quote = Self.quotePrefix(original.text) + "\n"
            }
        }
        // 같은 원글에 연달아 단 답글은 첫 말풍선만 답글로 건다(텔레그램은 말풍선마다 인용 머리를 그린다).
        let thread = m.threadOriginatorGuid.map { origin in replyTo.map { "tg:\($0)" } ?? "im:\(origin)" }
        if thread != nil, thread == lastIMThread {
            replyTo = nil
            quote = ""
        }
        let own = m.isFromMe ? Self.ownPrefix : ""
        var part = 0
        // 이미 보낸 부분(앞선 시도에서 일부만 성공)은 건너뛴다 → 재시도해도 중복 없음.
        for a in m.attachments {
            if try !state.hasMapping(imsgGuid: m.guid, part: part) {
                let id = try await sendAttachment(a, isAudioMessage: m.isAudioMessage, caption: m.isFromMe ? "🙋 나" : nil, replyTo: replyTo)
                try state.saveMapping(imsgGuid: m.guid, part: part, tgMessageID: id, direction: "im->tg", now: clock.now)
            }
            part += 1
        }
        let body = Self.telegramBody(of: m)
        if !body.text.isEmpty, try !state.hasMapping(imsgGuid: m.guid, part: part) {
            let id = try await sendTG(own + quote + body.text, replyTo: m.attachments.isEmpty ? replyTo : nil,
                                      linkPreviewURL: body.previewURL)
            try state.saveMapping(imsgGuid: m.guid, part: part, tgMessageID: id, direction: "im->tg", now: clock.now)
        }
        if !m.attachments.isEmpty || !body.text.isEmpty { lastIMThread = thread }
        return .done
    }

    /// 중계기가 보낸 글·파일이 chat.db 에 기록된 것인지 맞춰 본다. 맞으면 매핑만 저장하고 다시 보내지 않는다.
    func matchEcho(_ m: IMMessage) throws -> Bool {
        var candidates: [(String, String)] = m.attachments.map { ("file", $0.transferName) }
        if !m.text.isEmpty { candidates.append(("text", m.text)) }
        var matched = false
        for (kind, key) in candidates {
            guard let e = try state.oldestAwaitingEcho(kind: kind, matchKey: EchoKey.normalize(key)) else { continue }
            if m.errorCode != 0 {
                try state.updateOutbox(tgMessageID: e.tgMessageID, part: e.part, status: .failed,
                                       detail: MessagesSandbox.failureDetail(kind: kind, errorCode: m.errorCode, outboxDir: options.outboxDir.path),
                                       matchedGuid: m.guid, clearKey: true)
            } else {
                try state.updateOutbox(tgMessageID: e.tgMessageID, part: e.part, status: .confirmed, matchedGuid: m.guid, clearKey: true)
            }
            if e.tgMessageID > 0 {
                try state.saveMapping(imsgGuid: m.guid, part: matched ? 1 : 0, tgMessageID: e.tgMessageID, direction: "tg->im", now: clock.now)
            }
            matched = true
            logEvent(.info, "echo_matched", ["imsg_rowid": .int(m.rowid), "tg_message_id": .int(e.tgMessageID), "part": .int(Int64(e.part)),
                                              "kind": .string(kind), "error_code": .int(Int64(m.errorCode))])
        }
        if matched { log("메아리 확인 rowid=\(m.rowid)") }
        return matched
    }

    /// 유예가 끝나도 못 맞춘 내 메시지를 "직접 보낸 글"로 올리기 전에, 기다리던 발송과 얼마나
    /// 닮았는지 남긴다(본문 없이 길이·해시·같은 앞부분 길이만). 다음 불일치의 원인을 바로 좁히기 위함.
    func logEchoMiss(_ m: IMMessage) {
        let got = EchoKey.normalize(m.text)
        let waiting = (try? state.awaitingEchoes()) ?? []
        for e in waiting {
            let key = e.matchKey ?? ""
            log("메아리 불일치 rowid=\(m.rowid) 후보 tg=\(e.tgMessageID) part=\(e.part) kind=\(e.kind) "
                + "받은 \(EchoKey.fingerprint(got)) 기다림 \(EchoKey.fingerprint(key)) 같은앞부분=\(EchoKey.commonPrefix(got, key))")
            logEvent(.debug, "echo_mismatch", ["imsg_rowid": .int(m.rowid), "tg_message_id": .int(e.tgMessageID), "part": .int(Int64(e.part)),
                                                "kind": .string(e.kind), "common_prefix_len": .int(Int64(EchoKey.commonPrefix(got, key)))])
        }
    }

    func relayReaction(_ m: IMMessage) async throws -> Outcome {
        guard let tb = Tapback.parse(type: m.associatedType, associatedGuid: m.associatedGuid, emoji: m.associatedEmoji) else { return .done }
        let target = try state.tgMessageID(forGuid: tb.targetGuid, part: tb.targetPart)
        let label = tb.emoji ?? "스티커"
        logEvent(.info, "imsg_reaction_received", ["imsg_rowid": .int(m.rowid), "is_from_me": .bool(m.isFromMe),
                                                     "action": .string("\(tb.action)"), "tg_message_id": .int(target ?? 0)])

        if m.isFromMe {
            // 내 반응은 봇 반응으로 달면 상대 반응처럼 보이므로 글로만 보인다.
            guard options.mirrorOwnMessages, tb.action == .add else { return .done }
            lastIMThread = nil
            _ = try await sendTG(Self.ownPrefix + "\(label) 반응" + (target == nil ? " " + (try quoteOf(tb.targetGuid)) : ""), replyTo: target)
            return .done
        }

        switch tb.action {
        case .add:
            if let target, let emoji = tb.emoji, let tgEmoji = TelegramReactions.telegramEmoji(for: emoji) {
                do {
                    try await setReaction(target, tgEmoji)
                    return .done
                } catch TelegramError.api {
                    // 봇이 못 다는 반응 → 아래 글 대체로
                }
            }
            lastIMThread = nil
            _ = try await sendTG("\(label) 반응" + (target == nil ? " " + (try quoteOf(tb.targetGuid)) : ""), replyTo: target)
        case .remove:
            if let target, try state.reaction(onTG: target) != nil {
                try await setReaction(target, nil)
            }
        }
        return .done
    }

    func quoteOf(_ guid: String) throws -> String {
        guard let chat, let original = try chatDB.message(guid: guid, chat: chat) else { return Self.quotePrefix("") }
        return Self.quotePrefix(original.text)
    }

    func setReaction(_ target: Int64, _ emoji: String?) async throws {
        guard toTGBreaker.allow() else {
            await halt("10분 동안 텔레그램으로 \(options.limits.toTelegramPerWindow)건 넘게 보내려 함")
            throw SendError("안전 정지")
        }
        await toTGLimiter.acquire()
        try await telegram.setMessageReaction(messageID: target, emoji: emoji)
        try state.setReaction(onTG: target, emoji)
    }

    /// iMessage 행을 텔레그램 글로 옮길 모양. 링크 말풍선은 제목·주소 한 통 + 미리보기,
    /// 내용 없이 말풍선 앱 자료만 있는 행은 무엇을 못 옮겼는지 한 줄로 남긴다(조용히 사라지지 않게).
    static func telegramBody(of m: IMMessage) -> (text: String, previewURL: String?) {
        if m.isURLBalloon { return RichLink.telegramText(body: m.text, metadata: m.linkMetadata) }
        if m.text.isEmpty, m.attachments.isEmpty, let bundle = m.balloonBundleID {
            let app = bundle.split(separator: ":").last.map(String.init) ?? bundle
            return ("[iMessage 앱 메시지라 옮기지 못함: \(app)]", nil)
        }
        return (m.text, nil)
    }

    func sendTG(_ text: String, replyTo: Int64?, linkPreviewURL: String? = nil) async throws -> Int64 {
        guard toTGBreaker.allow() else {
            await halt("10분 동안 텔레그램으로 \(options.limits.toTelegramPerWindow)건 넘게 보내려 함")
            throw SendError("안전 정지")
        }
        await toTGLimiter.acquire()
        // 텔레그램 한 메시지 한도 4096자. 넘으면 잘라 여러 번 보내고 첫 메시지를 매핑한다.
        let chunks = Self.chunk(text, size: 4000)
        var first: Int64?
        for c in chunks {
            let id = try await telegram.sendMessage(c, replyTo: first == nil ? replyTo : first,
                                                    linkPreviewURL: first == nil ? linkPreviewURL : nil)
            if first == nil { first = id }
        }
        return first!
    }

    func sendAttachment(_ a: IMAttachment, isAudioMessage: Bool, caption: String?, replyTo: Int64?) async throws -> Int64 {
        guard let path = a.path else {
            return try await sendTG("[첨부를 받지 못함: \(a.transferName)]", replyTo: replyTo)
        }
        let size = a.totalBytes > 0 ? a.totalBytes : Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.int64Value ?? 0)
        if size > AttachmentClassifier.maxUploadBytes {
            return try await sendTG("[첨부가 너무 큼: \(a.transferName), \(size / 1_048_576)MB]", replyTo: replyTo)
        }
        guard toTGBreaker.allow() else {
            await halt("10분 동안 텔레그램으로 \(options.limits.toTelegramPerWindow)건 넘게 보내려 함")
            throw SendError("안전 정지")
        }
        await toTGLimiter.acquire()

        let src = URL(fileURLWithPath: path)
        let work = options.tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let plan = AttachmentClassifier.plan(filename: a.transferName, mimeType: a.mimeType, uti: a.uti, isAudioMessage: isAudioMessage, bytes: size)
        var file = src
        var kind: TGMediaKind = .document
        do {
            switch plan {
            case .photo(let conv):
                kind = .photo
                if conv { file = try converter.toJPEG(src, outputDir: work) }
            case .voice(let conv):
                kind = .voice
                if conv { file = try converter.toM4A(src, outputDir: work) }
            case .audio(let conv):
                kind = .audio
                if conv { file = try converter.toM4A(src, outputDir: work) }
            case .video: kind = .video
            case .document: kind = .document
            }
        } catch {
            log("변환 실패, 원본을 파일로 보냄: \(error)")
            file = src
            kind = .document
        }
        let name = kind == .document ? a.transferName : file.lastPathComponent
        logEvent(.info, "attachment_relayed", ["direction": .string("im_to_tg"), "kind": .string("\(kind)"), "bytes": .int(size)])
        do {
            return try await telegram.sendMedia(kind, fileURL: file, filename: name, mimeType: AttachmentClassifier.mime(for: file.lastPathComponent),
                                                caption: caption, replyTo: replyTo)
        } catch TelegramError.api where kind != .document {
            // 음성·사진 형식으로 거부되면 원본을 파일로 한 번 더.
            if kind == .voice {
                if let id = try? await telegram.sendMedia(.audio, fileURL: file, filename: name, mimeType: AttachmentClassifier.mime(for: name), caption: caption, replyTo: replyTo) {
                    return id
                }
            }
            return try await telegram.sendMedia(.document, fileURL: src, filename: a.transferName,
                                                mimeType: a.mimeType ?? AttachmentClassifier.mime(for: a.transferName), caption: caption, replyTo: replyTo)
        }
    }

    // MARK: - 도우미

    /// `↪ "원문 앞부분…"` 접두. 줄바꿈은 공백으로, 30자 넘으면 자른다.
    public static func quotePrefix(_ original: String, limit: Int = 30) -> String {
        let flat = original.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if flat.isEmpty { return "↪ (첨부)" }
        let cut = flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        return "↪ \"\(cut)\""
    }

    static func chunk(_ s: String, size: Int) -> [String] {
        guard s.count > size else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            out.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return out
    }
}
