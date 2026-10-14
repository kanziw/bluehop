import Foundation

public struct IMAttachment: Equatable {
    public var rowid: Int64
    public var guid: String
    /// 검증을 통과한 실제 파일 경로. 파일이 아직 없거나 허용 폴더 밖이면 nil.
    public var path: String?
    public var transferName: String
    public var mimeType: String?
    public var uti: String?
    public var totalBytes: Int64
    public var isSticker: Bool
}

public struct IMMessage: Equatable {
    public var rowid: Int64
    public var guid: String
    public var isFromMe: Bool
    public var text: String
    public var threadOriginatorGuid: String?
    public var threadOriginatorPart: String?
    public var associatedType: Int
    public var associatedGuid: String?
    public var associatedEmoji: String?
    public var isAudioMessage: Bool
    public var itemType: Int
    public var isRetracted: Bool
    /// message.error — 0 이 아니면 메시지 앱이 보내기 실패로 표시한 것
    public var errorCode: Int = 0
    public var attachments: [IMAttachment]

    public var isReaction: Bool { (2000...3999).contains(associatedType) }
}

public struct ChatInfo: Equatable {
    public var rowid: Int64
    public var guid: String
    public var handle: String
}

public enum ChatDBError: Error, CustomStringConvertible {
    case chatNotFound
    case notOneToOne(style: Int64, participants: Int)
    case handleMismatch

    public var description: String {
        switch self {
        case .chatNotFound: return "설정한 chatGuid 의 대화를 chat.db 에서 찾지 못했다"
        case .notOneToOne(let style, let n): return "1:1 대화가 아니다 (style=\(style), 참가자 \(n)명) — 단체방은 묶지 않는다"
        case .handleMismatch: return "대화 참가자가 설정의 handle 과 다르다"
        }
    }
}

/// chat.db 읽기 전용 리더. 모든 메시지 질의는 고정된 chat ROWID 하나로 한정한다.
public final class ChatDB {
    let db: SQLiteDB
    let attachmentsRoot: String
    /// `messages(after:chat:)` 를 부른 횟수(공용 감시가 헛조회를 줄이는지 테스트가 본다).
    public private(set) var messageQueryCount = 0

    /// - Parameters:
    ///   - path: chat.db 경로. 항상 `SQLITE_OPEN_READONLY` 로 연다.
    ///   - attachmentsRoot: 첨부 파일을 읽어도 되는 유일한 폴더(기본 `~/Library/Messages/Attachments`).
    public init(path: String, attachmentsRoot: String) throws {
        self.db = try SQLiteDB(path: path, mode: .readOnly)
        self.attachmentsRoot = (attachmentsRoot as NSString).resolvingSymlinksInPath
    }

    /// 설정의 대화가 1:1 이고 참가자가 설정 handle 하나뿐인지 검증한다.
    public func resolveChat(guid: String, expectedHandle: String) throws -> ChatInfo {
        let rows = try db.query("SELECT ROWID, style FROM chat WHERE guid = ?", [.text(guid)]) {
            ($0.int(0) ?? 0, $0.int(1) ?? 0)
        }
        guard let (rowid, style) = rows.first else { throw ChatDBError.chatNotFound }
        let handles = try db.query("""
            SELECT h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id = ?
            """, [.int(rowid)]) { $0.text(0) ?? "" }
        guard style == 45, handles.count == 1 else {
            throw ChatDBError.notOneToOne(style: style, participants: handles.count)
        }
        guard MappingRules.normalizeHandle(handles[0]) == MappingRules.normalizeHandle(expectedHandle) else {
            throw ChatDBError.handleMismatch
        }
        return ChatInfo(rowid: rowid, guid: guid, handle: handles[0])
    }

    /// 읽기가 되는지만 확인한다(전체 디스크 접근 권한이 없으면 여기서 실패).
    public func probe() throws {
        _ = try db.query("SELECT 1 FROM chat LIMIT 1") { _ in true }
    }

