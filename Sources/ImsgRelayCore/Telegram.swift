import Foundation

// MARK: - 모델 (필요한 필드만)

public struct TGUser: Decodable, Equatable { public var id: Int64; public var is_bot: Bool? }
public struct TGChat: Decodable, Equatable { public var id: Int64; public var type: String? }
public struct TGFileRef: Decodable, Equatable {
    public var file_id: String
    public var file_size: Int64?
    public var file_name: String?
    public var mime_type: String?
}
public struct TGPhotoSize: Decodable, Equatable { public var file_id: String; public var file_size: Int64?; public var width: Int?; public var height: Int? }

/// 답글 대상(한 단계만).
public struct TGReplyMessage: Decodable, Equatable {
    public var message_id: Int64
    public var text: String?
    public var caption: String?
}

public struct TGMessage: Decodable, Equatable {
    public var message_id: Int64
    public var from: TGUser?
    public var chat: TGChat
    /// 유닉스초. 실제 텔레그램 API 는 항상 보내지만, 테스트 fixture 는 생략할 수 있어 optional.
    public var date: Int64?
    public var text: String?
    public var caption: String?
    public var reply_to_message: TGReplyMessage?
    public var photo: [TGPhotoSize]?
    public var voice: TGFileRef?
    public var audio: TGFileRef?
    public var document: TGFileRef?
    public var video: TGFileRef?
    public var video_note: TGFileRef?
    public var sticker: TGFileRef?
    public var animation: TGFileRef?
}

public struct TGReactionType: Decodable, Equatable { public var type: String; public var emoji: String? }
public struct TGMessageReactionUpdated: Decodable, Equatable {
    public var chat: TGChat
    public var message_id: Int64
    public var user: TGUser?
    public var old_reaction: [TGReactionType]
    public var new_reaction: [TGReactionType]
}

public struct TGUpdate: Decodable, Equatable {
    public var update_id: Int64
    public var message: TGMessage?
    public var edited_message: TGMessage?
    public var message_reaction: TGMessageReactionUpdated?
}

struct TGResponse<T: Decodable>: Decodable {
    var ok: Bool
    var result: T?
    var description: String?
    var error_code: Int?
    var parameters: Params?
    struct Params: Decodable { var retry_after: Int? }
}

struct TGSent: Decodable { var message_id: Int64 }
struct TGFileInfo: Decodable { var file_path: String?; var file_size: Int64? }

public enum TelegramError: Error, CustomStringConvertible, Equatable {
    case api(method: String, code: Int, description: String)
    case retryAfter(seconds: Int)
    /// 네트워크 오류. URL(토큰 포함)은 담지 않는다.
    case network(method: String, code: Int)
    case tooLarge(bytes: Int64)
    case decode(method: String)

    public var description: String {
        switch self {
        case .api(let m, let c, let d): return "telegram \(m) 실패 \(c): \(d)"
        case .retryAfter(let s): return "telegram 속도 제한, \(s)초 뒤 재시도"
        case .network(let m, let c): return "telegram \(m) 네트워크 오류 (\(c))"
        case .tooLarge(let b): return "파일이 너무 큼 (\(b) bytes)"
        case .decode(let m): return "telegram \(m) 응답 해석 실패"
        }
    }
}

public enum TGMediaKind: String {
    case photo, voice, audio, video, document
    var method: String {
        switch self {
        case .photo: return "sendPhoto"
        case .voice: return "sendVoice"
        case .audio: return "sendAudio"
        case .video: return "sendVideo"
        case .document: return "sendDocument"
        }
    }
}

/// 텔레그램 Bot API 클라이언트. 실제 실행에서는 기본 주소(api.telegram.org)만 쓴다.
public final class TelegramClient {
    public static let productionBase = URL(string: "https://api.telegram.org")!
    /// 봇이 getFile 로 내려받을 수 있는 최대 크기
    public static let maxDownloadBytes: Int64 = 20 * 1024 * 1024

    let token: String
    let chatID: Int64
    let base: URL
    let session: URLSession

    /// - Parameter base: 테스트에서만 목 주소를 넣는다. 설정 파일로는 바꿀 수 없다.
    public init(token: String, chatID: Int64, base: URL = TelegramClient.productionBase, session: URLSession = .shared) {
        self.token = token
        self.chatID = chatID
        self.base = base
        self.session = session
    }

    private func methodURL(_ method: String) -> URL {
        base.appendingPathComponent("bot\(token)").appendingPathComponent(method)
    }

