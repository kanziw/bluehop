import AudioToolbox
import Foundation

// MARK: - 하위 프로세스 (셸 없이, argv 로만)

public struct ProcessResult { public var status: Int32; public var stdout: String; public var stderr: String }

public enum ProcessRunner {
    /// 셸을 거치지 않고 실행 파일을 직접 띄운다. 인자는 그대로 argv 가 된다.
    /// - Parameter stdin: 표준입력으로 넘길 값(비밀은 argv 가 아니라 여기로 — `ps` 에 보이지 않는다).
    /// - Parameter environment: 주면 이 환경만 쓴다(nil 이면 물려받음). `directory` 는 작업 폴더.
    public static func run(_ executable: String, _ args: [String], timeout: TimeInterval = 30, stdin: Data? = nil,
                           environment: [String: String]? = nil, directory: String? = nil) throws -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let environment { p.environment = environment }
        if let directory { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let input = stdin.map { _ in Pipe() }
        p.standardInput = input ?? FileHandle.nullDevice
        try p.run()
        if let input, let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            return ProcessResult(status: -9, stdout: "", stderr: "timeout")
        }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return ProcessResult(status: p.terminationStatus, stdout: o, stderr: e)
    }
}

// MARK: - 메시지 앱으로 보내기

public struct SendError: Error, CustomStringConvertible {
    public var description: String
    /// true 면 osascript 가 시간 제한으로 강제 종료된 경우 — 메시지 앱에 전달됐는지 알 수 없다
    /// (Apple Event 가 이미 전달된 뒤 kill 됐을 수 있음). 다른 실패(0 이 아닌 종료 코드에 오류가 또렷함)는 false.
    public var isAmbiguousTimeout: Bool
    public init(_ d: String, isAmbiguousTimeout: Bool = false) {
        description = d
        self.isAmbiguousTimeout = isAmbiguousTimeout
    }
}

public protocol MessagesSender: AnyObject {
    func sendText(_ text: String, chatGuid: String) throws
    func sendFile(_ path: String, chatGuid: String) throws
    /// 보내지 않고 대화가 메시지 앱에 있는지만 본다(doctor 용).
    func chatExists(_ chatGuid: String) throws -> Bool
}

/// AppleScript(osascript) 발신기. 본문·대상은 argv 로만 넘기고 스크립트 문자열에 끼워 넣지 않는다.
public final class AppleScriptSender: MessagesSender {
    /// 고정 스크립트. argv: 1=mode(text|file|exists) 2=chat guid 3=본문 또는 파일 경로
    public static let script = """
    on run argv
        set mode to item 1 of argv
        set targetChat to item 2 of argv
        if mode is "file" then
            set payloadFile to POSIX file (item 3 of argv)
        else if mode is "text" then
            set payloadText to item 3 of argv
        end if
        tell application "Messages"
            if mode is "exists" then
                return (exists chat id targetChat) as text
            end if
            set c to chat id targetChat
            if mode is "file" then
                send payloadFile to c
            else
                send payloadText to c
            end if
        end tell
        return "ok"
    end run
    """

    public init() {}

    /// osascript 한 번을 기다리는 최대 시간. 메시지 앱이 응답할 때까지(모달 대화상자가 떠 있거나
    /// 시스템이 바쁠 때 포함) 막힐 수 있어 넉넉히 둔다 — 짧추면 늦은 정상 응답까지 시간 제한으로 끊긴다.
    public static let sendTimeout: TimeInterval = 30