    public func maxRowID(chat: ChatInfo) throws -> Int64 {
        try db.query("SELECT IFNULL(MAX(message_id), 0) FROM chat_message_join WHERE chat_id = ?", [.int(chat.rowid)]) {
            $0.int(0) ?? 0
        }.first ?? 0
    }

    public func countAfter(_ cursor: Int64, chat: ChatInfo) throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM chat_message_join WHERE chat_id = ? AND message_id > ?",
                         [.int(chat.rowid), .int(cursor)]) { $0.int(0) ?? 0 }.first ?? 0)
    }

    private static let messageColumns = """
        m.ROWID, m.guid, m.is_from_me, m.text, m.attributedBody, m.thread_originator_guid,
        m.thread_originator_part, m.associated_message_type, m.associated_message_guid,
        m.associated_message_emoji, m.is_audio_message, m.item_type, m.date_retracted, m.error
        """

    public func messages(after cursor: Int64, chat: ChatInfo, limit: Int = 50) throws -> [IMMessage] {
        messageQueryCount += 1
        let rows = try db.query("""
            SELECT \(Self.messageColumns)
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.ROWID > ?
            ORDER BY m.ROWID ASC LIMIT ?
            """, [.int(chat.rowid), .int(cursor), .int(Int64(limit))], map: Self.mapMessage)
        return try rows.map { msg in
            var msg = msg
            msg.attachments = try attachments(messageRowID: msg.rowid)
            return msg
        }
    }

    /// 같은 대화 안에서만 guid 로 메시지를 찾는다(답글 인용·반응 대체 표현용).
    public func message(guid: String, chat: ChatInfo) throws -> IMMessage? {
        try db.query("""
            SELECT \(Self.messageColumns)
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.guid = ? LIMIT 1
            """, [.int(chat.rowid), .text(guid)], map: Self.mapMessage).first
    }

    private static func mapMessage(_ r: SQLiteDB.Row) -> IMMessage {
        var text = r.text(3)
        if text == nil || text!.isEmpty, let blob = r.blob(4) {
            text = AttributedBody.extractText(blob)
        }
        return IMMessage(
            rowid: r.int(0) ?? 0,
            guid: r.text(1) ?? "",
            isFromMe: (r.int(2) ?? 0) != 0,
            text: AttributedBody.clean(text),
            threadOriginatorGuid: r.text(5).flatMap { $0.isEmpty ? nil : $0 },
            threadOriginatorPart: r.text(6),
            associatedType: Int(r.int(7) ?? 0),
            associatedGuid: r.text(8),
            associatedEmoji: r.text(9),
            isAudioMessage: (r.int(10) ?? 0) != 0,
            itemType: Int(r.int(11) ?? 0),
            isRetracted: (r.int(12) ?? 0) != 0,
            errorCode: Int(r.int(13) ?? 0),
            attachments: []
        )
    }

    func attachments(messageRowID: Int64) throws -> [IMAttachment] {
        try db.query("""
            SELECT a.ROWID, a.guid, a.filename, a.transfer_name, a.mime_type, a.uti, a.total_bytes, a.is_sticker
            FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ? ORDER BY a.ROWID
            """, [.int(messageRowID)]) { r in
            let raw = r.text(2)
            return IMAttachment(
                rowid: r.int(0) ?? 0,
                guid: r.text(1) ?? "",
                path: raw.flatMap(self.safeAttachmentPath),
                transferName: r.text(3) ?? ((raw ?? "file") as NSString).lastPathComponent,
                mimeType: r.text(4),
                uti: r.text(5),
                totalBytes: r.int(6) ?? 0,
                isSticker: (r.int(7) ?? 0) != 0
            )
        }
    }

    /// 첨부 경로를 펼치고, 심볼릭 링크를 따라간 실제 경로가 허용 폴더 안에 있고 파일이 있을 때만 돌려준다.
    func safeAttachmentPath(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        let real = (expanded as NSString).resolvingSymlinksInPath
        guard real.hasPrefix(attachmentsRoot + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return real
    }

    public struct ChatSummary: Equatable {
        public var guid: String
        public var handle: String
        public var lastRowID: Int64
        /// chat.service_name (예: iMessage, SMS). 없으면 nil.
        public var service: String?
        /// 마지막 메시지 시각(유닉스초). 메시지가 없으면 nil.
        public var lastMessageAt: Double?
        public init(guid: String, handle: String, lastRowID: Int64, service: String? = nil, lastMessageAt: Double? = nil) {
            self.guid = guid
            self.handle = handle
            self.lastRowID = lastRowID
            self.service = service
            self.lastMessageAt = lastMessageAt
        }
    }

    /// `chats` 용: 1:1 대화 식별자·상대 handle·서비스·마지막 시각만(본문 없음). 최근 순.
    public func listOneToOneChats(limit: Int = 30) throws -> [ChatSummary] {
        let hasService = try columnExists(table: "chat", column: "service_name")
        let rows = try db.query("""
            SELECT c.guid, h.id, IFNULL(MAX(cmj.message_id), 0) AS last, \(hasService ? "c.service_name" : "NULL")
            FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
            WHERE c.style = 45
            GROUP BY c.ROWID
            HAVING COUNT(DISTINCT chj.handle_id) = 1
            ORDER BY last DESC LIMIT ?
            """, [.int(Int64(limit))]) { ChatSummary(guid: $0.text(0) ?? "", handle: $0.text(1) ?? "", lastRowID: $0.int(2) ?? 0, service: $0.text(3)) }
        return try rows.map { c in
            var c = c
            if c.lastRowID > 0 {
                let raw = try db.query("SELECT date FROM message WHERE ROWID = ?", [.int(c.lastRowID)]) { $0.int(0) }.first ?? nil
                c.lastMessageAt = raw.flatMap(Self.unixTime(appleDate:))
            }
            return c
        }
    }

    func columnExists(table: String, column: String) throws -> Bool {
        try db.query("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", [.text(table), .text(column)]) { _ in true }.first ?? false
    }

    /// message.date: 2001-01-01 기준. 예전 macOS 는 초, 지금은 나노초.
    public static func unixTime(appleDate raw: Int64) -> Double? {
        guard raw > 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return seconds + 978_307_200
    }

    /// 여러 대화의 마지막 메시지 ROWID 를 한 번의 질의로 읽는다(공용 감시용). 설정한 대화 ROWID 로만 한정한다.
    public func latestRowIDs(chats: [Int64]) throws -> [Int64: Int64] {
        guard !chats.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: chats.count).joined(separator: ", ")
        var out: [Int64: Int64] = [:]
        for (chat, last) in try db.query("""
            SELECT chat_id, MAX(message_id) FROM chat_message_join WHERE chat_id IN (\(marks)) GROUP BY chat_id
            """, chats.map { .int($0) }, map: { ($0.int(0) ?? 0, $0.int(1) ?? 0) }) {
            out[chat] = last
        }
        return out
    }

    /// 자가 점검용: text 와 attributedBody 가 둘 다 있는 행에서 추출 결과가 text 와 같은지 센다(본문은 밖으로 안 냄).
    public func attributedBodySelfCheck(chat: ChatInfo, limit: Int) throws -> (checked: Int, matched: Int, onlyBlob: Int, onlyBlobExtracted: Int) {
        var checked = 0, matched = 0, onlyBlob = 0, extracted = 0
        try db.query("""
            SELECT m.text, m.attributedBody
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.attributedBody IS NOT NULL ORDER BY m.ROWID DESC LIMIT ?
            """, [.int(chat.rowid), .int(Int64(limit))]) { r in
            let t = r.text(0)
            let got = r.blob(1).flatMap(AttributedBody.extractText)
            if let t, !t.isEmpty {
                checked += 1
                if got == t { matched += 1 }
            } else {
                onlyBlob += 1
                if let got, !got.isEmpty { extracted += 1 }
            }
        }
        return (checked, matched, onlyBlob, extracted)
    }
}

