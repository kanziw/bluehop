import Foundation
import XCTest
@testable import BluehopCore

/// 빌드된 `bluehop` 을 실제로 실행해 에이전트가 기대는 겉모습(도움말·종료 코드·--json)을 본다.
/// 임시 설정 파일(--config)만 쓰고, chat.db·Keychain·네트워크·LaunchAgent 는 건드리지 않는 명령만 돌린다.
/// 홈 폴더(HOME·CFFIXED_USER_HOME)와 작업 폴더도 테스트마다 빈 임시 폴더로 바꿔 실제 설정·상태 DB·chat.db 에 닿지 않게 한다.
final class CLIBinaryTests: XCTestCase {
    var binary: String {
        Bundle(for: CLIBinaryTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("bluehop").path
    }

    lazy var home = makeTempDir()
    lazy var workDir = makeTempDir()

    var isolatedEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["CFFIXED_USER_HOME"] = home.path
        env.removeValue(forKey: "BLUEHOP_LANG")
        return env
    }

    func run(_ args: [String], stdin: String? = nil, env: [String: String] = [:]) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("bluehop 바이너리가 없다: \(binary)") }
        return try ProcessRunner.run(binary, args, timeout: 30, stdin: stdin.map { Data($0.utf8) },
                                     environment: isolatedEnvironment.merging(env) { _, new in new }, directory: workDir.path)
    }

    /// 에이전트가 부를 수 있는 모든 명령(별칭 포함). 새 명령을 넣으면 여기에도 넣는다.
    static let allCommands = [["run"], ["chats"], ["list-chats"], ["mapping", "list"], ["mapping", "add"], ["mapping", "remove"],
                              ["mapping", "pause"], ["mapping", "resume"], ["mapping", "test"], ["doctor"], ["status"],
                              ["telegram-ids"], ["notify"], ["resume"], ["selfcheck-attributed"], ["diag-echo"], ["diag-send-file"],
                              ["diag-audio"], ["version"]]

    func entries(_ dir: URL) -> [String] {
        (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? []
    }

    func json(_ r: ProcessResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any], r.stdout + r.stderr)
    }

    func testEveryCommandHasHelp() throws {
        for c in Self.allCommands {
            let r = try run(c + ["--help"])
            XCTAssertEqual(r.status, 0, c.joined(separator: " "))
            XCTAssertTrue(r.stdout.hasPrefix("bluehop " + c.joined(separator: " ")), r.stdout)
            XCTAssertTrue(r.stdout.contains("종료 코드"))
        }
        let top = try run(["--help"])
        XCTAssertEqual(top.status, 0)
        XCTAssertTrue(top.stdout.contains("mapping add"))
        XCTAssertEqual(try run(["help", "mapping", "add"]).stdout, try run(["mapping", "add", "--help"]).stdout)
        XCTAssertEqual(try run(["mapping", "--help"]).status, 0)
        XCTAssertEqual(try run([]).status, 2)
    }

    /// `--help`/`-h` 는 어디에 있든(모르는 옵션 뒤, 다른 옵션의 값 자리) 다른 일보다 먼저 도움말로 끝나고,
    /// 모르는 옵션은 종료 코드 2 로 끝난다. 둘 다 홈·작업 폴더에 아무것도 만들지 않는다(`run` 이 중계를 시작하지 않는다).
    func testHelpAndUnknownFlagsHaveNoSideEffects() throws {
        let helpForms: [[String]] = [["--help"], ["-h"], ["--bogus-flag", "--help"], ["-h", "--bogus-flag"],
                                     ["--config", "-h"], ["--mapping", "--help"], ["extra", "positional", "-h"]]
        let badForms: [[String]] = [["--bogus-flag"], ["-x"], ["--bogus-flag=1"], ["--json", "--bogus-flag"]]
        for c in Self.allCommands {
            let name = c.joined(separator: " ")
            for form in helpForms {
                let r = try run(c + form)
                XCTAssertEqual(r.status, 0, "\(name) \(form): \(r.stderr)")
                XCTAssertTrue(r.stdout.hasPrefix("bluehop " + name), "\(name) \(form): \(r.stdout.prefix(80))")
            }
            for form in badForms {
                let r = try run(c + form)
                XCTAssertEqual(r.status, 2, "\(name) \(form): \(r.stdout) \(r.stderr)")
                XCTAssertTrue(r.stderr.contains("모르는 옵션"), "\(name) \(form): \(r.stderr)")
            }
        }
        XCTAssertEqual(entries(home), [], "홈 폴더에 생긴 파일")
        XCTAssertEqual(entries(workDir), [], "작업 폴더에 생긴 파일")
    }

    func testUnknownCommandsAndFlagsFail() throws {
        XCTAssertEqual(try run(["nope"]).status, 2)
        XCTAssertEqual(try run(["mapping", "nope"]).status, 2)
        let r = try run(["status", "--jsno"])
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.stderr.contains("--jsno"))
        let j = try run(["mapping", "list", "--json", "--bogus"])
        XCTAssertEqual(j.status, 2)
        XCTAssertEqual((try json(j)["error"] as? [String: Any])?["kind"] as? String, "usage")
        XCTAssertEqual(try run(["mapping", "remove"]).status, 2)
        XCTAssertEqual(try run(["version", "extra"]).status, 2)
    }

    func testVersionJSON() throws {
        let r = try run(["version", "--json"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(try json(r)["version"] as? String, "0.5.6")
    }

    func testMappingListPauseResumeRemoveOnTempConfig() throws {
        let dir = makeTempDir()
        let cfg = dir.appendingPathComponent("config.json").path
        // 설정이 없으면 빈 목록
        var r = try run(["mapping", "list", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(try json(r)["configExists"] as? Bool, false)

        // 0.4.x 설정은 default 로 보인다
        _ = writePrivate(legacyJSON, in: dir)
        r = try run(["mapping", "list", "--json", "--config", cfg])
        var obj = try json(r)
        XCTAssertEqual(obj["legacy"] as? Bool, true)
        XCTAssertEqual(obj["configVersion"] as? Int, 1)
        let maps = try XCTUnwrap(obj["mappings"] as? [[String: Any]])
        XCTAssertEqual(maps.map { $0["id"] as? String }, ["default"])
        XCTAssertEqual((maps[0]["telegram"] as? [String: Any])?["tokenAccount"] as? String, "telegram-bot-token")

        // 멈추기 → 버전 2 로 옮기고 백업
        r = try run(["mapping", "pause", "default", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 0, r.stderr)
        obj = try json(r)
        XCTAssertEqual(obj["enabled"] as? Bool, false)
        XCTAssertEqual(obj["configBackup"] as? String, cfg + ".v1-backup")
        XCTAssertEqual(try ConfigLoader.load(path: cfg).mapping("default")?.enabled, false)
        r = try run(["mapping", "resume", "default", "--config", cfg])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(try ConfigLoader.load(path: cfg).mapping("default")?.enabled, true)

        // 없는 id
        r = try run(["mapping", "pause", "nope", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 4)
        XCTAssertEqual((try json(r)["error"] as? [String: Any])?["kind"] as? String, "not_found")

        // status 는 상태 DB 가 없어도 매핑마다 한 줄
        r = try run(["status", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 0, r.stderr)
        let st = try XCTUnwrap(try json(r)["mappings"] as? [[String: Any]])
        XCTAssertEqual(st.map { $0["verdict"] as? String }, ["unknown"])

        // 지우기(Keychain 은 건드리지 않게 --keep-token)
        r = try run(["mapping", "remove", "default", "--keep-token", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(try json(r)["tokenDeleted"] as? Bool, false)
        XCTAssertEqual(try ConfigLoader.load(path: cfg).mappings.count, 0)
    }

    func testAddRefusesTokenOnArgvAndWithoutStdin() throws {
        let cfg = makeTempDir().appendingPathComponent("config.json").path
        // 토큰을 인자로 받는 옵션은 없다
        XCTAssertEqual(try run(["mapping", "add", "--token", "123:abc", "--config", cfg]).status, 2)
        // 터미널이 아니고 토큰 입력 방법이 없으면 사용법 오류
        let r = try run(["mapping", "add", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 2)
        XCTAssertTrue(r.stderr.contains("--token-stdin"))
        // 형식이 틀린 토큰은 네트워크 전에 거부(1)
        let bad = try run(["mapping", "add", "--token-stdin", "--json", "--config", cfg], stdin: "not-a-token\n")
        XCTAssertEqual(bad.status, 1)
        XCTAssertFalse(bad.stdout.contains("not-a-token"))
        XCTAssertFalse(bad.stderr.contains("not-a-token"))
    }

    /// `notify` 의 인자 검사(매핑 선택·글 출처)는 네트워크·Keychain 에 닿기 전에 끝난다 — 모두 거짓 토큰 설정으로 돈다.
    func testNotifyArgumentValidationHasNoNetworkSideEffects() throws {
        let cfg = fileTokenConfig()  // 매핑 하나: family
        XCTAssertEqual(try run(["notify", "--config", makeTempDir().appendingPathComponent("config.json").path,
                                "--all", "--text", "hi"]).status, 1, "설정 없음")
        XCTAssertEqual(try run(["notify", "--mapping", "family", "--all", "--text", "hi", "--config", cfg]).status, 2,
                      "--mapping 과 --all 동시 지정")
        let noText = try run(["notify", "--all", "--config", cfg])
        XCTAssertEqual(noText.status, 2, noText.stderr)
        XCTAssertTrue(noText.stderr.contains("--text"), noText.stderr)
        XCTAssertEqual(try run(["notify", "--all", "--text", "hi", "--text-stdin", "--config", cfg]).status, 2, "--text 와 --text-stdin 동시 지정")
        let notFound = try run(["notify", "--mapping", "nope", "--text", "hi", "--json", "--config", cfg])
        XCTAssertEqual(notFound.status, 4, notFound.stderr)
        XCTAssertEqual((try json(notFound)["error"] as? [String: Any])?["kind"] as? String, "not_found")

        let emptyCfg = writePrivate("""
            {"version":2,"mappings":[]}
            """, in: makeTempDir())
        let noMappings = try run(["notify", "--all", "--text", "hi", "--json", "--config", emptyCfg])
        XCTAssertEqual(noMappings.status, 4, noMappings.stderr)

        // 설정 하나뿐이면 --mapping·--all 없이도 그 매핑으로 고른다(다른 명령과 같은 관례) — 거짓 토큰이라 전송 전에 실패.
        let autoSelected = try run(["notify", "--text", "hi", "--json", "--config", cfg])
        XCTAssertEqual(autoSelected.status, 1, autoSelected.stderr)
        let r = try json(autoSelected)
        let results = try XCTUnwrap(r["results"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["mapping"] as? String }, ["family"])
        XCTAssertEqual(results[0]["ok"] as? Bool, false)
        XCTAssertEqual(results[0]["code"] as? String, "TOKEN_FORMAT")
        XCTAssertTrue(results[0]["messageId"] is NSNull)

        XCTAssertEqual(entries(home), [], "홈 폴더에 생긴 파일(Keychain·네트워크에 닿지 않아야 한다)")
    }

    /// 토큰 파일(형식이 틀림)을 쓰는 매핑 하나: Keychain·네트워크 없이 doctor 가 실패 코드를 낸다.
    func fileTokenConfig() -> String {
        let dir = makeTempDir()
        let tokenPath = writePrivate("not-a-token\n", in: dir, name: "token")
        return writePrivate("""
            {"version":2,"mappings":[{"id":"family","enabled":true,
             "telegram":{"chatId":555,"allowedUserId":777,"tokenSource":"file","tokenFile":"\(tokenPath)"},
             "imessage":{"chatGuid":"any;-;+821011112222","handle":"+821011112222"}}]}
            """, in: dir)
    }

    func testDoctorJSONHasStableIdsAndCodes() throws {
        // 설정 없음
        let missing = makeTempDir().appendingPathComponent("config.json").path
        var r = try run(["doctor", "--json", "--config", missing])
        XCTAssertEqual(r.status, 1)
        var obj = try json(r)
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual((obj["config"] as? [String: Any])?["code"] as? String, "CONFIG_MISSING")
        XCTAssertEqual((obj["config"] as? [String: Any])?["id"] as? String, "config")
        XCTAssertEqual(obj["codes"] as? [String], ["CONFIG_MISSING"])

        // 틀린 토큰 + chat.db 없음(빈 홈)
        let cfg = fileTokenConfig()
        r = try run(["doctor", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 1, r.stderr)
        obj = try json(r)
        XCTAssertEqual((obj["config"] as? [String: Any])?["code"] as? String, "OK")
        let m = try XCTUnwrap((obj["mappings"] as? [[String: Any]])?.first)
        let checks = try XCTUnwrap(m["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.map { $0["id"] as? String }, ["token", "chatdb"])
        XCTAssertEqual(checks.map { $0["code"] as? String }, ["TOKEN_FORMAT", "CHATDB_UNREADABLE"])
        for c in checks { XCTAssertEqual(Set(c.keys), ["id", "name", "title", "ok", "code", "detail", "message"]) }
        XCTAssertEqual(m["codes"] as? [String], ["TOKEN_FORMAT", "CHATDB_UNREADABLE"])
        XCTAssertEqual(obj["codes"] as? [String], ["TOKEN_FORMAT", "CHATDB_UNREADABLE"])
        XCTAssertFalse(r.stdout.contains("not-a-token"))

        // mapping test 도 같은 모양(텔레그램은 토큰을 못 읽어 건너뜀 — 네트워크 없음)
        r = try run(["mapping", "test", "family", "--json", "--config", cfg])
        XCTAssertEqual(r.status, 1)
        let t = try XCTUnwrap(((try json(r))["mappings"] as? [[String: Any]])?.first?["checks"] as? [[String: Any]])
        XCTAssertEqual(t.map { $0["code"] as? String }, ["TOKEN_FORMAT", "CHATDB_UNREADABLE", "TELEGRAM_SKIPPED"])
        XCTAssertEqual(entries(home), [])
    }

    func testEnglishOutputForDoctorAndStatus() throws {
        let cfg = fileTokenConfig()
        let isHangul: (String) -> Bool = { $0.unicodeScalars.contains { $0.value >= 0xAC00 && $0.value <= 0xD7A3 } }
        for (args, env) in [(["doctor", "--lang", "en", "--config", cfg], [String: String]()),
                            (["doctor", "--config", cfg], ["BLUEHOP_LANG": "en"])] {
            let r = try run(args, env: env)
            XCTAssertEqual(r.status, 1)
            XCTAssertTrue(r.stdout.contains("[TOKEN_FORMAT]"), r.stdout)
            XCTAssertTrue(r.stdout.contains("[CHATDB_UNREADABLE]"), r.stdout)
            XCTAssertFalse(isHangul(r.stdout), r.stdout)
        }
        let ko = try run(["doctor", "--config", cfg])
        XCTAssertTrue(ko.stdout.contains("봇 토큰"), ko.stdout)
        let st = try run(["status", "--lang", "en", "--config", cfg])
        XCTAssertEqual(st.status, 0, st.stderr)
        XCTAssertTrue(st.stdout.hasPrefix("service dev.kanziw.bluehop: "), st.stdout)
        XCTAssertTrue(st.stdout.contains("[family] unknown"), st.stdout)
        XCTAssertFalse(isHangul(st.stdout), st.stdout)
        let sj = try json(try run(["status", "--json", "--config", cfg]))
        XCTAssertEqual(sj["schemaVersion"] as? Int, 1)
        let row = try XCTUnwrap((sj["mappings"] as? [[String: Any]])?.first)
        XCTAssertTrue(row.keys.contains("lastErrorCode"))
        XCTAssertTrue(row["lastErrorCode"] is NSNull)
        // 로그 파일 위치는 status --json 과 사람이 읽는 줄 모두에 보인다(둘 다 같은 경로를 가리킨다).
        // `run()` 이 격리된 HOME 으로 바꿔 돌리므로, 기대값도 그 HOME 기준으로 계산한다.
        let expectedEventLog = home.appendingPathComponent("Library/Logs/bluehop-events.jsonl").path
        let logs = try XCTUnwrap(sj["logs"] as? [String: Any])
        XCTAssertEqual(logs["text"] as? String, home.appendingPathComponent("Library/Logs/bluehop.log").path)
        XCTAssertEqual(logs["events"] as? String, expectedEventLog)
        XCTAssertTrue(st.stdout.contains(expectedEventLog), st.stdout)
        let dj = try json(try run(["doctor", "--json", "--config", cfg]))
        XCTAssertEqual((dj["logs"] as? [String: Any])?["events"] as? String, expectedEventLog)
        // 모르는 언어는 사용법 오류
        XCTAssertEqual(try run(["doctor", "--lang", "fr", "--config", cfg]).status, 2)
        XCTAssertEqual(try run(["status", "--config", cfg], env: ["BLUEHOP_LANG": "fr"]).status, 2)
    }
}
