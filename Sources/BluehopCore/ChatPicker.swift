import Foundation

/// 대화 고르기 화면의 상태. 터미널 입출력과 떨어진 순수 로직이라 테스트한다.
/// 위·아래·PageUp/Down·Home/End 로 움직이고, 글자를 치면 거르고, Enter 로 고르고, Esc·Ctrl-C 로 취소한다.
/// 이미 다른 매핑이 쓰는 대화는 보이지만 고를 수 없다.
public struct ChatPicker {
    public struct Item: Equatable {
        public var guid: String
        public var handle: String
        public var detail: String
        /// 이 대화를 쓰는 매핑 id(있으면 고를 수 없음)
        public var mappedTo: String?
        public init(guid: String, handle: String, detail: String = "", mappedTo: String? = nil) {
            self.guid = guid
            self.handle = handle
            self.detail = detail
            self.mappedTo = mappedTo
        }
    }

    public enum Key: Equatable {
        case up, down, pageUp, pageDown, home, end, enter, escape, backspace, interrupt
        case char(Character)
    }

    public enum Outcome: Equatable { case pending, picked(Item), cancelled }

    public let items: [Item]
    public private(set) var filter = ""
    /// `visible` 안의 위치
    public private(set) var cursor = 0
    public private(set) var scroll = 0
    public private(set) var message: String?
    public var pageSize: Int

    public init(items: [Item], pageSize: Int = 10) {
        self.items = items
        self.pageSize = max(1, pageSize)
        cursor = visible.firstIndex { $0.mappedTo == nil } ?? 0
        clampScroll()
    }

    /// 거름말이 handle·guid 에 들어 있는 항목(공백·`-`·괄호·대소문자 무시).
    public var visible: [Item] {
        let f = MappingRules.normalizeHandle(filter)
        guard !f.isEmpty else { return items }
        return items.filter {
            MappingRules.normalizeHandle($0.handle).contains(f) || MappingRules.normalizeHandle($0.guid).contains(f)
                || $0.detail.lowercased().contains(filter.lowercased())
        }
    }

    public var current: Item? {
        let v = visible
        return v.indices.contains(cursor) ? v[cursor] : nil
    }

    public mutating func handle(_ key: Key) -> Outcome {
        message = nil
        let count = visible.count
        switch key {
        case .up: cursor = max(0, cursor - 1)
        case .down: cursor = min(max(0, count - 1), cursor + 1)
        case .pageUp: cursor = max(0, cursor - pageSize)
        case .pageDown: cursor = min(max(0, count - 1), cursor + pageSize)
        case .home: cursor = 0
        case .end: cursor = max(0, count - 1)
        case .escape, .interrupt: return .cancelled
        case .backspace:
            if !filter.isEmpty { filter.removeLast(); cursor = 0 }
        case .char(let c):
            filter.append(c)
            cursor = 0
        case .enter:
            guard let item = current else {
                message = "고를 대화가 없습니다"
                return .pending
            }
            if let m = item.mappedTo {
                message = "이미 매핑 '\(m)' 가 쓰는 대화입니다"
                return .pending
            }
            return .picked(item)
        }
        clampScroll()
        return .pending
    }

    mutating func clampScroll() {
        if cursor < scroll { scroll = cursor }
        if cursor >= scroll + pageSize { scroll = cursor - pageSize + 1 }
        scroll = max(0, min(scroll, max(0, visible.count - pageSize)))
    }

    /// 화면에 그릴 줄들(색 없음). 고른 줄은 `›`, 고를 수 없는 줄은 `·`.
    public func render(title: String) -> [String] {
        var lines = [title, "거름말: \(filter.isEmpty ? "(글자를 쳐서 거르기)" : filter)   ↑↓ 이동 · Enter 고르기 · Esc 취소"]
        let v = visible
        if v.isEmpty { lines.append("  (맞는 대화 없음)") }
        let end = min(v.count, scroll + pageSize)
        if scroll < end {
            for i in scroll..<end {
                let it = v[i]
                let mark = i == cursor ? "›" : (it.mappedTo == nil ? " " : "·")
                var line = "\(mark) \(it.handle)"
                if !it.detail.isEmpty { line += "  \(it.detail)" }
                if let m = it.mappedTo { line += "  [매핑 \(m)]" }
                lines.append(line)
            }
        }
        lines.append("  \(v.count)개 중 \(v.isEmpty ? 0 : scroll + 1)–\(end)")
        if let message { lines.append("! \(message)") }
        return lines
    }
}