    private func run(_ mode: String, _ chatGuid: String, _ payload: String) throws -> String {
        let r = try ProcessRunner.run("/usr/bin/osascript", ["-e", Self.script, mode, chatGuid, payload], timeout: Self.sendTimeout)
        guard r.status == 0 else {
            // ProcessRunner 는 시간 제한에 걸리면 status=-9, stderr="timeout" 을 돌려준다(실제 종료 코드가
            // 아니라 우리가 강제로 만든 값) — osascript 를 죽였을 뿐 메시지 앱이 이미 받은 요청을 끝냈는지는
            // 모른다. 그 밖의 0 이 아닌 종료는 osascript·AppleScript 가 또렷하게 돌려준 실패다.
            if r.status == -9, r.stderr == "timeout" {
                throw SendError("osascript 응답 없음(\(Int(Self.sendTimeout))초 제한) — 메시지 앱에 전달됐는지 확인되지 않음", isAmbiguousTimeout: true)
            }
            // stderr 에는 본문이 섞이지 않는다(스크립트 오류 번호·설명). 길이만 제한해 남긴다.
            throw SendError("osascript 실패(\(r.status)): \(r.stderr.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func sendText(_ text: String, chatGuid: String) throws { _ = try run("text", chatGuid, text) }
    public func sendFile(_ path: String, chatGuid: String) throws { _ = try run("file", chatGuid, path) }
    public func chatExists(_ chatGuid: String) throws -> Bool { try run("exists", chatGuid, "") == "true" }
}

// MARK: - 미디어 변환 (macOS 기본 도구만: sips, afconvert)

public protocol MediaConverter: AnyObject {
    func toJPEG(_ input: URL, outputDir: URL) throws -> URL
    func toM4A(_ input: URL, outputDir: URL) throws -> URL
}

public final class SystemMediaConverter: MediaConverter {
    public init() {}

    public func toJPEG(_ input: URL, outputDir: URL) throws -> URL {
        let out = outputDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".jpg")
        let r = try ProcessRunner.run("/usr/bin/sips", ["-s", "format", "jpeg", input.path, "--out", out.path], timeout: 60)
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else { throw SendError("sips 변환 실패") }
        return out
    }

    public func toM4A(_ input: URL, outputDir: URL) throws -> URL {
        let out = outputDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".m4a")
        let r = try ProcessRunner.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", input.path, out.path], timeout: 120)
        guard r.status == 0, FileManager.default.fileExists(atPath: out.path) else { throw SendError("afconvert 변환 실패") }
        return out
    }
}

// MARK: - 첨부 분류

public enum AttachmentPlan: Equatable {
    case photo(convertToJPEG: Bool)
    case voice(convert: Bool)
    case audio(convert: Bool)
    case video
    case document
}

public enum AttachmentClassifier {
    public static let maxPhotoBytes: Int64 = 10 * 1024 * 1024
    public static let maxUploadBytes: Int64 = 50 * 1024 * 1024

    public static func plan(filename: String, mimeType: String?, uti: String?, isAudioMessage: Bool, bytes: Int64) -> AttachmentPlan {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = (mimeType ?? "").lowercased()
        let uti = (uti ?? "").lowercased()

        let audioExts: Set = ["caf", "m4a", "mp3", "amr", "aac", "wav", "aiff", "ogg", "oga", "opus"]
        if isAudioMessage || mime.hasPrefix("audio/") || audioExts.contains(ext) {
            // 텔레그램 음성은 OGG/Opus·MP3·M4A 만 받는다. 나머지는 m4a 로 바꾼다.
            let native: Set = ["m4a", "mp3"]
            let convert = !native.contains(ext)
            return isAudioMessage || ext == "caf" ? .voice(convert: convert) : .audio(convert: convert)
        }
        if mime == "image/gif" || ext == "gif" { return .document }
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "heif", "tiff", "webp"].contains(ext) || uti.contains("image") || uti.contains("jpeg") || uti.contains("heic") {
            let needsJPEG = !["jpg", "jpeg", "png"].contains(ext)
            if !needsJPEG && bytes > maxPhotoBytes { return .document }
            return .photo(convertToJPEG: needsJPEG)
        }
        if mime.hasPrefix("video/") || ["mov", "mp4", "m4v"].contains(ext) { return .video }
        return .document
    }

    static let mimeByExt: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "heic": "image/heic",
        "m4a": "audio/mp4", "mp3": "audio/mpeg", "caf": "audio/x-caf", "ogg": "audio/ogg", "oga": "audio/ogg",
        "mov": "video/quicktime", "mp4": "video/mp4", "pdf": "application/pdf",
    ]
    public static func mime(for filename: String) -> String {
        mimeByExt[(filename as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
    }

    /// 파일 이름에서 경로 구분자·제어 문자를 없앤다(텔레그램이 준 이름을 그대로 경로로 쓰지 않음).
    public static func safeFilename(_ name: String?, fallback: String) -> String {
        let base = (name ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "_")
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }
            .trimmingCharacters(in: .whitespaces)
        let cleaned = base.hasPrefix(".") ? "_" + base : base
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(120))
    }
}

