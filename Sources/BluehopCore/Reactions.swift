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

    /// 허용 목록(73개, Bot API `ReactionTypeEmoji`)에 없는 흔한 이모지를 뜻이 가까운 허용 이모지로
    /// 대응시킨다. 왼쪽은 iMessage 기본 tapback(❓)이거나, iOS 17+ "임의 이모지" tapback으로 흔히
    /// 쓰이는 것들이다.
    ///
    /// | 입력 | 대응 | 근거 |
    /// |---|---|---|
    /// | 😂 | 🤣 | 허용 목록에 "눈물" 웃음(😂)이 없고 "바닥을 구르는" 웃음(🤣)만 있다 |
    /// | ❓ | 🤔 | 허용 목록에 물음표가 없다. 궁금함을 표현하는 가장 가까운 얼굴 |
    /// | ❔ | 🤔 | ❓의 약한 버전(백색 물음표 장식) — 같은 대응 |
    /// | ✅ ☑️ ✔️ | 👌 | 체크마크류 = 승인/완료. 허용 목록의 "오케이" 손짓이 가장 가깝다 |
    /// | ‼️ ❗ ❕ | ⚡ | 강조 부호. 허용 목록에 느낌표가 없어 "쾅" 느낌의 번개로 대응 |
    /// | ❌ | 👎 | 취소/거부 표시 → 부정 반응 |
    /// | 🙂 😊 ☺️ 😀 😃 😄 | 😁 | 웃는 얼굴 계열을 허용 목록의 "활짝 웃는" 얼굴로 통일 |
    /// | 😆 😅 💀 | 🤣 | "웃겨 죽겠다" 계열 — 웃음 강도가 센 쪽으로 |
    /// | 😉 | 😘 | 장난스런 윙크 → 허용 목록의 입맞춤 |
    /// | 😋 | 😍 | 맛있음/만족 → 허용 목록의 반한 표정 |
    /// | 😏 | 😈 | 능글맞음/장난기 → 허용 목록의 장난스런 악마 얼굴 |
    /// | 🥳 | 🎉 | 파티 얼굴 → 허용 목록의 폭죽(이미 같은 맥락) |
    /// | 🙁 ☹️ 😞 😔 | 😢 | 슬픔/실망 계열을 허용 목록의 우는 얼굴로 통일 |
    /// | 🤦 🫠 | 🙈 | 민망함/자책 → 허용 목록의 "안 보는" 원숭이 |
    public static let aliases: [String: String] = [
        "😂": "🤣", "❓": "🤔", "❔": "🤔",
        "✅": "👌", "☑️": "👌", "✔️": "👌",
        "‼️": "⚡", "❗": "⚡", "❕": "⚡",
        "❌": "👎",
        "🙂": "😁", "😊": "😁", "☺️": "😁", "😀": "😁", "😃": "😁", "😄": "😁",
        "😆": "🤣", "😅": "🤣", "💀": "🤣",
        "😉": "😘",
        "😋": "😍",
        "😏": "😈",
        "🥳": "🎉",
        "🙁": "😢", "☹️": "😢", "😞": "😢", "😔": "😢",
        "🤦": "🙈", "🫠": "🙈",
    ]

    /// 변형 선택자(U+FE0F)와 피부색 변경자(U+1F3FB–U+1F3FF, 예: 👍🏽)를 뗀다. iMessage 쪽 이모지는
    /// 피부색이 붙어 오는 일이 흔한데, 허용 목록·별칭 표는 피부색 없는 기본형만 들고 있다.
    static func strip(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            $0.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains($0.value)
        }))
    }

    /// 텔레그램 반응으로 달 수 있으면 그 정확한 문자열, 아니면 nil.
    public static func telegramEmoji(for emoji: String) -> String? {
        let key = strip(emoji)
        if let direct = allowed.first(where: { strip($0) == key }) { return direct }
        guard let mapped = aliases[emoji] ?? aliases[key] else { return nil }
        return allowed.first { strip($0) == strip(mapped) }
    }
}
