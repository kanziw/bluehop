import Foundation
import XCTest
@testable import BluehopCore

/// 인자 해석·JSON 모양·도움말. 에이전트가 기대는 계약이라 고정한다.
final class CLIParsingTests: XCTestCase {
    let spec = CommandSpec("mapping add", "요약", positionals: ["ID"], required: 0,
                           flags: [FlagSpec("--json", "j"), FlagSpec("--id", value: "ID", "i"), FlagSpec("--telegram-chat", value: "ID", "t")])

    func testParsesFlagsValuesAndPositionals() throws {
        let p = try ArgParser.parse(["x", "--json", "--id", "family", "--telegram-chat=-100123"], spec: spec)
        XCTAssertEqual(p.positionals, ["x"])
        XCTAssertTrue(p.has("--json"))
        XCTAssertEqual(p.value("--id"), "family")
        XCTAssertEqual(p.value("--telegram-chat"), "-100123")
        XCTAssertEqual(try p.int64("--telegram-chat"), -100123)
        // 음수 값도 값으로 받는다
        XCTAssertEqual(try ArgParser.parse(["--telegram-chat", "-5"], spec: spec).value("--telegram-chat"), "-5")
        // -- 뒤는 위치 인자
        XCTAssertEqual(try ArgParser.parse(["--", "--json"], spec: spec).positionals, ["--json"])
    }

    func testUnknownFlagIsAnError() {
        XCTAssertThrowsError(try ArgParser.parse(["--jsno"], spec: spec)) { e in
            XCTAssertEqual((e as? CLIError)?.code, .usage)
            XCTAssertTrue("\(e)".contains("--jsno"))
        }
        XCTAssertThrowsError(try ArgParser.parse(["-x"], spec: spec))
    }

    func testMissingValueExtraArgsAndBadValues() {
        XCTAssertThrowsError(try ArgParser.parse(["--id"], spec: spec)) { XCTAssertEqual(($0 as? CLIError)?.code, .usage) }
        XCTAssertThrowsError(try ArgParser.parse(["--id", "--json"], spec: spec))
        XCTAssertThrowsError(try ArgParser.parse(["--json=1"], spec: spec))
        XCTAssertThrowsError(try ArgParser.parse(["a", "b"], spec: spec))
        let need = CommandSpec("mapping remove", "s", positionals: ["ID"], flags: [])
        XCTAssertThrowsError(try ArgParser.parse([], spec: need)) { XCTAssertTrue("\($0)".contains("ID")) }
        let p = try! ArgParser.parse(["--id", "x"], spec: spec)
        XCTAssertThrowsError(try p.int64("--id"))
        let lim = try! ArgParser.parse([], spec: spec)
        XCTAssertEqual(try lim.int("--wait", default: 120, range: 0...3600), 120)
    }

    func testHelpWinsOverMissingArguments() throws {
        let need = CommandSpec("mapping remove", "s", positionals: ["ID"], flags: [])
        XCTAssertTrue(try ArgParser.parse(["--help"], spec: need).wantsHelp)
        XCTAssertTrue(try ArgParser.parse(["-h"], spec: need).wantsHelp)
        // 모르는 옵션보다, 값 자리에 있어도, 남는 인자보다 도움말이 먼저다
        XCTAssertTrue(try ArgParser.parse(["--bogus", "--help"], spec: spec).wantsHelp)
        XCTAssertTrue(try ArgParser.parse(["--id", "-h"], spec: spec).wantsHelp)
        XCTAssertTrue(try ArgParser.parse(["a", "b", "c", "--help"], spec: spec).wantsHelp)
        XCTAssertNil(try ArgParser.parse(["--id", "-h"], spec: spec).value("--id"))
        // -- 뒤의 --help 는 위치 인자
        XCTAssertFalse(try ArgParser.parse(["--", "--help"], spec: spec).wantsHelp)
        XCTAssertFalse(ArgParser.wantsHelp(["--", "-h"]))
        let h = spec.help()
        XCTAssertTrue(h.hasPrefix("bluehop mapping add [ID] [옵션]"))
        XCTAssertTrue(h.contains("--telegram-chat ID"))
        XCTAssertTrue(h.contains("--help"))
        XCTAssertTrue(h.contains("종료 코드"))
    }

