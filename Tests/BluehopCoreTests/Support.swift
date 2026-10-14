import Foundation
import XCTest
@testable import BluehopCore

// MARK: - 임시 폴더

func makeTempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("bluehop-test-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return u
}

// MARK: - fixture chat.db (실제 chat.db 를 쓰지 않는다)

/// chat.db 의 필요한 테이블만 같은 이름·컬럼으로 만든 테스트용 DB.
final class FixtureChatDB {
    let dir: URL
    let path: String
    let attachmentsRoot: URL
    let db: SQLiteDB
    private(set) var guidCounter = 0
    /// 여러 일꾼(다른 스레드)이 메아리를 동시에 써 넣을 수 있어 잠근다.
    let lock = NSRecursiveLock()

    /// 기본 대화: chat rowid 1 = 1:1 (handle +821011112222), chat rowid 2 = 다른 1:1, chat rowid 3 = 단체방
    init() throws {
        dir = makeTempDir()
        path = dir.appendingPathComponent("chat.db").path
        attachmentsRoot = dir.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentsRoot, withIntermediateDirectories: true)
        db = try SQLiteDB(path: path, mode: .readWriteCreate)
        // 실제 chat.db 처럼 WAL — 여러 일꾼이 읽는 동안 테스트가 행을 써 넣어도 서로 막지 않는다.
        try db.exec("PRAGMA journal_mode = WAL")
        try db.exec("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL, service TEXT);
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, style INTEGER, chat_identifier TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, UNIQUE(chat_id, handle_id));
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, text TEXT,
                handle_id INTEGER DEFAULT 0, attributedBody BLOB, error INTEGER DEFAULT 0, date INTEGER,
                is_from_me INTEGER DEFAULT 0, is_audio_message INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
                associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, associated_message_emoji TEXT,
                thread_originator_guid TEXT, thread_originator_part TEXT, date_retracted INTEGER,
                is_sent INTEGER DEFAULT 0, is_delivered INTEGER DEFAULT 0, service TEXT DEFAULT 'iMessage',
                cache_has_attachments INTEGER DEFAULT 0, balloon_bundle_id TEXT, expire_state INTEGER DEFAULT 0);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER DEFAULT 0, PRIMARY KEY (chat_id, message_id));
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, guid TEXT UNIQUE NOT NULL, filename TEXT,
                uti TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER DEFAULT 0, is_sticker INTEGER DEFAULT 0,
                transfer_state INTEGER DEFAULT 0, is_outgoing INTEGER DEFAULT 0);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER, UNIQUE(message_id, attachment_id));
            INSERT INTO handle(ROWID, id) VALUES (1, '+821011112222'), (2, '+821033334444'), (3, 'other@example.com');
            INSERT INTO chat(ROWID, guid, style) VALUES (1, 'any;-;+821011112222', 45), (2, 'any;-;+821033334444', 45), (3, 'any;+;chat123', 43);
            INSERT INTO chat_handle_join VALUES (1, 1), (2, 2), (3, 2), (3, 3);
            """)
    }

    static let chatGuid = "any;-;+821011112222"
    static let handle = "+821011112222"

    func nextGuid() -> String { lock.lock(); defer { lock.unlock() }; guidCounter += 1; return "GUID-\(guidCounter)" }

    @discardableResult
    func insert(chat: Int64 = 1, text: String? = nil, blobText: String? = nil, fromMe: Bool = false,
                guid: String? = nil, threadOriginator: String? = nil, threadPart: String? = nil,
                assocType: Int = 0, assocGuid: String? = nil, assocEmoji: String? = nil,
                audio: Bool = false, error: Int = 0, attachments: [(name: String, path: String?, mime: String?)] = []) throws -> (rowid: Int64, guid: String) {
        lock.lock(); defer { lock.unlock() }
        let g = guid ?? nextGuid()
        try db.run("""
            INSERT INTO message(guid, text, attributedBody, is_from_me, thread_originator_guid, thread_originator_part,
                associated_message_type, associated_message_guid, associated_message_emoji, is_audio_message, error)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(g), text.map { .text($0) } ?? .null, blobText.map { .blob(AttributedBody.encodeForTesting($0)) } ?? .null,
                  .int(fromMe ? 1 : 0), threadOriginator.map { .text($0) } ?? .null, threadPart.map { .text($0) } ?? .null,
                  .int(Int64(assocType)), assocGuid.map { .text($0) } ?? .null, assocEmoji.map { .text($0) } ?? .null,
                  .int(audio ? 1 : 0), .int(Int64(error))])
        let rowid = try db.query("SELECT ROWID FROM message WHERE guid = ?", [.text(g)]) { $0.int(0)! }[0]
        try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES(?, ?)", [.int(chat), .int(rowid)])
        for a in attachments {
            let ag = "ATT-\(g)-\(a.name)"
            try db.run("INSERT INTO attachment(guid, filename, mime_type, transfer_name, total_bytes) VALUES(?, ?, ?, ?, 10)",
                       [.text(ag), a.path.map { .text($0) } ?? .null, a.mime.map { .text($0) } ?? .null, .text(a.name)])
            let aid = try db.query("SELECT ROWID FROM attachment WHERE guid = ?", [.text(ag)]) { $0.int(0)! }[0]
            try db.run("INSERT INTO message_attachment_join VALUES(?, ?)", [.int(rowid), .int(aid)])
        }
        return (rowid, g)
    }

    /// 메시지 앱이 내가 보낸 첨부를 적는 실측 모양(2026-10-14, macOS 26.0.1) 그대로 행을 넣는다.
    /// - 첨부 행: `text` NULL, `attributedBody` = U+FFFC 하나(+파일 전송 GUID 속성), `cache_has_attachments=1`
    /// - 성공: `error=0`, `is_sent=1`, attachment `transfer_state=5`, `filename` = 메시지 첨부 폴더 안 사본
    /// - 샌드박스 밖 파일: `error=25`, `is_sent=0`, `is_delivered=0`, `transfer_state=6`, `filename` = 넘긴 경로 그대로
    @discardableResult
    func insertObservedOwnAttachment(chat: Int64 = 1, sentPath: String, mime: String?, uti: String?, error: Int) throws -> (rowid: Int64, guid: String) {
        lock.lock(); defer { lock.unlock() }
        let g = nextGuid()
        let ok = error == 0
        try db.run("""
            INSERT INTO message(guid, text, attributedBody, is_from_me, error, is_sent, is_delivered, service, cache_has_attachments)
            VALUES(?, NULL, ?, 1, ?, ?, ?, 'iMessage', 1)
            """, [.text(g), .blob(ObservedShapes.attachmentPlaceholderBody), .int(Int64(error)), .int(ok ? 1 : 0), .int(ok ? 1 : 0)])
        let rowid = try db.query("SELECT ROWID FROM message WHERE guid = ?", [.text(g)]) { $0.int(0)! }[0]
        try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES(?, ?)", [.int(chat), .int(rowid)])
        let name = (sentPath as NSString).lastPathComponent
        var filename = sentPath
        if ok {
            // 성공하면 메시지 앱이 자기 첨부 폴더(…/Attachments/xx/yy/<GUID>/원래이름)로 복사한다.
            filename = makeAttachmentFile(name, contents: (try? String(contentsOfFile: sentPath, encoding: .utf8)) ?? "data")
        }
        let ag = "ATT-\(g)"
        try db.run("""
            INSERT INTO attachment(guid, filename, uti, mime_type, transfer_name, total_bytes, transfer_state, is_outgoing)
            VALUES(?, ?, ?, ?, ?, 10, ?, 1)
            """, [.text(ag), .text(filename), uti.map { .text($0) } ?? .null, mime.map { .text($0) } ?? .null,
                  .text(name), .int(ok ? 5 : 6)])
        let aid = try db.query("SELECT ROWID FROM attachment WHERE guid = ?", [.text(ag)]) { $0.int(0)! }[0]
        try db.run("INSERT INTO message_attachment_join VALUES(?, ?)", [.int(rowid), .int(aid)])
        return (rowid, g)
    }

    /// 첨부 폴더 안에 실제 파일을 만들고 경로를 돌려준다.
    func makeAttachmentFile(_ name: String, contents: String = "data") -> String {
        let sub = attachmentsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let p = sub.appendingPathComponent(name)
        try! contents.data(using: .utf8)!.write(to: p)
        return p.path
    }

    func reader() throws -> ChatDB { try ChatDB(path: path, attachmentsRoot: attachmentsRoot.path) }
}

