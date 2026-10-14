import Foundation
import BluehopCore

/// 터미널 입출력(사람이 쓰는 대화형 모드에서만). 안내·화면은 표준오류로 써서 표준출력(`--json`)을 더럽히지 않는다.
enum Terminal {
    static var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDERR_FILENO) == 1 }

    /// 원시 모드로 화살표 키를 읽을 수 있는 터미널인가.
    static var supportsRawMode: Bool {
        guard isInteractive else { return false }
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        if term.isEmpty || term == "dumb" { return false }
        var t = termios()
        return tcgetattr(STDIN_FILENO, &t) == 0
    }

    static func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }

    static func readLine() -> String? {
        Swift.readLine(strippingNewline: true)
    }

    /// 화면 너비(열). 모르면 80.
    static var columns: Int {
        var w = winsize()
        if ioctl(STDERR_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 { return Int(w.ws_col) }
        return 80
    }

    /// 표시 폭(한글·한자 등 넓은 글자는 2칸)에 맞춰 자른다.
    static func fit(_ s: String, width: Int) -> String {
        var out = ""
        var used = 0
        for ch in s {
            let w = ch.unicodeScalars.contains { isWide($0) } ? 2 : 1
            if used + w > width { break }
            out.append(ch)
            used += w
        }
        return out
    }

    static func isWide(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    // MARK: 끝날 때 터미널 되돌리기

    nonisolated(unsafe) static var saved: termios?

    static func restore() {
        if var t = saved {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &t)
            saved = nil
        }
        write("\u{1B}[?25h")
    }

    /// Ctrl-C 로 끝나도 입력 표시·커서를 되돌린다.
    static func installInterruptHandler() {
        signal(SIGINT) { _ in
            Terminal.restore()
            Terminal.write("\n취소했습니다.\n")
            exit(ExitCode.cancelled.rawValue)
        }
    }

    /// 입력을 화면에 보이지 않게 한 줄 읽는다(봇 토큰용).
    static func readHidden(prompt: String) -> String? {
        write(prompt)
        var t = termios()
        guard tcgetattr(STDIN_FILENO, &t) == 0 else { return readLine() }
        saved = t
        var quiet = t
        quiet.c_lflag &= ~tcflag_t(ECHO)
        quiet.c_lflag |= tcflag_t(ECHONL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet)
        defer { restore() }
        return readLine()
    }

    /// 화살표 키 대화 고르기. 원시 모드를 못 쓰면 번호 고르기.
    static func pick(_ items: [ChatPicker.Item], title: String) throws -> ChatPicker.Item {
        guard supportsRawMode else { return try pickNumbered(items, title: title) }
        var t = termios()
        guard tcgetattr(STDIN_FILENO, &t) == 0 else { return try pickNumbered(items, title: title) }
        saved = t
        var raw = t
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        defer { restore() }

        var picker = ChatPicker(items: items, pageSize: 12)
        var drawn = 0
        func draw() {
            let width = max(20, columns - 1)
            var s = drawn > 0 ? "\u{1B}[\(drawn)A\r\u{1B}[J" : "\u{1B}[?25l"
            let lines = picker.render(title: title).map { fit($0, width: width) }
            s += lines.joined(separator: "\n") + "\n"
            write(s)
            drawn = lines.count
        }
        draw()
        var pending: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 64)
        while true {
            let n = read(STDIN_FILENO, &buf, buf.count)
            if n <= 0 { throw CLIError(.cancelled, "입력이 끊겼습니다") }
            let (keys, rest) = KeyDecoder.decode(pending + buf[0..<n])
            pending = rest
            for k in keys {
                switch picker.handle(k) {
                case .pending: continue
                case .cancelled: throw CLIError(.cancelled, "대화 고르기를 취소했습니다")
                case .picked(let item):
                    write("› 고름: \(item.handle)\n")
                    return item
                }
            }
            draw()
        }
    }

    static func pickNumbered(_ items: [ChatPicker.Item], title: String) throws -> ChatPicker.Item {
        write(title + "\n" + NumberedChoice.render(items).joined(separator: "\n") + "\n")
        while true {
            write("번호 (q 취소): ")
            switch NumberedChoice.choose(readLine(), items: items) {
            case .picked(let it): return it
            case .cancelled: throw CLIError(.cancelled, "대화 고르기를 취소했습니다")
            case .invalid(let why): write("! \(why)\n")
            }
        }
    }
}

/// `mapping add` 의 대화형 질문(터미널일 때만).
final class TerminalInteraction: AddInteraction {
    func pickChat(_ items: [ChatPicker.Item]) throws -> ChatPicker.Item {
        try Terminal.pick(items, title: "묶을 iMessage 1:1 대화를 고르세요 (최근 순)")
    }

    func askID(suggested: String) throws -> String {
        Terminal.write("매핑 id (소문자·숫자·-) [\(suggested)]: ")
        guard let line = Terminal.readLine() else { throw CLIError(.cancelled, "입력이 끊겼습니다") }
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? suggested : t
    }

    func confirmSender(_ s: DetectedSender, bot: String) throws -> Bool {
        Terminal.write("텔레그램 \(s.name ?? "사용자") (user id \(s.userID), chat \(s.chatID)) 가 @\(bot) 에게 보냈습니다. 이 사람으로 할까요? [Y/n] ")
        guard let line = Terminal.readLine() else { throw CLIError(.cancelled, "입력이 끊겼습니다") }
        let a = line.trimmingCharacters(in: .whitespaces).lowercased()
        return a.isEmpty || a == "y" || a == "yes" || a == "예" || a == "네"
    }
}