// MARK: - 진단(diag-echo): 본문은 밖으로 내지 않고 모양만 본다
extension ChatDB {
    public struct RawOwnRow {
        public var rowid: Int64
        public var text: String?
        public var attributedBody: Data?
        public var date: Int64
        public var error: Int64
        public var itemType: Int64
        public var associatedType: Int64
        public var balloonBundleID: String?
    }

    /// `diag-echo` 용: 고정 대화에서 `after` 뒤의 내 메시지 행을 가공 없이 돌려준다.
    public func rawOwnRows(after: Int64, chat: ChatInfo, limit: Int = 50) throws -> [RawOwnRow] {
        try db.query("""
            SELECT m.ROWID, m.text, m.attributedBody, m.date, m.error, m.item_type, m.associated_message_type, m.balloon_bundle_id
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.ROWID > ? AND m.is_from_me = 1
            ORDER BY m.ROWID ASC LIMIT ?
            """, [.int(chat.rowid), .int(after), .int(Int64(limit))]) { r in
            RawOwnRow(rowid: r.int(0) ?? 0, text: r.text(1), attributedBody: r.blob(2), date: r.int(3) ?? 0,
                      error: r.int(4) ?? 0, itemType: r.int(5) ?? 0, associatedType: r.int(6) ?? 0,
                      balloonBundleID: r.text(7))
        }
    }
}

