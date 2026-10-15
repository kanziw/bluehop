import Foundation
import XCTest
@testable import BluehopCore

/// `scripts/*.sh` 의 `--help`/`-h` 와 모르는 인자. 도움말은 아무 일도 하기 전에 끝나야 한다.
/// 실수로 본 작업이 돌더라도 실제 시스템에 닿지 않게: 홈은 빈 임시 폴더, PATH 맨 앞의 가짜
/// launchctl·security·codesign·swift·git·plutil 은 불린 사실만 기록하고 실패한다.
final class ScriptArgsTests: XCTestCase {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    lazy var home = makeTempDir()
    lazy var stubs = makeTempDir()
    var stubLog: URL { stubs.appendingPathComponent("calls.log") }

    override func setUpWithError() throws {
        for tool in ["launchctl", "security", "codesign", "swift", "git", "plutil", "osascript"] {
            let path = stubs.appendingPathComponent(tool)
            try "#!/bin/sh\necho \"\(tool) $*\" >> \"\(stubLog.path)\"\nexit 1\n".write(to: path, atomically: true, encoding: .utf8)
            chmod(path.path, 0o755)
        }
    }

    func run(_ script: String, _ args: [String]) throws -> ProcessResult {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["CFFIXED_USER_HOME"] = home.path
        env["PATH"] = stubs.path + ":/usr/bin:/bin"
        env.removeValue(forKey: "BLUEHOP_BIN")
        return try ProcessRunner.run("/bin/bash", [repo.appendingPathComponent("scripts/\(script)").path] + args,
                                     timeout: 30, environment: env, directory: home.path)
    }

    func assertUntouched(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let calls = (try? String(contentsOf: stubLog, encoding: .utf8)) ?? ""
        XCTAssertEqual(calls, "", "\(what): 불린 도구", file: file, line: line)
        let made = (FileManager.default.enumerator(atPath: home.path)?.allObjects as? [String]) ?? []
        XCTAssertEqual(made, [], "\(what): 홈에 생긴 파일", file: file, line: line)
    }

    static let scripts = ["install.sh", "uninstall.sh", "agent-run.sh", "build-release.sh", "check.sh", "setup-dev.sh", "publish-site.sh"]

    func testHelpExitsZeroBeforeDoingAnything() throws {
        for s in Self.scripts {
            for form in [["--help"], ["-h"], ["--bogus", "--help"]] {
                if s == "agent-run.sh" && form.first == "--bogus" { continue }  // agent-run 은 첫 인자를 bluehop 명령으로 본다
                let r = try run(s, form)
                XCTAssertEqual(r.status, 0, "\(s) \(form): \(r.stderr)")
                XCTAssertTrue(r.stdout.hasPrefix("usage: bash scripts/\(s)"), "\(s) \(form): \(r.stdout.prefix(80))")
                assertUntouched("\(s) \(form)")
            }
        }
        // install.sh 도움말은 서비스를 멈추고 다시 켠다는 것을 알린다
        XCTAssertTrue(try run("install.sh", ["--help"]).stdout.contains("bootout"))
        XCTAssertTrue(try run("uninstall.sh", ["--help"]).stdout.contains("Irreversible"))
    }

    func testUnknownArgumentsExitTwoBeforeDoingAnything() throws {
        for s in Self.scripts where s != "agent-run.sh" {
            for form in [["--bogus"], ["--no-load", "--purge"], ["extra"]] {
                if (s == "install.sh" && form == ["--no-load", "--purge"]) {
                    let r = try run(s, form)
                    XCTAssertEqual(r.status, 2, "\(s) \(form)")
                    XCTAssertTrue(r.stderr.contains("--purge"))
                    assertUntouched("\(s) \(form)")
                    continue
                }
                let r = try run(s, form)
                XCTAssertEqual(r.status, 2, "\(s) \(form): \(r.stdout) \(r.stderr)")
                XCTAssertTrue(r.stderr.contains("unknown argument"), "\(s) \(form): \(r.stderr)")
                assertUntouched("\(s) \(form)")
            }
        }
    }

    func testAgentRunNeverStartsALaunchdJobForHelp() throws {
        // 설치된 바이너리가 없는 빈 홈: 도움말 요청은 launchd 작업 없이 끝난다
        for form in [["doctor", "--help"], ["chats", "-h"], ["run", "--config", "-h"]] {
            let r = try run("agent-run.sh", form)
            XCTAssertEqual(r.status, 0, "\(form): \(r.stderr)")
            assertUntouched("agent-run.sh \(form)")
        }
        // 인자 없음은 사용법 오류
        XCTAssertEqual(try run("agent-run.sh", []).status, 2)
        assertUntouched("agent-run.sh (no args)")
    }
}