// MARK: - 목 텔레그램 (URLProtocol)

struct RecordedRequest {
    var method: String
    var json: [String: Any]
    var multipart: String
    /// 요청 주소의 봇 토큰(`/bot<token>/<method>`). 여러 봇을 구분하는 테스트용.
    var token: String = ""
}

final class MockTelegram: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [RecordedRequest] = []
    nonisolated(unsafe) static var updatesQueue: [[[String: Any]]] = []
    nonisolated(unsafe) static var nextMessageID: Int64 = 1000
    /// 메서드 이름 → 강제 오류 응답(JSON)
    nonisolated(unsafe) static var failures: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var fileBytes = Data("OggS-fake".utf8)
    nonisolated(unsafe) static var networkDown = false
    /// 토큰별 강제 오류(메서드 → 응답). 여러 봇 중 하나만 망가뜨리는 테스트용.
    nonisolated(unsafe) static var failuresByToken: [String: [String: [String: Any]]] = [:]
    /// 토큰별 getUpdates 응답 줄. 비어 있으면 공용 `updatesQueue` 를 쓴다.
    nonisolated(unsafe) static var updatesByToken: [String: [[[String: Any]]]] = [:]

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        requests = []; updatesQueue = []; nextMessageID = 1000; failures = [:]; networkDown = false
        failuresByToken = [:]; updatesByToken = [:]
    }

    static func calls(_ method: String, token: String) -> [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.method == method && $0.token == token }
    }

    static func enqueue(_ updates: [[String: Any]], token: String) {
        lock.lock(); updatesByToken[token, default: []].append(updates); lock.unlock()
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockTelegram.self]
        return URLSession(configuration: c)
    }

    static func calls(_ method: String) -> [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.method == method }
    }
    static var sentMethods: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests.map(\.method).filter { $0 != "getUpdates" }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        if Self.networkDown {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: url]))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            s.close()
        }
        // /file/bot<token>/<path> 다운로드
        if url.path.hasPrefix("/file/") {
            Self.record(RecordedRequest(method: "file", json: [:], multipart: ""))
            respond(Self.fileBytes)
            return
        }
        let method = url.lastPathComponent
        let token = url.pathComponents.first { $0.hasPrefix("bot") }.map { String($0.dropFirst(3)) } ?? ""
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.record(RecordedRequest(method: method, json: json, multipart: String(decoding: body, as: UTF8.self), token: token))

        Self.lock.lock()
        let failure = Self.failuresByToken[token]?[method] ?? Self.failures[method]
        Self.lock.unlock()
        if let failure { respondJSON(failure); return }

        switch method {
        case "getUpdates":
            Self.lock.lock()
            let batch: [[String: Any]]
            if var own = Self.updatesByToken[token] {
                batch = own.isEmpty ? [] : own.removeFirst()
                Self.updatesByToken[token] = own
            } else {
                batch = Self.updatesQueue.isEmpty ? [] : Self.updatesQueue.removeFirst()
            }
            Self.lock.unlock()
            respondJSON(["ok": true, "result": batch])
        case "sendMessage", "sendPhoto", "sendVoice", "sendAudio", "sendVideo", "sendDocument":
            Self.lock.lock()
            Self.nextMessageID += 1
            let id = Self.nextMessageID
            Self.lock.unlock()
            respondJSON(["ok": true, "result": ["message_id": id]])
        case "setMessageReaction":
            respondJSON(["ok": true, "result": true])
        case "getFile":
            respondJSON(["ok": true, "result": ["file_path": "voice/file_1.oga", "file_size": 9]])
        case "getMe":
            let id = Int64(token.split(separator: ":").first ?? "") ?? 1
            respondJSON(["ok": true, "result": ["id": id, "username": id == 123456 ? "test_bot" : "bot\(id)_bot", "is_bot": true]])
        default:
            respondJSON(["ok": false, "error_code": 404, "description": "Not Found"])
        }
    }

    static func record(_ r: RecordedRequest) {
        lock.lock(); requests.append(r); lock.unlock()
    }

    private func respondJSON(_ obj: [String: Any]) {
        respond(try! JSONSerialization.data(withJSONObject: obj))
    }

    private func respond(_ data: Data) {
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func enqueue(_ updates: [[String: Any]]) {
        lock.lock(); updatesQueue.append(updates); lock.unlock()
    }
}