// MARK: - 진단(diag-send-file): 내가 보낸 행의 전송 상태만 본다(본문 없음)
extension ChatDB {
    public struct SendDiagAttachment {
        public var transferState: Int64
        /// chat.db 에 적힌 파일 경로(펼친 값). 출력할 때는 위치 분류만 쓴다.
        public var filename: String
        public var mimeType: String?
    }
    public struct SendDiagRow {
        public var rowid: Int64
        public var error: Int64
        public var isSent: Bool
        public var isDelivered: Bool
        public var service: String?
        public var hasText: Bool
        public var attachments: [SendDiagAttachment]
    }

    /// 고정 대화에서 `after` 뒤의 내 메시지 행의 전송 상태를 돌려준다.
    public func sendDiagRows(after: Int64, chat: ChatInfo) throws -> [SendDiagRow] {
        var rows = try db.query("""
            SELECT m.ROWID, m.error, m.is_sent, m.is_delivered, m.service,
                   (m.text IS NOT NULL AND m.text != '') OR m.attributedBody IS NOT NULL
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ? AND m.ROWID > ? AND m.is_from_me = 1
            ORDER BY m.ROWID ASC LIMIT 20
            """, [.int(chat.rowid), .int(after)]) { r in
            SendDiagRow(rowid: r.int(0) ?? 0, error: r.int(1) ?? 0, isSent: (r.int(2) ?? 0) != 0,
                        isDelivered: (r.int(3) ?? 0) != 0, service: r.text(4), hasText: (r.int(5) ?? 0) != 0, attachments: [])
        }
        for i in rows.indices {
            rows[i].attachments = try db.query("""
                SELECT a.transfer_state, a.filename, a.mime_type
                FROM message_attachment_join maj JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id = ? ORDER BY a.ROWID
                """, [.int(rows[i].rowid)]) { r in
                SendDiagAttachment(transferState: r.int(0) ?? -1,
                                   filename: ((r.text(1) ?? "") as NSString).expandingTildeInPath, mimeType: r.text(2))
            }
        }
        return rows
    }
}

// MARK: - 진단(diag-audio): 오디오 첨부 행의 메타만 본다(본문·음성 내용 없음)
extension ChatDB {
    public struct AudioDiagRow {
        public var rowid: Int64
        public var isFromMe: Bool
        public var isAudioMessage: Bool
        public var expireState: Int64
        public var itemType: Int64
        public var balloonBundleID: String?
        public var mimeType: String?
        public var uti: String?
        public var transferName: String
        public var fileExtension: String
        public var totalBytes: Int64
        /// 허용 폴더 안의 실제 파일 경로(코덱 확인용). 출력하지 않는다.
        public var path: String?
    }

