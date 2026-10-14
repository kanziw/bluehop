import Foundation

/// iMessage tapback(반응) 해석.
public struct Tapback: Equatable {
    public enum Action: Equatable { case add, remove }
    public var action: Action
    /// 사람이 보는 이모지(예: "❤️", "‼️", 임의 이모지). 스티커 반응은 nil.
    public var emoji: String?
    /// 반응 대상 메시지 guid(`p:0/` 같은 접두를 뗀 값)
    public var targetGuid: String
    /// 대상 메시지의 몇 번째 부분인지(`p:N/`). 없으면 nil.
    public var targetPart: Int?

    /// associated_message_type: 2000–2007 추가, 3000–3007 취소.
    /// 2000 ❤️ 2001 👍 2002 👎 2003 😂 2004 ‼️ 2005 ❓ 2006 임의 이모지(iOS 17+) 2007 스티커.
    public static func parse(type: Int, associatedGuid: String?, emoji: String?) -> Tapback? {
        guard let associatedGuid, let (guid, part) = parseAssociatedGuid(associatedGuid) else { return nil }
        let action: Action
        let kind: Int
        switch type {
        case 2000...2007: action = .add; kind = type - 2000
        case 3000...3007: action = .remove; kind = type - 3000
        default: return nil
        }
        let symbol: String?
        switch kind {
        case 0: symbol = "❤️"
        case 1: symbol = "👍"
        case 2: symbol = "👎"
        case 3: symbol = "😂"
        case 4: symbol = "‼️"
        case 5: symbol = "❓"
        case 6: symbol = (emoji?.isEmpty == false) ? emoji : nil
        default: symbol = nil  // 7: 스티커
        }
        return Tapback(action: action, emoji: symbol, targetGuid: guid, targetPart: part)
    }

    /// `p:0/GUID` → (GUID, 0), `bp:GUID` → (GUID, nil), `GUID` → (GUID, nil)
    static func parseAssociatedGuid(_ s: String) -> (String, Int?)? {
        if s.hasPrefix("p:"), let slash = s.firstIndex(of: "/") {
            let partStr = s[s.index(s.startIndex, offsetBy: 2)..<slash]
            let guid = String(s[s.index(after: slash)...])
            return guid.isEmpty ? nil : (guid, Int(partStr))
        }
        if s.hasPrefix("bp:") {
            let guid = String(s.dropFirst(3))
            return guid.isEmpty ? nil : (guid, nil)
        }
        return s.isEmpty ? nil : (s, nil)
    }
}

/// 텔레그램 봇이 `setMessageReaction` 에 쓸 수 있는 기본 반응 이모지.
/// (Bot API ReactionTypeEmoji 목록. 변형 선택자 U+FE0F 는 빼고 비교한다.)
public enum TelegramReactions {
    public static let allowed: [String] = [
        "👍", "👎", "❤", "🔥", "🥰", "👏", "😁", "🤔", "🤯", "😱", "🤬", "😢", "🎉", "🤩", "🤮", "💩",
        "🙏", "👌", "🕊", "🤡", "🥱", "🥴", "😍", "🐳", "❤‍🔥", "🌚", "🌭", "💯", "🤣", "⚡", "🍌", "🏆",
        "💔", "🤨", "😐", "🍓", "🍾", "💋", "🖕", "😈", "😴", "😭", "🤓", "👻", "👨‍💻", "👀", "🎃", "🙈",
        "😇", "😨", "🤝", "✍", "🤗", "🫡", "🎅", "🎄", "☃", "💅", "🤪", "🗿", "🆒", "💘", "🙉", "🦄",
        "😘", "💊", "🙊", "😎", "👾", "🤷‍♂", "🤷", "🤷‍♀", "😡",
    ]

    /// iMessage 기본 tapback 중 텔레그램에 그대로 없는 것의 대응(😂 → 🤣, ❓ → 🤔).
    static let aliases: [String: String] = ["😂": "🤣", "❓": "🤔"]

    static func strip(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value != 0xFE0F }))
    }

    /// 텔레그램 반응으로 달 수 있으면 그 정확한 문자열, 아니면 nil.
    public static func telegramEmoji(for emoji: String) -> String? {
        let key = strip(aliases[emoji] ?? aliases[strip(emoji)] ?? emoji)
        return allowed.first { strip($0) == key }
    }
}