// MARK: - 메시지 앱 샌드박스

/// 메시지 앱은 샌드박스 앱이라 entitlement 로 허용된 폴더의 파일만 읽는다. 그 밖의 파일을 AppleScript
/// `send POSIX file` 로 넘기면 osascript 는 성공하지만 chat.db 에 error=25·transfer_state=6 으로 실패가 남는다.
/// 허용 폴더는 `codesign -d --entitlements - /System/Applications/Messages.app` 의
/// `com.apple.security.temporary-exception.files.home-relative-path.read-write` 에서 확인한 값이다.
/// `~/Library/Messages` 도 허용되지만 이 프로그램은 그 폴더에 쓰지 않으므로 보낼 곳으로 쓰지 않는다.
public enum MessagesSandbox {
    public static func readableRoots(home: String = Paths.home) -> [String] {
        [home + "/Library/Caches/com.apple.MobileSMS", home + "/Media", home + "/Library/SMS", home + "/Library/Messages"]
    }

    /// 경로가 메시지 앱이 읽을 수 있는 폴더 안에 있는지(심볼릭 링크를 따라간 실제 경로 기준).
    public static func canRead(_ path: String, home: String = Paths.home) -> Bool {
        let real = ((path as NSString).expandingTildeInPath as NSString).resolvingSymlinksInPath
        return readableRoots(home: home).contains { root in
            let r = (root as NSString).resolvingSymlinksInPath
            return real == r || real.hasPrefix(r + "/")
        }
    }

    /// chat.db 의 실패 표시(message.error)를 사람이 읽을 설명으로 바꾼다. 본문은 넣지 않는다.
    public static func failureDetail(kind: String, errorCode: Int, outboxDir: String) -> String {
        guard kind == "file" else { return "메시지 앱이 실패로 표시(error=\(errorCode))" }
        if !canRead(outboxDir) {
            return "메시지 앱이 첨부를 보내지 못함(error=\(errorCode)) — 첨부를 둔 폴더를 메시지 앱이 읽을 수 없음(샌드박스). 설정 outboxDirectory 를 비워 기본 폴더를 쓰세요"
        }
        return "메시지 앱이 첨부를 보내지 못함(error=\(errorCode)) — 파일 위치는 정상이라 iMessage 연결·용량·형식 문제일 수 있음"
    }
}

// MARK: - 보낼 첨부를 두는 폴더

public enum OutboxStaging {
    /// `diag-send-file` 이 만드는 폴더 이름 앞부분. 정리 대상에 포함된다.
    public static let diagPrefix = "diag-"

    /// 보낼 첨부 폴더 아래에 `key` 이름의 빈 폴더(0700)를 새로 만든다. 같은 이름이 있으면 지우고 다시 만든다.
    public static func freshDirectory(_ key: String, in outboxDir: URL) throws -> URL {
        let dir = outboxDir.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}

// MARK: - 오디오 파일 형식 확인 (헤더만 읽는다)

public enum AudioCodecProbe {
    /// 오디오 파일의 컨테이너·코덱·샘플레이트·채널만 돌려준다. 음성 데이터는 읽지 않는다.
    public static func describe(_ path: String) -> String {
        var file: AudioFileID?
        guard AudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, .readPermission, 0, &file) == noErr, let file else { return "열기 실패" }
        defer { AudioFileClose(file) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd) == noErr else { return "형식 읽기 실패" }
        var type: AudioFileTypeID = 0
        var tsize = UInt32(MemoryLayout<AudioFileTypeID>.size)
        _ = AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &tsize, &type)
        return "\(fourCC(type))/\(fourCC(asbd.mFormatID))@\(Int(asbd.mSampleRate))Hz/\(asbd.mChannelsPerFrame)ch"
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