    /// 고정 대화에서 오디오로 보이는 첨부(mime audio/*, 음성 메시지 플래그, .caf/.m4a 등)가 달린 행을 최근 순으로 돌려준다.
    public func audioDiagRows(chat: ChatInfo, limit: Int = 30) throws -> [AudioDiagRow] {
        try db.query("""
            SELECT m.ROWID, m.is_from_me, m.is_audio_message, m.expire_state, m.item_type, m.balloon_bundle_id,
                   a.mime_type, a.uti, a.transfer_name, a.filename, a.total_bytes
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE cmj.chat_id = ?
              AND (m.is_audio_message = 1 OR a.mime_type LIKE 'audio/%' OR a.uti LIKE '%audio%'
                   OR lower(a.transfer_name) LIKE '%.caf' OR lower(a.transfer_name) LIKE '%.m4a')
            ORDER BY m.ROWID DESC LIMIT ?
            """, [.int(chat.rowid), .int(Int64(limit))]) { r in
            let raw = r.text(9)
            let name = r.text(8) ?? ((raw ?? "") as NSString).lastPathComponent
            return AudioDiagRow(rowid: r.int(0) ?? 0, isFromMe: (r.int(1) ?? 0) != 0, isAudioMessage: (r.int(2) ?? 0) != 0,
                                expireState: r.int(3) ?? 0, itemType: r.int(4) ?? 0, balloonBundleID: r.text(5),
                                mimeType: r.text(6), uti: r.text(7), transferName: name,
                                fileExtension: ((raw ?? name) as NSString).pathExtension.lowercased(),
                                totalBytes: r.int(10) ?? 0, path: raw.flatMap(self.safeAttachmentPath))
        }
    }

    /// 파일 이름을 개인 정보 없이 분류한다. 아이폰 음성 메시지 이름("Audio Message.caf")과 중계기 이름(voice-<id>.m4a)만 그대로 알려 준다.
    public static func transferNameClass(_ name: String) -> String {
        if name == "Audio Message.caf" { return "\"Audio Message.caf\"" }
        if name.range(of: #"^voice-\d+\.[a-z0-9]+$"#, options: .regularExpression) != nil { return "voice-<id>.\((name as NSString).pathExtension)" }
        return "기타(.\((name as NSString).pathExtension.lowercased()))"
    }
}

/// 여러 매핑이 함께 쓰는 chat.db 변화 감시. 감시 중인 대화들의 마지막 ROWID 를 한 번의 질의로 읽어 두고
/// (최소 `minInterval` 초 간격), 각 일꾼은 자기 대화에 커서 뒤 행이 있을 때만 행을 읽는다.
/// 일꾼들이 서로 다른 스레드에서 부르므로 잠금으로 감싼다(연결도 이 객체만 쓴다).
public final class ChatActivity {
    let db: ChatDB
    let minInterval: Double
    let now: () -> Double
    let lock = NSLock()
    var watched: Set<Int64> = []
    var latest: [Int64: Int64] = [:]
    var lastRefresh = -Double.infinity
    var refreshes = 0

    public init(chatDB: ChatDB, minInterval: Double = 1.0, now: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.db = chatDB
        self.minInterval = minInterval
        self.now = now
    }

    public func watch(_ chatRowID: Int64) {
        lock.lock(); defer { lock.unlock() }
        if watched.insert(chatRowID).inserted { lastRefresh = -Double.infinity }
    }

    /// 지금까지 한 묶음 질의 횟수.
    public var refreshCount: Int { lock.lock(); defer { lock.unlock() }; return refreshes }

    /// 그 대화의 마지막 메시지 ROWID. 읽기에 실패하면 nil(일꾼이 직접 조회한다).
    public func latestRowID(chat: Int64) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard watched.contains(chat) else { return nil }
        let t = now()
        if t - lastRefresh >= minInterval {
            guard let fresh = try? db.latestRowIDs(chats: watched.sorted()) else { return nil }
            latest = fresh
            lastRefresh = t
            refreshes += 1
        }
        return latest[chat] ?? 0
    }
}
