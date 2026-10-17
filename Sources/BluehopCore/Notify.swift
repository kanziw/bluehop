import Foundation

/// 매핑 하나에 글 하나를 보낸 결과. `code` 는 `ErrorCodes.catalog` 의 키(성공은 `OK`).
public struct NotifyResult: Equatable {
    public var mappingID: String
    public var ok: Bool
    public var messageID: Int64?
    public var code: String
    public var detail: String?

    public init(mappingID: String, ok: Bool, messageID: Int64? = nil, code: String = ErrorCodes.ok, detail: String? = nil) {
        self.mappingID = mappingID
        self.ok = ok
        self.messageID = messageID
        self.code = code
        self.detail = detail
    }

    public var json: [String: Any?] {
        ["mapping": mappingID, "ok": ok, "messageId": messageID, "code": code, "detail": detail]
    }
}

/// `bluehop notify`: 매핑마다 그 봇 토큰으로 텔레그램 글 하나를 보낸다.
/// iMessage·상태 DB·사건 로그는 건드리지 않는다 — 텔레그램으로 나가는 요청뿐이다.
/// 매핑 하나가 실패해도(토큰 못 읽음, 텔레그램 오류) 나머지는 계속 보낸다(부분 성공).
public enum Notifier {
    public static func send(_ mappings: [MappingConfig], text: String,
                            loadToken: (MappingConfig) throws -> String = ConfigLoader.loadToken,
                            telegramFor: (String, Int64) -> TelegramClient = { TelegramClient(token: $0, chatID: $1) }) async -> [NotifyResult] {
        var out: [NotifyResult] = []
        for m in mappings {
            do {
                let token = try loadToken(m)
                let messageID = try await telegramFor(token, m.telegram.chatId).sendMessage(text)
                out.append(NotifyResult(mappingID: m.id, ok: true, messageID: messageID))
            } catch {
                out.append(NotifyResult(mappingID: m.id, ok: false, code: ErrorCodes.of(error), detail: "\(error)"))
            }
        }
        return out
    }
}