/// 터미널 키 입력 바이트 → 키. 화살표·Home/End·PageUp/Down 의 CSI·SS3 순서를 안다.
public enum KeyDecoder {
    /// 바이트 묶음을 키들로 바꾼다. 끝에 덜 들어온 이스케이프 순서는 남는 바이트로 돌려준다.
    public static func decode(_ bytes: [UInt8]) -> (keys: [ChatPicker.Key], rest: [UInt8]) {
        var keys: [ChatPicker.Key] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            switch b {
            case 0x1B:
                if i + 1 >= bytes.count { keys.append(.escape); i += 1; continue }
                let n = bytes[i + 1]
                if n == UInt8(ascii: "[") || n == UInt8(ascii: "O") {
                    guard i + 2 < bytes.count else { return (keys, Array(bytes[i...])) }
                    var j = i + 2
                    var params = ""
                    while j < bytes.count, (0x30...0x3F).contains(bytes[j]) {
                        params.append(Character(UnicodeScalar(bytes[j])))
                        j += 1
                    }
                    guard j < bytes.count else { return (keys, Array(bytes[i...])) }
                    let final = Character(UnicodeScalar(bytes[j]))
                    switch (final, params) {
                    case ("A", _): keys.append(.up)
                    case ("B", _): keys.append(.down)
                    case ("H", _): keys.append(.home)
                    case ("F", _): keys.append(.end)
                    case ("~", "1"), ("~", "7"): keys.append(.home)
                    case ("~", "4"), ("~", "8"): keys.append(.end)
                    case ("~", "5"): keys.append(.pageUp)
                    case ("~", "6"): keys.append(.pageDown)
                    default: break
                    }
                    i = j + 1
                } else {
                    keys.append(.escape)
                    i += 1
                }
            case 0x0D, 0x0A: keys.append(.enter); i += 1
            case 0x7F, 0x08: keys.append(.backspace); i += 1
            case 0x03: keys.append(.interrupt); i += 1
            case 0x10: keys.append(.up); i += 1      // Ctrl-P
            case 0x0E: keys.append(.down); i += 1    // Ctrl-N
            default:
                if b < 0x20 { i += 1; continue }
                // UTF-8 한 글자
                let len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
                guard i + len <= bytes.count else { return (keys, Array(bytes[i...])) }
                if let s = String(bytes: bytes[i..<(i + len)], encoding: .utf8), let c = s.first {
                    keys.append(.char(c))
                }
                i += len
            }
        }
        return (keys, [])
    }
}

/// 번호 고르기(터미널이 원시 모드를 못 쓸 때). 입력 줄 → 고른 항목.
public enum NumberedChoice {
    public static func render(_ items: [ChatPicker.Item]) -> [String] {
        items.enumerated().map { i, it in
            "\(String(i + 1).padding(toLength: 3, withPad: " ", startingAt: 0)) \(it.handle)"
                + (it.detail.isEmpty ? "" : "  \(it.detail)") + (it.mappedTo.map { "  [매핑 \($0), 고를 수 없음]" } ?? "")
        }
    }

    public enum Result: Equatable { case picked(ChatPicker.Item), invalid(String), cancelled }

    public static func choose(_ line: String?, items: [ChatPicker.Item]) -> Result {
        guard let raw = line?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.lowercased() != "q" else { return .cancelled }
        guard let n = Int(raw), (1...items.count).contains(n) else { return .invalid("1~\(items.count) 사이 번호를 넣으세요") }
        let it = items[n - 1]
        if let m = it.mappedTo { return .invalid("이미 매핑 '\(m)' 가 쓰는 대화입니다") }
        return .picked(it)
    }
}
