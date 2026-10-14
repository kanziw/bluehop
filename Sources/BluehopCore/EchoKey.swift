import Foundation

/// 메아리 맞춤용 본문 키. 텔레그램에서 보낸 글과, 메시지 앱이 chat.db 에 다시 적은 글을
/// 같은 규칙으로 접어 "같은 글"인지 비교한다. 이 키는 비교에만 쓰고 화면에 보이지 않는다.
///
/// 메시지 앱은 보낸 글을 그대로 적지 않는다. 확인된 차이:
/// - 한글을 **NFD(자모 분해)** 로 적는다 — `가`(U+AC00)가 `ᄀ`+`ᅡ`(U+1100 U+1161)가 된다.
///   텔레그램 글은 NFC 라 한국어 글은 바이트·스칼라가 모두 달라진다(ASCII 는 영향 없음).
/// - 여러 줄 글의 줄바꿈을 U+2028/U+2029 로 적을 수 있다.
/// 그 밖에 메시지 앱의 스마트 구두점(곧은 따옴표 → 둥근 따옴표, `--` → 대시, `...` → 말줄임표)과
/// 보이지 않는 문자(폭 없는 공백·BOM·제어문자)도 같은 모양으로 접는다.
public enum EchoKey {
    public static func normalize(_ s: String) -> String {
        let nfc = AttributedBody.clean(s).precomposedStringWithCanonicalMapping
        var out = String.UnicodeScalarView()
        var lastWasSpace = false
        var lastWasDash = false
        for u in nfc.unicodeScalars {
            let mapped: String
            switch u.value {
            case 0x2018, 0x2019, 0x201A, 0x201B, 0x2032: mapped = "'"
            case 0x201C, 0x201D, 0x201E, 0x201F, 0x2033: mapped = "\""
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212: mapped = "-"
            case 0x2026: mapped = "..."
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0xFFFC: mapped = ""
            case 0x0A: mapped = "\n"
            case 0x09, 0x20, 0xA0, 0x2007, 0x202F, 0x3000, 0x2000...0x200A: mapped = " "
            case 0x00...0x1F, 0x7F: mapped = ""
            default: mapped = String(u)
            }
            for m in mapped.unicodeScalars {
                if m == " " {
                    if lastWasSpace { continue }
                    lastWasSpace = true; lastWasDash = false
                } else if m == "-" {
                    if lastWasDash { continue }
                    lastWasDash = true; lastWasSpace = false
                } else {
                    lastWasSpace = false; lastWasDash = false
                }
                out.append(m)
            }
        }
        // 줄 끝 공백은 메시지 앱·텔레그램 어느 쪽이든 떨어질 수 있어 비교에서 뺀다.
        return String(out).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 로그용 지문: 본문 없이 길이와 짧은 해시(FNV-1a 32bit)만.
    public static func fingerprint(_ s: String) -> String {
        var h: UInt32 = 0x811C_9DC5
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 0x0100_0193 }
        return "len=\(s.unicodeScalars.count)/h=\(String(format: "%08x", h))"
    }

    /// 로그용: 두 키가 앞에서부터 같은 스칼라 수.
    public static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a.unicodeScalars, b.unicodeScalars).prefix { $0 == $1 }.count
    }
}
