import Foundation

/// chat.db `message.attributedBody`(NSArchiver typedstream) 에서 본문 문자열을 꺼낸다.
///
/// 최근 macOS 는 `text` 컬럼을 비워 두고 본문을 이 BLOB 에만 넣는 경우가 많다.
/// 구조: `… NSString <클래스 버전 등> '+' <길이> <UTF-8 바이트>`.
/// 길이 인코딩: 0x00–0x7F 는 그 값, 0x81 은 뒤 2바이트(LE), 0x82 는 뒤 4바이트(LE).
public enum AttributedBody {
    private static let markers: [[UInt8]] = [Array("NSString".utf8), Array("NSMutableString".utf8)]

    public static func extractText(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        for marker in markers {
            guard let markerEnd = find(marker, in: bytes) else { continue }
            // 마커 뒤 짧은 구간 안에서 '+'(0x2B, C 문자열 타입 태그)를 찾는다.
            let searchEnd = min(bytes.count, markerEnd + 16)
            var i = markerEnd
            while i < searchEnd, bytes[i] != 0x2B { i += 1 }
            guard i < searchEnd else { continue }
            i += 1
            guard let (length, start) = readLength(bytes, at: i) else { continue }
            guard length >= 0, start + length <= bytes.count else { continue }
            if let s = String(bytes: bytes[start..<(start + length)], encoding: .utf8) {
                return s
            }
        }
        return nil
    }

    static func readLength(_ b: [UInt8], at i: Int) -> (Int, Int)? {
        guard i < b.count else { return nil }
        let tag = b[i]
        switch tag {
        case 0x81:
            guard i + 2 < b.count else { return nil }
            return (Int(b[i + 1]) | Int(b[i + 2]) << 8, i + 3)
        case 0x82:
            guard i + 4 < b.count else { return nil }
            let v = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16 | Int(b[i + 4]) << 24
            return (v, i + 5)
        case 0x80, 0x83...0xFF:
            return nil
        default:
            return (Int(tag), i + 1)
        }
    }

    /// `needle` 이 처음 나오는 곳의 **끝** 인덱스.
    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = 0
        while i <= hay.count - needle.count {
            if hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle {
                return i + needle.count
            }
            i += 1
        }
        return nil
    }

    /// 메시지 본문 정리: 첨부 자리표시(U+FFFC) 제거 · 줄바꿈 정규화 · NFC 합성 · 앞뒤 공백 제거.
    ///
    /// 메시지 앱은 한글을 NFD(자모 분해)로 적는다. 텔레그램에 그대로 올려도 보이긴 하지만 검색·복사가
    /// 어긋나므로 NFC 로 합쳐 둔다. 메아리 비교는 이보다 넓은 규칙의 `EchoKey.normalize` 가 맡는다.
    ///
    /// 메시지 앱은 여러 줄 글을 chat.db 에 적을 때 줄바꿈을 `\n` 이 아니라 유니코드
    /// LINE/PARAGRAPH SEPARATOR(U+2028/U+2029)로 바꿔 쓸 수 있다. 텔레그램에서 보낸 글(`\n`)을
    /// 그대로 다시 읽어 메아리로 맞추려면(`matchEcho`) 양쪽을 같은 모양으로 둬야 한다 — 안 그러면
    /// 본문 비교가 실패해 내가 보낸 글이 "iPhone 에서 직접 보낸 글"로 오인되어 텔레그램에 다시
    /// 올라가고, 상대 반응·답글이 원래 글이 아니라 그 메아리에 붙고, 60초 뒤 거짓 ⚠️ 가 달린다.
    public static func clean(_ s: String?) -> String {
        guard let s else { return "" }
        var out = s.replacingOccurrences(of: "\u{FFFC}", with: "")
        for sep in ["\r\n", "\u{2028}", "\u{2029}", "\r"] {
            out = out.replacingOccurrences(of: sep, with: "\n")
        }
        return out.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 테스트·자가 점검용: 주어진 문자열을 typedstream 과 같은 모양으로 감싼다.
    public static func encodeForTesting(_ s: String) -> Data {
        var out = [UInt8]()
        out += [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12]
        out += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84, 0x08] + Array("NSObject".utf8)
        out += [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08] + Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        let u = Array(s.utf8)
        if u.count < 0x80 {
            out.append(UInt8(u.count))
        } else if u.count <= 0xFFFF {
            out += [0x81, UInt8(u.count & 0xFF), UInt8(u.count >> 8)]
        } else {
            out += [0x82, UInt8(u.count & 0xFF), UInt8((u.count >> 8) & 0xFF), UInt8((u.count >> 16) & 0xFF), UInt8(u.count >> 24)]
        }
        out += u
        out += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x92]
        return Data(out)
    }
}
