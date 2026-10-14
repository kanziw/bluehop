import Foundation
import BluehopCore

let version = "0.5.0"

// MARK: - 출력

func log(_ s: String) {
    let f = ISO8601DateFormatter()
    FileHandle.standardOutput.write("\(f.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

func say(_ s: String) { print(s) }
func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// MARK: - 명령 표

let configFlag = FlagSpec("--config", value: "PATH", "설정 파일 (기본: ~/Library/Application Support/bluehop/config.json, 상태 DB 는 같은 폴더)")
let jsonFlag = FlagSpec("--json", "결과를 JSON 하나로 표준출력에 (안내·오류 설명은 표준오류)")
let mappingFlag = FlagSpec("--mapping", value: "ID", "대상 매핑 id (매핑이 하나뿐이면 생략)")

struct Command {
    var spec: CommandSpec
    var run: (Context) async throws -> ExitCode
}

struct Context {
    var args: ParsedArgs
    var raw: [String]
    var json: Bool { args.has("--json") }
    var configPath: String {
        args.value("--config").map { (($0 as NSString).expandingTildeInPath as NSString).standardizingPath } ?? Paths.configFile
    }
    var statePath: String { Paths.stateFile(forConfig: configPath) }
}

// 아래 표보다 먼저 정의해야 한다(main.swift 의 전역은 위에서부터 차례로 초기화된다).
let mappingAddSpec = CommandSpec(
    "mapping add", "iMessage 1:1 대화 하나와 새 텔레그램 봇 하나를 묶는다. 매핑마다 봇 토큰이 따로 필요하다(@BotFather /newbot).",
    flags: [
        FlagSpec("--id", value: "ID", "매핑 id (소문자로 시작, 소문자·숫자·-, 32자 이하). 없으면 봇 이름에서 만든다"),
        FlagSpec("--chat", value: "GUID|HANDLE", "iMessage 대화 guid(…;-;…) 또는 상대 handle. 없으면 터미널에서 화살표로 고른다"),
        FlagSpec("--token-stdin", "봇 토큰을 표준입력 한 줄로 받는다(에이전트용). 토큰은 명령줄 인자로 받지 않는다"),
        FlagSpec("--token-file", value: "PATH", "봇 토큰을 Keychain 대신 이 파일(0600)에서 읽고, 실행할 때도 이 파일을 쓴다"),
        FlagSpec("--telegram-chat", value: "ID", "텔레그램 방 id (--allowed-user 와 함께). 없으면 봇에게 온 메시지로 알아낸다"),
        FlagSpec("--allowed-user", value: "ID", "글을 받아 줄 텔레그램 사용자 id"),
        FlagSpec("--wait", value: "SEC", "봇에게 올 메시지를 기다릴 초 (기본 120)"),
        FlagSpec("--dry-run", "검사만 하고 Keychain·설정에 쓰지 않는다"),
        FlagSpec("--no-doctor", "추가한 뒤 점검을 건너뛴다"),
        jsonFlag, configFlag,
    ],
    details: """
        순서: 토큰(숨김 입력·--token-stdin·--token-file) → getMe 로 봇 확인 → iMessage 대화 → 텔레그램 방·사용자 → id → Keychain(dev.kanziw.bluehop / bot-token:<id>)과 설정에 저장 → 점검.
        대화형 질문은 표준입력이 터미널이고 값이 빠졌을 때만 한다. 아니면 빠진 값은 오류(종료 코드 2)다.
        텔레그램 방·사용자를 주지 않으면 봇에게 온 최근 10분 안의 개인 메시지로 알아낸다(그 글은 iMessage 로 보내지 않는다).
        같은 iMessage 대화·같은 봇은 두 매핑에 쓸 수 없다(종료 코드 3). 실행 중인 bluehop 은 약 5초 안에 새 매핑을 시작한다.
        """,
    examples: [
        "bluehop mapping add                                   # 터미널: 토큰 입력 → 대화 고르기 → 봇에게 글 보내기",
        "printf '%s\\n' \"$TOKEN\" | bluehop mapping add --token-stdin --id family --chat 'any;-;+15555550123' --json",
        "bluehop mapping add --token-stdin --chat +15555550123 --telegram-chat 123456789 --allowed-user 123456789 < token.txt",
    ])

let commands: [String: Command] = [
    "run": Command(spec: CommandSpec("run", "켜진 매핑마다 중계를 돌린다 (LaunchAgent 가 부른다). 설정 파일이 바뀌면 약 5초 안에 반영한다.",
                                     flags: [configFlag]), run: cmdRun),
    "chats": Command(spec: chatsSpec("chats"), run: cmdChats),
    "list-chats": Command(spec: chatsSpec("list-chats", alias: true), run: cmdChats),
    "mapping list": Command(spec: CommandSpec("mapping list", "설정된 매핑 목록 (토큰은 내지 않는다).", flags: [jsonFlag, configFlag],
                                              examples: ["bluehop mapping list", "bluehop mapping list --json"]), run: cmdMappingList),
    "mapping add": Command(spec: mappingAddSpec, run: cmdMappingAdd),
    "mapping remove": Command(spec: CommandSpec("mapping remove", "매핑을 지운다. 그 매핑의 Keychain 봇 토큰도 지운다(--keep-token 이면 남김).",
                                                positionals: ["ID"],
                                                flags: [FlagSpec("--keep-token", "Keychain 봇 토큰을 남긴다"),
                                                        FlagSpec("--purge-state", "상태 DB 의 그 매핑 행(커서·매핑·outbox)도 지운다"),
                                                        jsonFlag, configFlag],
                                                examples: ["bluehop mapping remove family", "bluehop mapping remove family --keep-token --json"]),
                              run: cmdMappingRemove),
    "mapping pause": Command(spec: CommandSpec("mapping pause", "매핑을 멈춘다(설정 enabled=false). 실행 중인 bluehop 이 약 5초 안에 그 일꾼을 멈춘다.",
                                               positionals: ["ID"], flags: [jsonFlag, configFlag]), run: { try cmdSetEnabled($0, false) }),
    "mapping resume": Command(spec: CommandSpec("mapping resume", "멈춘 매핑을 다시 켠다(설정 enabled=true). 안전 정지 해제는 `bluehop resume`.",
                                                positionals: ["ID"], flags: [jsonFlag, configFlag]), run: { try cmdSetEnabled($0, true) }),
    "mapping test": Command(spec: CommandSpec("mapping test", "매핑 하나를 점검한다: 토큰·chat.db 대화·텔레그램 getMe. 아무것도 보내지 않는다.",
                                              positionals: ["ID"],
                                              flags: [FlagSpec("--messages", "메시지 앱에 대화가 있는지도 본다(자동 제어 권한 필요)"), jsonFlag, configFlag]),
                            run: cmdMappingTest),
    "doctor": Command(spec: CommandSpec("doctor", "설정·권한·대화를 점검한다(보내지 않음). 매핑을 주지 않으면 모든 매핑.",
                                        flags: [mappingFlag,
                                                FlagSpec("--messages", "메시지 앱에 대화가 있는지 확인(자동 제어 권한 필요)"),
                                                FlagSpec("--telegram", "봇 토큰으로 getMe 호출"), jsonFlag, configFlag],
                                        details: "chat.db 를 열 권한이 없으면(터미널에서 실행) 설치된 bluehop 을 launchd 로 한 번 돌려 그 권한으로 점검한다.",
                                        examples: ["bluehop doctor", "bluehop doctor --mapping family --telegram --json"]),
                      run: cmdDoctor),
    "status": Command(spec: CommandSpec("status", "매핑별 상태: 마지막 텔레그램 확인 시각·마지막 오류·안전 정지, LaunchAgent 실행 여부. 상태 DB 만 읽는다.",
                                        flags: [jsonFlag, configFlag],
                                        details: "verdict: ok · paused(설정에서 멈춤) · halted(안전 정지) · error(최근 10분 오류) · stale(2분 넘게 텔레그램 확인 없음) · unknown(아직 기록 없음)"),
                      run: cmdStatus),
    "telegram-ids": Command(spec: CommandSpec("telegram-ids", "봇에게 최근 보낸 메시지의 chat id·user id (본문 없음). 실행 중인 bluehop 이 같은 봇을 쓰면 비어 보일 수 있다.",
                                              flags: [mappingFlag, FlagSpec("--token-stdin", "봇 토큰을 표준입력 한 줄로 받는다"),
                                                      FlagSpec("--token-file", value: "PATH", "봇 토큰 파일(0600)"), jsonFlag, configFlag]),
                            run: cmdTelegramIDs),
    "resume": Command(spec: CommandSpec("resume", "안전 정지를 푼다. 실행 중인 bluehop 은 다음 루프부터 반영한다.",
                                        flags: [mappingFlag, FlagSpec("--skip-backlog", "밀린 iMessage 를 건너뛴다(chat.db 권한 필요)"), configFlag]),
                      run: cmdResume),
    "selfcheck-attributed": Command(spec: CommandSpec("selfcheck-attributed", "매핑한 대화에서 본문 추출 일치율(숫자만).", flags: [mappingFlag, configFlag]),
                                    run: cmdSelfcheck),
    "diag-echo": Command(spec: CommandSpec("diag-echo", "내 메시지 행의 본문 모양(길이·정규화·다른 코드포인트)만 출력.",
                                           flags: [mappingFlag, FlagSpec("--after", value: "ROWID", "이 ROWID 뒤부터"),
                                                   FlagSpec("--expect-file", value: "PATH", "비교할 글이 든 파일"), configFlag]),
                         run: cmdDiagEcho),
    "diag-send-file": Command(spec: CommandSpec("diag-send-file", "⚠️ 실제로 보낸다. 실제 전송 경로로 매핑한 대화에만 파일(+글)을 보내고 chat.db 의 전송 상태만 출력.",
                                                flags: [mappingFlag, FlagSpec("--file", value: "PATH", "보낼 파일 (필수)"),
                                                        FlagSpec("--caption", value: "TEXT", "같이 보낼 글"),
                                                        FlagSpec("--wait", value: "SEC", "결과를 기다릴 초 (기본 40)"), configFlag]),
                              run: cmdDiagSendFile),
    "diag-audio": Command(spec: CommandSpec("diag-audio", "매핑한 대화의 오디오 첨부 행 메타(음성 메시지 플래그·mime·uti·코덱)만 출력.",
                                            flags: [mappingFlag, configFlag]), run: cmdDiagAudio),
    "version": Command(spec: CommandSpec("version", "버전을 출력한다.", flags: [jsonFlag]), run: { ctx in
        say(ctx.json ? JSONOut.render(["version": version]) : version)
        return .ok
    }),
]

func chatsSpec(_ name: String, alias: Bool = false) -> CommandSpec {
    CommandSpec(name, (alias ? "`bluehop chats` 의 옛 이름. " : "") + "이 맥의 iMessage 1:1 대화 목록(최근 순): guid·상대 handle·서비스·마지막 시각·쓰는 매핑. 메시지 본문은 읽지 않는다.",
                flags: [jsonFlag, FlagSpec("--search", value: "TEXT", "handle·guid 에 이 글이 든 대화만 (공백·-·괄호 무시)"),
                        FlagSpec("--limit", value: "N", "최대 개수 (기본 30, 최대 1000)"), configFlag],
                details: "출력에는 전화번호·이메일이 들어 있다. 로그·이슈·채팅에 붙이지 말 것.\n전체 디스크 접근 권한이 없으면(터미널에서 실행) 설치된 bluehop 을 launchd 로 한 번 돌려 그 권한으로 읽는다.",
                examples: ["bluehop chats --search 1234", "bluehop chats --json --limit 100"])
}

// MARK: - 진입

let rawArgs = Array(CommandLine.arguments.dropFirst())

func topHelp() -> String {
    let order = ["run", "chats", "mapping list", "mapping add", "mapping remove", "mapping pause", "mapping resume", "mapping test",
                 "doctor", "status", "telegram-ids", "resume", "selfcheck-attributed", "diag-echo", "diag-send-file", "diag-audio", "version"]
    var s = "bluehop \(version) — iMessage 1:1 대화 ↔ 텔레그램 봇 방 중계 (매핑마다 봇 하나)\n\n사용법: bluehop <명령> [옵션]   명령마다 --help\n\n명령:\n"
    for name in order {
        guard let c = commands[name] else { continue }
        let summary = c.spec.summary.split(separator: "\n").first.map(String.init) ?? ""
        s += "  " + name.padding(toLength: 22, withPad: " ", startingAt: 0) + summary + "\n"
    }
    s += "\n에이전트용: 모든 명령에 --help, 조회 명령에 --json, 모르는 옵션은 오류(2). 봇 토큰은 명령줄 인자로 받지 않는다(--token-stdin).\n"
    s += CLIHelp.exitCodeTable
    return s
}

func mappingHelp() -> String {
    var s = "bluehop mapping <list|add|remove|pause|resume|test> [옵션]\n\n"
    for sub in ["list", "add", "remove", "pause", "resume", "test"] {
        let c = commands["mapping " + sub]!
        s += "  " + sub.padding(toLength: 8, withPad: " ", startingAt: 0) + (c.spec.summary.split(separator: "\n").first.map(String.init) ?? "") + "\n"
    }
    return s + "\n자세히: bluehop mapping <명령> --help\n"
}

/// 명령 이름(`mapping add` 처럼 두 단어일 수 있음)과 나머지 인자.
func resolveCommand(_ args: [String]) -> (String, [String])? {
    guard let first = args.first else { return nil }
    if first == "mapping" {
        guard args.count > 1, !args[1].hasPrefix("-") else { return ("mapping", Array(args.dropFirst())) }
        return ("mapping " + args[1], Array(args.dropFirst(2)))
    }
    return (first, Array(args.dropFirst()))
}

func main() async -> Int32 {
    guard let (name, rest) = resolveCommand(rawArgs) else {
        FileHandle.standardError.write(Data(topHelp().utf8))
        return ExitCode.usage.rawValue
    }
    if name == "--help" || name == "-h" || name == "help" {
        if name == "help", let target = resolveCommand(rest), let c = commands[target.0] {
            print(c.spec.help(), terminator: "")
        } else if name == "help", rest.first == "mapping" {
            print(mappingHelp(), terminator: "")
        } else {
            print(topHelp(), terminator: "")
        }
        return 0
    }
    if name == "--version" { print(version); return 0 }
    if name == "mapping" {
        if rest.contains("--help") || rest.contains("-h") { print(mappingHelp(), terminator: ""); return 0 }
        FileHandle.standardError.write(Data(("모르는 mapping 명령: \(rest.first ?? "(없음)")\n\n" + mappingHelp()).utf8))
        return ExitCode.usage.rawValue
    }
    guard let cmd = commands[name] else {
        note("모르는 명령: \(name) (bluehop --help 참고)")
        return ExitCode.usage.rawValue
    }
    let wantsJSON = rest.contains("--json")
    do {
        let parsed = try ArgParser.parse(rest, spec: cmd.spec)
        if parsed.wantsHelp {
            print(cmd.spec.help(), terminator: "")
            return 0
        }
        return try await cmd.run(Context(args: parsed, raw: rest)).rawValue
    } catch {
        let e = CLIError.from(error)
        if wantsJSON { print(JSONOut.error(e)) }
        note("오류: \(e.message)")
        return e.code.rawValue
    }
}

exit(await main())
