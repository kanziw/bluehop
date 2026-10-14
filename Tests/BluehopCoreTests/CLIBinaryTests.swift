import Foundation
import XCTest
@testable import BluehopCore

/// 빌드된 `bluehop` 을 실제로 실행해 에이전트가 기대는 겉모습(도움말·종료 코드·--json)을 본다.
/// 임시 설정 파일(--config)만 쓰고, chat.db·Keychain·네트워크·LaunchAgent 는 건드리지 않는 명령만 돌린다.
final class CLIBinaryTests: XCTestCase {
    var binary: String {
        Bundle(for: CLIBinaryTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("bluehop").path
    }

    func run(_ args: [String], stdin: String? = nil) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("bluehop 바이너리가 없다: \(binary)") }
        return try ProcessRunner.run(binary, args, timeout: 30, stdin: stdin.map { Data($0.utf8) })
    }

    func json(_ r: ProcessResult) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any], r.stdout + r.stderr)
    }

    func testEveryCommandHasHelp() throws {
        let commands = [["run"], ["chats"], ["list-chats"], ["mapping", "list"], ["mapping", "add"], ["mapping", "remove"],
                        ["mapping", "pause"], ["mapping", "resume"], ["mapping", "test"], ["doctor"], ["status"],
                        ["telegram-ids"], ["resume"], ["selfcheck-attributed"], ["diag-echo"], ["diag-send-file"], ["diag-audio"], ["version"]]
        for c in commands {
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
        XCTAssertEqual(try json(r)["version"] as? String, "0.5.0")
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
}