// MARK: - 가짜 발신기·변환기·시계

final class FakeSender: MessagesSender {
    var sent: [(kind: String, payload: String, chat: String)] = []
    var failNext = false
    /// 보낼 때 fixture chat.db 에 메아리(내 메시지) 행을 써 넣는다 — 실제 메시지 앱 동작 흉내.
    var echoInto: FixtureChatDB?
    /// 메아리를 적을 fixture 대화 rowid(매핑마다 다른 대화).
    var echoChat: Int64 = 1
    var echoError = 0
    /// 메시지 앱이 chat.db 에 적을 때 본문을 바꿔 쓰는 것을 흉내낸다(예: `\n` → U+2028).
    /// nil 이면 보낸 그대로 적는다.
    var echoTextTransform: ((String) -> String)?
    /// true 면 메아리를 실제 메시지 앱처럼 `text` 를 비우고 `attributedBody` 에만 적는다.
    var echoAsAttributedBody = false

    func sendText(_ text: String, chatGuid: String) throws {
        if failNext { failNext = false; throw SendError("가짜 실패") }
        sent.append(("text", text, chatGuid))
        let written = echoTextTransform?(text) ?? text
        if echoAsAttributedBody {
            try echoInto?.insert(chat: echoChat, blobText: written, fromMe: true, error: echoError)
        } else {
            try echoInto?.insert(chat: echoChat, text: written, fromMe: true, error: echoError)
        }
    }
    /// 파일 메아리에만 쓰는 error 값. nil 이면 `echoError` 를 쓴다(예: 사진만 25, 캡션은 0).
    var fileEchoError: Int?
    /// 보낸 파일의 권한(보낼 때 시점) 기록 — 폴더·파일 권한 검사용.
    var sentFileModes: [Int] = []

