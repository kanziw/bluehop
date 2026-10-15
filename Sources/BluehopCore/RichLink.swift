import Foundation

/// 메시지 앱의 링크 말풍선(링크 미리보기) 행을 텔레그램에 읽기 좋은 한 통으로 옮긴다.
///
/// chat.db 실측 모양(macOS 26.0.1, `docs/observed-facts.md` "링크"):
/// - 링크 말풍선은 앞뒤 글과 따로 **한 행**이다. `balloon_bundle_id = com.apple.messages.URLBalloonProvider`,
///   `text`(또는 `attributedBody`) = 링크 주소 그대로.
/// - 미리보기에 쓰인 아이콘·대표 그림은 그 행의 첨부로 붙는다. 이름은 `<UUID>.pluginPayloadAttachment`,
///   `mime_type` 없음, `uti = dyn.…` — 사람이 보낸 파일이 아니라 메시지 앱이 미리보기를 그리려고 받아 둔 자료다.
/// - 제목·사이트 이름·요약은 `payload_data`(NSKeyedArchiver 바이너리 plist)의
///   `root → richLinkMetadata` 에 `title`·`siteName`·`summary`·`URL`·`originalURL` 로 들어 있다.
public enum RichLink {
    public static let urlBalloonBundleID = "com.apple.messages.URLBalloonProvider"

    /// 말풍선 앱(링크 미리보기 등)이 붙인 자료 첨부인지. 텔레그램에 파일로 올리지 않는다.
    public static func isPluginPayload(transferName: String) -> Bool {
        transferName.lowercased().hasSuffix(".pluginpayloadattachment")
    }

    public struct Metadata: Equatable {
        public var title: String?
        public var siteName: String?
        public var summary: String?
        public var url: String?
        public var originalURL: String?
        public init(title: String? = nil, siteName: String? = nil, summary: String? = nil, url: String? = nil, originalURL: String? = nil) {
            self.title = title; self.siteName = siteName; self.summary = summary; self.url = url; self.originalURL = originalURL
        }
    }

    /// `payload_data` 에서 링크 정보를 꺼낸다. 형식이 다르면 nil(그래도 링크 주소는 본문으로 보낸다).
    ///
    /// NSKeyedUnarchiver 는 쓰지 않는다 — 상대 기기가 만든 자료에서 임의의 클래스를 되살리지 않도록
    /// 데이터만 읽는 PropertyListSerialization 으로 열고, 객체 참조(UID)만 직접 따라간다.
    public static func parse(payload: Data) -> Metadata? {
        guard let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any] else { return nil }
        let archive = KeyedArchive(objects: objects)
        guard let root = archive.dictionary(top["root"]),
              let meta = archive.dictionary(root["richLinkMetadata"]) else { return nil }
        let m = Metadata(title: archive.string(meta["title"]), siteName: archive.string(meta["siteName"]),
                         summary: archive.string(meta["summary"]), url: archive.url(meta["URL"]),
                         originalURL: archive.url(meta["originalURL"]))
        return m == Metadata() ? nil : m
    }

    /// 텔레그램에 보낼 한 통: 제목 줄 + 원래 주소, 그리고 미리보기를 켤 주소.
    ///
    /// - 본문(`body`)은 상대가 보낸 그대로 둔다(주소가 잘리거나 바뀌지 않게). 비어 있으면 메타데이터의 주소를 쓴다.
    /// - 제목은 텔레그램 미리보기를 못 만들 때도 무엇에 대한 링크인지 알 수 있도록 앞에 한 줄로 붙인다.
    /// - 미리보기 주소는 본문에 실제로 있는 첫 링크다. 메시지 앱도 이 행에만 미리보기를 그리므로
    ///   텔레그램도 이 행에서만 미리보기를 켠다.
    public static func telegramText(body: String, metadata: Metadata?) -> (text: String, previewURL: String?) {
        var link = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.isEmpty { link = metadata?.originalURL ?? metadata?.url ?? "" }
        let previewURL = firstLink(in: link)
        var lines: [String] = []
        if let title = metadata?.title.map(oneLine), !title.isEmpty, !link.contains(title) {
            lines.append("🔗 " + title)
        }
        if !link.isEmpty { lines.append(link) }
        return (lines.joined(separator: "\n"), previewURL)
    }

    static func oneLine(_ s: String) -> String {
        AttributedBody.clean(s).split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func firstLink(in s: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        for match in detector.matches(in: s, range: range) {
            guard let r = Range(match.range, in: s), let url = match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            return String(s[r])
        }
        return nil
    }
}

/// NSKeyedArchiver 바이너리 plist 의 `$objects` 표를 UID 로 따라가는 최소 도우미.
private struct KeyedArchive {
    let objects: [Any]

    /// CFKeyedArchiverUID 는 Swift 에 값 접근자가 없어 설명 문자열(`…{value = N}`)에서 번호를 읽는다.
    func index(_ ref: Any?) -> Int? {
        guard let ref, !(ref is String), !(ref is [String: Any]), !(ref is [Any]) else { return nil }
        let d = String(describing: ref as AnyObject)
        guard d.hasPrefix("<CFKeyedArchiverUID"), let open = d.range(of: "{value = "),
              let close = d.range(of: "}", range: open.upperBound..<d.endIndex) else { return nil }
        return Int(d[open.upperBound..<close.lowerBound])
    }

    func resolve(_ ref: Any?) -> Any? {
        guard let i = index(ref), objects.indices.contains(i) else { return nil }
        let o = objects[i]
        if let s = o as? String, s == "$null" { return nil }
        return o
    }

    func dictionary(_ ref: Any?) -> [String: Any]? { resolve(ref) as? [String: Any] }

    func string(_ ref: Any?) -> String? {
        guard let s = resolve(ref) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// NSURL 은 `{NS.base, NS.relative}` 로 보관된다. 기준 주소가 없는 절대 주소만 쓴다.
    func url(_ ref: Any?) -> String? {
        guard let d = dictionary(ref), resolve(d["NS.base"]) == nil else { return nil }
        return string(d["NS.relative"])
    }
}