    private func perform<T: Decodable>(_ method: String, request: URLRequest, as: T.Type) async throws -> T {
        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch let e as URLError {
            throw TelegramError.network(method: method, code: e.errorCode)
        } catch {
            throw TelegramError.network(method: method, code: -1)
        }
        guard let resp = try? JSONDecoder().decode(TGResponse<T>.self, from: data) else {
            throw TelegramError.decode(method: method)
        }
        if resp.ok, let r = resp.result { return r }
        if let ra = resp.parameters?.retry_after { throw TelegramError.retryAfter(seconds: ra) }
        throw TelegramError.api(method: method, code: resp.error_code ?? 0, description: resp.description ?? "")
    }

    private func call<T: Decodable>(_ method: String, _ params: [String: Any], as t: T.Type, timeout: TimeInterval = 30) async throws -> T {
        var req = URLRequest(url: methodURL(method))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        return try await perform(method, request: req, as: t)
    }

    /// 토큰 확인용. 봇 username 을 돌려준다.
    public func getMe() async throws -> String {
        struct Me: Decodable { var username: String? }
        return try await call("getMe", [:], as: Me.self).username ?? ""
    }

    /// 설정용: offset 을 올리지 않고 최근 업데이트의 (chat id, 보낸 사람 id)만 본다.
    public func peekSenders() async throws -> [(chatID: Int64, userID: Int64?, chatType: String?)] {
        try await call("getUpdates", ["timeout": 0, "allowed_updates": ["message"]], as: [TGUpdate].self)
            .compactMap { $0.message }.map { ($0.chat.id, $0.from?.id, $0.chat.type) }
    }

    public func getUpdates(offset: Int64, timeout: Int) async throws -> [TGUpdate] {
        try await call("getUpdates", [
            "offset": offset, "timeout": timeout,
            "allowed_updates": ["message", "edited_message", "message_reaction"],
        ], as: [TGUpdate].self, timeout: TimeInterval(timeout + 15))
    }

    private func replyParams(_ replyTo: Int64?) -> [String: Any]? {
        guard let replyTo else { return nil }
        return ["message_id": replyTo, "allow_sending_without_reply": true]
    }

    @discardableResult
    public func sendMessage(_ text: String, replyTo: Int64? = nil) async throws -> Int64 {
        var p: [String: Any] = ["chat_id": chatID, "text": text, "link_preview_options": ["is_disabled": true]]
        if let rp = replyParams(replyTo) { p["reply_parameters"] = rp }
        return try await call("sendMessage", p, as: TGSent.self).message_id
    }

    /// 첨부 업로드(multipart). caption 은 1024자까지만 쓴다.
    public func sendMedia(_ kind: TGMediaKind, fileURL: URL, filename: String, mimeType: String?,
                          caption: String? = nil, replyTo: Int64? = nil) async throws -> Int64 {
        let boundary = "imsgrelay-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("chat_id", String(chatID))
        if let caption, !caption.isEmpty { field("caption", String(caption.prefix(1024))) }
        if let rp = replyParams(replyTo), let json = try? JSONSerialization.data(withJSONObject: rp) {
            field("reply_parameters", String(decoding: json, as: UTF8.self))
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(kind.rawValue)\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType ?? "application/octet-stream")\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: methodURL(kind.method))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await perform(kind.method, request: req, as: TGSent.self).message_id
    }

    /// emoji 가 nil 이면 반응을 지운다.
    public func setMessageReaction(messageID: Int64, emoji: String?) async throws {
        let reaction: [[String: Any]] = emoji.map { [["type": "emoji", "emoji": $0]] } ?? []
        _ = try await call("setMessageReaction", ["chat_id": chatID, "message_id": messageID, "reaction": reaction], as: Bool.self)
    }

    /// 파일을 내려받는다(20MB 한도).
    public func download(fileID: String) async throws -> Data {
        let info = try await call("getFile", ["file_id": fileID], as: TGFileInfo.self)
        if let size = info.file_size, size > Self.maxDownloadBytes { throw TelegramError.tooLarge(bytes: size) }
        guard let path = info.file_path else { throw TelegramError.decode(method: "getFile") }
        let url = base.appendingPathComponent("file").appendingPathComponent("bot\(token)").appendingPathComponent(path)
        do {
            let (data, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw TelegramError.api(method: "file", code: http.statusCode, description: "download failed")
            }
            if Int64(data.count) > Self.maxDownloadBytes { throw TelegramError.tooLarge(bytes: Int64(data.count)) }
            return data
        } catch let e as URLError {
            throw TelegramError.network(method: "file", code: e.errorCode)
        }
    }
}