    func sendFile(_ path: String, chatGuid: String) throws {
        if failNext { failNext = false; throw SendError("가짜 실패") }
        sent.append(("file", path, chatGuid))
        let dirMode = (try? FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)[.posixPermissions] as? Int) ?? -1
        sentFileModes.append(dirMode)
        let ext = (path as NSString).pathExtension.lowercased()
        let mime = AttachmentClassifier.mime(for: path)
        let uti = ["jpg": "public.jpeg", "m4a": "com.apple.m4a-audio", "pdf": "com.adobe.pdf"][ext]
        try echoInto?.insertObservedOwnAttachment(chat: echoChat, sentPath: path, mime: mime, uti: uti, error: fileEchoError ?? echoError)
    }
    func chatExists(_ chatGuid: String) throws -> Bool { true }
}

final class FakeConverter: MediaConverter {
    var calls: [String] = []
    func toJPEG(_ input: URL, outputDir: URL) throws -> URL { try convert(input, outputDir, "jpg") }
    func toM4A(_ input: URL, outputDir: URL) throws -> URL { try convert(input, outputDir, "m4a") }
    private func convert(_ input: URL, _ dir: URL, _ ext: String) throws -> URL {
        calls.append(ext)
        let out = dir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "." + ext)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: input, to: out)
        return out
    }
}

final class FakeClock: Clock {
    var now: Double = 1_800_000_000
    var slept: Double = 0
    func sleep(seconds: Double) async { now += seconds; slept += seconds }
}

// MARK: - 조립

final class LogBox {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func append(_ s: String) { lock.lock(); stored.append(s); lock.unlock() }
}

struct Harness {
    let logs: LogBox
    let fixture: FixtureChatDB
    let state: StateStore
    let statePath: String
    let sender: FakeSender
    let converter: FakeConverter
    let clock: FakeClock
    let relay: Relay
    let workDir: URL

