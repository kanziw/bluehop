import Foundation

/// `imsg-relay diag-echo` 의 출력 생성. 본문은 내지 않고 길이·정규화 형식·코드포인트 차이만 낸다.
public enum EchoDiagnostics {
    public static func report(rows: [ChatDB.RawOwnRow], expected: String?) -> [String] {
        var out: [String] = []
        if let expected { out.append("expected " + shape(expected)) }
        for r in rows {
            var line = "rowid=\(r.rowid) item=\(r.itemType) assoc=\(r.associatedType) err=\(r.error) balloon=\(r.balloonBundleID ?? "-")"
            line += " textCol=" + (r.text.map { $0.isEmpty ? "empty" : shape($0) } ?? "NULL")
            if let blob = r.attributedBody {
                line += " blob=\(blob.count)B"
                if let x = AttributedBody.extractText(blob) {
                    line += " extracted=" + shape(x) + " lenPrefix=" + lengthPrefixHex(blob)
                } else {
                    line += " extracted=FAIL"
                }
            } else {
                line += " blob=NULL"
            }
            out.append(line)
            let raw = (r.text?.isEmpty == false ? r.text : r.attributedBody.flatMap(AttributedBody.extractText)) ?? ""
            if let expected {
                out.append("  raw-vs-expected: " + diff(raw, expected))
                out.append("  key-vs-key:      " + diff(EchoKey.normalize(raw), EchoKey.normalize(expected)))
            }
        }
        return out
    }

    static func shape(_ s: String) -> String {
        let sc = Array(s.unicodeScalars)
        let nfc = s.precomposedStringWithCanonicalMapping
        let nfd = s.decomposedStringWithCanonicalMapping
        let form = s.unicodeScalars.elementsEqual(nfc.unicodeScalars) ? "NFC" : (s.unicodeScalars.elementsEqual(nfd.unicodeScalars) ? "NFD" : "mixed")
        let special = sc.filter { !$0.isASCII && !(0xAC00...0xD7A3).contains($0.value) && !(0x1100...0x11FF).contains($0.value) }
            .map { String(format: "U+%04X", $0.value) }
        return "(utf8=\(s.utf8.count) scalars=\(sc.count) form=\(form) nonHangulNonASCII=[\(Set(special).sorted().joined(separator: ","))] ctrl=\(sc.filter { $0.value < 0x20 }.count))"
    }

    static func diff(_ a: String, _ b: String) -> String {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x == y { return "IDENTICAL" }
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        var j = 0
        while j < min(x.count, y.count) - i, x[x.count - 1 - j] == y[y.count - 1 - j] { j += 1 }
        func hex(_ s: ArraySlice<Unicode.Scalar>) -> String { s.prefix(12).map { String(format: "%04X", $0.value) }.joined(separator: " ") }
        return "DIFF lenA=\(x.count) lenB=\(y.count) firstDiff=\(i) commonSuffix=\(j) a[diff]=[\(hex(x[i..<(x.count - j)]))] b[diff]=[\(hex(y[i..<(y.count - j)]))]"
    }

    /// NSString 마커 뒤 '+' 부터 길이 접두까지의 바이트(본문 아님).
    static func lengthPrefixHex(_ blob: Data) -> String {
        let b = [UInt8](blob)
        guard let end = AttributedBody.find(Array("NSString".utf8), in: b) else { return "?" }
        let slice = b[end..<min(b.count, end + 10)]
        return slice.map { String(format: "%02X", $0) }.joined()
    }
}