    func testExitCodesAndErrorJSON() throws {
        XCTAssertEqual(ExitCode.usage.rawValue, 2)
        XCTAssertEqual(ExitCode.conflict.rawValue, 3)
        XCTAssertEqual(ExitCode.notFound.rawValue, 4)
        XCTAssertEqual(ExitCode.timeout.rawValue, 5)
        XCTAssertEqual(ExitCode.cancelled.rawValue, 130)
        XCTAssertEqual(CLIError.from(ConfigError.conflict("x")).code, .conflict)
        XCTAssertEqual(CLIError.from(ConfigError.missing("x")).code, .failure)
        let obj = try JSONSerialization.jsonObject(with: Data(JSONOut.error(CLIError(.notFound, "없음")).utf8)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        let err = obj?["error"] as? [String: Any]
        XCTAssertEqual(err?["kind"] as? String, "not_found")
        XCTAssertEqual(err?["exitCode"] as? Int, 4)
        XCTAssertEqual(err?["message"] as? String, "없음")
    }

    func testMappingJSONHasNoTokenAndStableKeys() throws {
        var m = mapping("family", bot: 111)
        m.relay = RelayConfig.Relay(mirrorOwnMessages: false)
        let text = JSONOut.render(JSONOut.mapping(m))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["id", "enabled", "imessage", "telegram", "options"])
        let tg = try XCTUnwrap(obj["telegram"] as? [String: Any])
        XCTAssertEqual(Set(tg.keys), ["chatId", "allowedUserId", "botId", "botUsername", "tokenSource", "tokenAccount", "tokenFile"])
        XCTAssertEqual(tg["tokenAccount"] as? String, "bot-token:family")
        XCTAssertTrue(tg["tokenFile"] is NSNull)
        XCTAssertEqual((obj["options"] as? [String: Any])?["mirrorOwnMessages"] as? Bool, false)
        XCTAssertFalse(text.lowercased().contains("token\":\""))   // 토큰 값 자체가 들어갈 자리 없음
    }

    func testJSONRendersNilAsNull() {
        let s = JSONOut.render(["a": nil, "b": [1, 2], "c": ["d": Optional<String>.none]] as [String: Any?])
        XCTAssertEqual(s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: ""), "{\"a\":null,\"b\":[1,2],\"c\":{\"d\":null}}")
    }

    func testServiceStateParse() {
        let out = """
            gui/501/dev.kanziw.bluehop = {
                active count = 1
                state = running
                program = /x/bluehop
                pid = 4242
            }
            """
        XCTAssertEqual(ServiceState.parse(launchctlPrint: out, exitStatus: 0), ServiceState(loaded: true, running: true, pid: 4242))
        XCTAssertEqual(ServiceState.parse(launchctlPrint: "state = not running", exitStatus: 0), ServiceState(loaded: true, running: false, pid: nil))
        XCTAssertEqual(ServiceState.parse(launchctlPrint: "", exitStatus: 113), ServiceState(loaded: false, running: false, pid: nil))
    }

    func testOneShotPlistCarriesMarkerAndArgs() throws {
        let data = try LaunchdOneShot.plist(label: "dev.kanziw.bluehop.oneshot.1", binary: "/a b/bluehop", args: ["chats", "--json"], output: "/tmp/o")
        let obj = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(obj["ProgramArguments"] as? [String], ["/a b/bluehop", "chats", "--json"])
        XCTAssertEqual((obj["EnvironmentVariables"] as? [String: String])?["BLUEHOP_ONESHOT"], "1")
        XCTAssertEqual(obj["KeepAlive"] as? Bool, false)
    }

    func testKeychainCommandKeepsTokenOffArgvAndRejectsQuotes() throws {
        let cmd = try KeychainTokenStore.addCommand(token: "424242:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", account: "bot-token:family",
                                                    service: "dev.kanziw.bluehop", trusted: ["/Users/x/Library/Application Support/bluehop/bin/bluehop"])
        XCTAssertEqual(cmd, "add-generic-password -U -s \"dev.kanziw.bluehop\" -a \"bot-token:family\" -T \"/Users/x/Library/Application Support/bluehop/bin/bluehop\" -w \"424242:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"\n")
        XCTAssertThrowsError(try KeychainTokenStore.addCommand(token: "t", account: "a\"b", service: "s", trusted: []))
        XCTAssertThrowsError(try KeychainTokenStore.addCommand(token: "t", account: "a", service: "s", trusted: ["/x\ny"]))
    }
}