    static let chatID: Int64 = 555
    static let userID: Int64 = 777

    static let token = "123456:TESTTOKENTESTTOKENTESTTOKEN"

    static func make(fixture: FixtureChatDB? = nil, statePath: String? = nil, mappingID: String = "default",
                     token: String = Harness.token, chatGuid: String = FixtureChatDB.chatGuid, handle: String = FixtureChatDB.handle,
                     activity: ChatActivity? = nil, resetMock: Bool = true,
                     configure: (inout Relay.Options) -> Void = { _ in }) throws -> Harness {
        if resetMock { MockTelegram.reset() }
        let fx = try fixture ?? FixtureChatDB()
        let work = makeTempDir()
        let sp = statePath ?? work.appendingPathComponent("state.sqlite").path
        let state = try StateStore(path: sp, mappingID: mappingID)
        let sender = FakeSender()
        sender.echoInto = fx
        sender.echoChat = try fx.db.query("SELECT ROWID FROM chat WHERE guid = ?", [.text(chatGuid)]) { $0.int(0) }.first.flatMap { $0 } ?? 1
        let conv = FakeConverter()
        let clock = FakeClock()
        var opts = Relay.Options(chatGuid: chatGuid, handle: handle,
                                 allowedUserID: userID, chatID: chatID,
                                 outboxDir: work.appendingPathComponent("outbox"), tmpDir: work.appendingPathComponent("tmp"))
        opts.pollTimeout = 0
        opts.requireMessagesReadableOutbox = false  // 테스트는 임시 폴더를 쓴다
        configure(&opts)
        let tg = TelegramClient(token: token, chatID: chatID,
                                base: URL(string: "https://mock.telegram.test")!, session: MockTelegram.session())
        let logs = LogBox()
        let relay = Relay(chatDB: try fx.reader(), state: state, telegram: tg, sender: sender,
                          converter: conv, clock: clock, options: opts, activity: activity, log: { logs.append($0) })
        return Harness(logs: logs, fixture: fx, state: state, statePath: sp, sender: sender, converter: conv, clock: clock, relay: relay, workDir: work)
    }

    static func textUpdate(_ updateID: Int64, messageID: Int64, text: String, chat: Int64 = chatID, from: Int64 = userID,
                           replyTo: (Int64, String)? = nil, date: Int64? = nil) -> [String: Any] {
        var msg: [String: Any] = ["message_id": messageID, "chat": ["id": chat], "from": ["id": from, "is_bot": false], "text": text]
        if let r = replyTo { msg["reply_to_message"] = ["message_id": r.0, "text": r.1] }
        if let date { msg["date"] = date }
        return ["update_id": updateID, "message": msg]
    }
}

// MARK: - 실측 모양 상수 (개인 본문·실제 GUID 없음)

enum ObservedShapes {
    /// 내가 보낸 첨부 행의 attributedBody(2026-10-14 실측). 본문은 U+FFFC 하나, 속성은
    /// `__kIMFileTransferGUIDAttributeName`(값은 가짜 GUID 로 바꿈)과 `__kIMMessagePartAttributeName`=0.
    static let attachmentPlaceholderBody = Data(hex: """
        040B73747265616D747970656481E803840140848484124E5341747472696275746564537472696E67008484084E534F626A656374008592848484084E53537472696E67019484012B03EFBFBC86840269490101928484840C4E5344696374696F6E61727900948401690292849696225F5F6B494D46696C655472616E73666572475549444174747269627574654E616D6586928496962431313131313131312D323232322D333333332D343434342D35353535353535353535353586928496961D5F5F6B494D4D657373616765506172744174747269627574654E616D658692848484084E534E756D626572008484074E5356616C7565009484012A84999900868686
        """)
}

extension Data {
    init(hex: String) {
        let chars = Array(hex.filter { !$0.isWhitespace })
        var bytes: [UInt8] = []
        var i = 0
        while i + 1 < chars.count {
            bytes.append(UInt8(String(chars[i...i + 1]), radix: 16)!)
            i += 2
        }
        self.init(bytes)
    }
}
