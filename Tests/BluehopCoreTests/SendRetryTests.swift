import XCTest
@testable import BluehopCore

/// 텔레그램 → iMessage 보내기 실패의 재시도 정책. 보내지 않은 것이 확실한 실패만 바로 다시 보내고(성공하면 조용히),
/// 결과를 모르는 발송은 "처음 것이 실행되지 않았다"는 근거가 모두 있을 때만 1회 다시 보낸다.
final class SendRetryTests: XCTestCase {
    func eventLog() -> (EventLog, String) {
        let path = makeTempDir().appendingPathComponent("events.jsonl").path
        return (EventLog(file: RotatingFileLog(path: path), level: .info, logBodies: false), path)
    }

    func events(_ path: String, _ name: String) -> [[String: Any]] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }.filter { $0["event"] as? String == name }
    }

    // MARK: 보내지 않음이 확실한 실패 — 즉시 재시도

    /// 대화 확인 단계에서 한 번 막혔다가 다음 시도에 보내지면, 메아리로 확인되고 경고는 없다. 재시도는 사건 로그에만 남는다.
    func testNotSentFailureIsRetriedAndSuccessIsSilent() async throws {
        let (log, path) = eventLog()
        let h = try Harness.make(events: log)
        try await h.relay.start()
        h.sender.sendFailures = [FakeSender.notSentUnresponsive]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "한 번 막혔다 보내짐")])
        await h.relay.tick()

        XCTAssertEqual(h.sender.sendAttempts, 2)
        XCTAssertEqual(h.sender.sent.count, 1)
        XCTAssertEqual(h.clock.slept, 2)  // 첫 재시도 간격
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])
        await h.relay.tick()
        XCTAssertTrue(MockTelegram.calls("sendMessage").isEmpty)  // 경고 없음

        let retries = events(path, "im_send_retry")
        XCTAssertEqual(retries.count, 1)
        XCTAssertEqual(retries.first?["attempt"] as? Int, 2)
        XCTAssertEqual(retries.first?["reason"] as? String, "messages_unresponsive")
        XCTAssertEqual(events(path, "im_send_ok").first?["attempts"] as? Int, 2)
    }

    /// 재시도까지 모두 보내기 전 단계에서 막히면 경고를 한 번만 보낸다. 몇 번 시도했는지 적고, 무응답이
    /// 이어졌으니 메시지 앱을 다시 켜 달라고 안내한다.
    func testNotSentFailuresExhaustedWarnOnceWithAttemptsAndRestartHint() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.sendFailures = Array(repeating: FakeSender.notSentUnresponsive, count: 3)
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "끝내 막힘")])
        await h.relay.tick()
        await h.relay.tick()

        XCTAssertEqual(h.sender.sendAttempts, 3)  // 처음 + 2번
        XCTAssertEqual(h.clock.slept, 7)  // 2초 + 5초
        XCTAssertTrue(h.sender.sent.isEmpty)
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.failed])
        let warns = MockTelegram.calls("sendMessage")
        XCTAssertEqual(warns.count, 1)
        let text = try XCTUnwrap(warns[0].json["text"] as? String)
        XCTAssertTrue(text.contains("보내지 못했습니다:"))
        XCTAssertFalse(text.contains("확인하지 못했습니다"))  // 보내지 않은 것이 확실하다
        XCTAssertTrue(text.contains("3번 시도"))
        XCTAssertTrue(text.contains("메시지 앱을 종료했다가 다시 켜 주세요"))
        XCTAssertEqual((warns[0].json["reply_parameters"] as? [String: Any])?["message_id"] as? Int64, 42)
    }

    /// 메시지 앱이 응답은 하지만 대화를 못 찾는 경우도 보내지 않은 것이 확실하다 — 재시도 뒤 알리되,
    /// 메시지 앱은 응답하고 있으므로 다시 켜 달라는 안내는 붙이지 않는다.
    func testNotSentWithResponsiveMessagesHasNoRestartHint() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        let missing = SendError("가짜 대화 없음", kind: .notSent, reason: "chat_not_found")
        h.sender.sendFailures = [missing, missing, missing]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "대화 없음")])
        await h.relay.tick()

        let text = try XCTUnwrap(MockTelegram.calls("sendMessage").last?.json["text"] as? String)
        XCTAssertTrue(text.contains("3번 시도"))
        XCTAssertFalse(text.contains("다시 켜 주세요"))
    }

    /// 보내기 전 단계라는 근거가 없는 또렷한 실패는 다시 보내지 않는다.
    func testOtherFailureIsNotRetried() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.sendFailures = [SendError("가짜 처리기 실패", kind: .failed, reason: "applescript_-10000")]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "모르는 오류")])
        await h.relay.tick()
        XCTAssertEqual(h.sender.sendAttempts, 1)
        XCTAssertEqual(h.clock.slept, 0)
        XCTAssertTrue((MockTelegram.calls("sendMessage").last?.json["text"] as? String)?.contains("자동으로 다시 보내지 않았습니다") == true)
    }

    // MARK: 결과를 모르는 발송 — 유예 뒤 판단

    /// 유예 안에 메아리가 오면 응답 확인도, 재전송도 하지 않는다.
    func testEchoWithinGraceNeedsNoProbeOrResend() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.sendFailures = [FakeSender.sendTimeout]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "늦게 기록됨")])
        await h.relay.tick()
        try h.fixture.insert(text: "늦게 기록됨", fromMe: true)
        h.clock.now += 5
        await h.relay.tick()
        h.clock.now += h.relay.options.sendTimeoutGrace + 1
        await h.relay.tick()

        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])
        XCTAssertEqual(h.sender.sendAttempts, 1)
        XCTAssertEqual(h.sender.existsCalls, 0)
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)
    }

    /// 유예 끝까지 메아리가 없고, 지금 메시지 앱이 응답하며, 그 사이 이 대화에 내 메시지 행이 하나도 없으면
    /// 처음 보내기는 실행되지 않은 것이다 — 1회 다시 보내고, 확인되면 경고하지 않는다.
    func testUnconfirmedSendIsResentOnceWhenMessagesAnswersAndNothingWasRecorded() async throws {
        let (log, path) = eventLog()
        let h = try Harness.make(events: log)
        try await h.relay.start()
        h.sender.sendFailures = [FakeSender.sendTimeout]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "막혔던 글")])
        await h.relay.tick()
        XCTAssertTrue(h.sender.sent.isEmpty)

        h.clock.now += h.relay.options.sendTimeoutGrace + 1
        await h.relay.tick()  // 응답 확인 → 3초 더 기다림 → 기록 없음 → 1회 다시 보냄(가짜가 메아리를 적는다)
        XCTAssertEqual(h.sender.existsCalls, 1)
        XCTAssertEqual(h.sender.sent.map(\.payload), ["막혔던 글"])
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.sent])

        await h.relay.tick()  // 메아리 맞춤
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.confirmed])
        h.clock.now += h.relay.options.confirmTimeout + 1
        await h.relay.tick()
        XCTAssertEqual(h.sender.sendAttempts, 2)  // 더 보내지 않는다
        XCTAssertTrue(MockTelegram.sentMethods.isEmpty)  // 경고 없음, 메아리를 "🙋 나:" 로 올리지도 않음
        let retry = try XCTUnwrap(events(path, "im_send_retry").first)
        XCTAssertEqual(retry["reason"] as? String, "unconfirmed_after_grace")
        XCTAssertEqual(retry["attempt"] as? Int, 2)
    }

    /// 다시 보낸 것도 확인되지 않으면 더 보내지 않고, 1번 다시 보냈다는 사실을 적어 알린다.
    func testResentButStillUnconfirmedWarnsWithoutThirdSend() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.echoInto = nil  // 메시지 앱이 아무것도 기록하지 않는다
        h.sender.sendFailures = [FakeSender.sendTimeout]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "끝내 기록 없음")])
        await h.relay.tick()
        h.clock.now += h.relay.options.sendTimeoutGrace + 1
        await h.relay.tick()
        XCTAssertEqual(h.sender.sendAttempts, 2)
        h.clock.now += h.relay.options.confirmTimeout + 1
        await h.relay.tick()

        XCTAssertEqual(h.sender.sendAttempts, 2)
        let warns = MockTelegram.calls("sendMessage")
        XCTAssertEqual(warns.count, 1)
        let text = try XCTUnwrap(warns[0].json["text"] as? String)
        XCTAssertTrue(text.contains("1번 다시 보냈지만"))
        XCTAssertTrue(text.contains("자동으로 더 보내지 않습니다"))
    }

    /// 중복 방지: 유예 동안 이 대화에 내 메시지 행이 생겼다면(본문이 달라 메아리로 못 맞춘 내 발송일 수 있음)
    /// 다시 보내지 않는다. 그 행은 평소처럼 처리되고, 발송은 "확인하지 못했다"로 알린다.
    func testOwnRowAfterSendBlocksResend() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.sendFailures = [FakeSender.sendTimeout]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "원래 글")])
        await h.relay.tick()
        try h.fixture.insert(text: "메시지 앱이 바꿔 적은 글", fromMe: true)

        h.clock.now += h.relay.options.sendTimeoutGrace + 1
        await h.relay.tick()
        h.clock.now += h.relay.options.echoGraceSeconds + 1
        await h.relay.tick()
        await h.relay.tick()

        XCTAssertEqual(h.sender.sendAttempts, 1)  // 다시 보내지 않음
        XCTAssertTrue(h.sender.sent.isEmpty)
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.failed])
        let texts = MockTelegram.calls("sendMessage").compactMap { $0.json["text"] as? String }
        XCTAssertEqual(texts.filter { $0.hasPrefix("⚠️") }.count, 1)
        XCTAssertTrue(texts.contains { $0.contains("확인하지 못했습니다") && $0.contains("자동으로 다시 보내지 않았습니다") })
    }

    /// 중복 방지: 재시작해 본문을 잃은 결과 모르는 발송은 다시 보내지 않는다(모를 때는 보내지 않는 쪽).
    func testUnconfirmedSendFromBeforeRestartIsNotResent() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.sendFailures = [FakeSender.sendTimeout]
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 42, text: "재시작 전 글")])
        await h.relay.tick()

        let h2 = try Harness.make(fixture: h.fixture, statePath: h.statePath, resetMock: false)
        h2.clock.now = h.clock.now + h2.relay.options.sendTimeoutGrace + 1
        try await h2.relay.start()
        await h2.relay.tick()

        XCTAssertEqual(h2.sender.sendAttempts, 0)
        XCTAssertEqual(h2.sender.existsCalls, 0)
        XCTAssertTrue((MockTelegram.calls("sendMessage").last?.json["text"] as? String)?.contains("자동으로 다시 보내지 않았습니다") == true)
    }

    /// 중복·순서 방지: 여러 부분 중 하나가 결과를 모르는 채로 남아 뒤 부분을 건너뛰었다면 다시 보내지 않는다.
    func testMultiPartMessageWithSkippedPartsIsNotResent() async throws {
        let h = try Harness.make()
        try await h.relay.start()
        h.sender.sendFailures = [FakeSender.sendTimeout]  // 사진(첫 부분)이 시간 제한
        MockTelegram.enqueue([["update_id": 1, "message": ["message_id": 42, "chat": ["id": Harness.chatID],
                                                           "from": ["id": Harness.userID, "is_bot": false],
                                                           "photo": [["file_id": "p1", "width": 10, "height": 10, "file_size": 3]],
                                                           "caption": "사진 설명"]]])
        await h.relay.tick()
        XCTAssertEqual(try h.state.outbox(tgMessageID: 42).map(\.status), [.ambiguousTimeout, .failed])

        h.clock.now += h.relay.options.sendTimeoutGrace + 1
        await h.relay.tick()
        XCTAssertEqual(h.sender.sendAttempts, 1)
        XCTAssertEqual(h.sender.existsCalls, 0)
        XCTAssertTrue((MockTelegram.calls("sendMessage").last?.json["text"] as? String)?.contains("여러 부분") == true)
    }
}

/// 메시지 앱 발신기의 실패 분류. 실제 osascript·메시지 앱 대신 가짜 실행기로 결과를 흉내 낸다.
final class AppleScriptSenderClassificationTests: XCTestCase {
    /// 호출마다 (모드, 결과)를 기록하고 준비한 결과를 차례로 돌려주는 가짜 실행기.
    final class Script {
        var results: [ProcessResult]
        var modes: [String] = []
        var timeouts: [TimeInterval] = []
        init(_ results: [ProcessResult]) { self.results = results }
        func run(_ args: [String], _ timeout: TimeInterval) throws -> ProcessResult {
            modes.append(args[2])
            timeouts.append(timeout)
            return results.removeFirst()
        }
    }

    static let ok = ProcessResult(status: 0, stdout: "ok\n", stderr: "")
    static let exists = ProcessResult(status: 0, stdout: "true\n", stderr: "")
    static let timeout = ProcessResult(status: -9, stdout: "", stderr: "timeout")
    static func scriptError(_ code: Int) -> ProcessResult {
        ProcessResult(status: 1, stdout: "", stderr: "execution error: Messages got an error: Can't get chat id \"iMessage;-;fake-guid\". (\(code))\n")
    }

    func sendError(_ results: [ProcessResult]) -> (SendError?, Script) {
        let script = Script(results)
        let sender = AppleScriptSender(runner: script.run)
        do {
            try sender.sendText("본문", chatGuid: "iMessage;-;fake-guid")
            return (nil, script)
        } catch {
            return (error as? SendError, script)
        }
    }

    func testSendRunsPrecheckThenSend() {
        let (err, script) = sendError([Self.exists, Self.ok])
        XCTAssertNil(err)
        XCTAssertEqual(script.modes, ["exists", "text"])
        XCTAssertEqual(script.timeouts, [AppleScriptSender.precheckTimeout, AppleScriptSender.sendTimeout])
    }

    /// 실제 사례: 메시지 앱의 Apple Event 통로가 막혀 대화 찾기에서 시간 제한. 보내기는 부르지 않으므로 보내지 않음이 확실하다.
    func testPrecheckTimeoutIsCertainlyNotSentAndSkipsSend() throws {
        let (err, script) = sendError([Self.timeout])
        let e = try XCTUnwrap(err)
        XCTAssertEqual(e.kind, .notSent)
        XCTAssertTrue(e.messagesUnresponsive)
        XCTAssertEqual(e.reason, "messages_unresponsive")
        XCTAssertEqual(script.modes, ["exists"])
    }

    func testMissingChatIsCertainlyNotSent() throws {
        let (err, script) = sendError([ProcessResult(status: 0, stdout: "false\n", stderr: "")])
        XCTAssertEqual(try XCTUnwrap(err).kind, .notSent)
        XCTAssertEqual(err?.reason, "chat_not_found")
        XCTAssertEqual(script.modes, ["exists"])
    }

    func testSendTimeoutIsUnknown() throws {
        let e = try XCTUnwrap(sendError([Self.exists, Self.timeout]).0)
        XCTAssertEqual(e.kind, .unknown)
        XCTAssertTrue(e.isAmbiguousTimeout)
        XCTAssertTrue(e.messagesUnresponsive)
    }

    func testBeforeSendErrorCodesAreCertainlyNotSent() throws {
        for code in [-1728, -1743, -1744, -1708, -1700, -2740, -2741, -2753, -600] {
            let e = try XCTUnwrap(sendError([Self.exists, Self.scriptError(code)]).0)
            XCTAssertEqual(e.kind, .notSent, "\(code)")
            XCTAssertEqual(e.reason, "applescript_\(code)")
        }
    }

    func testOtherErrorCodesAreNotAssumedUnsent() throws {
        for code in [-609, -1712, -10000] {
            XCTAssertEqual(try XCTUnwrap(sendError([Self.exists, Self.scriptError(code)]).0).kind, .failed, "\(code)")
        }
        XCTAssertEqual(try XCTUnwrap(sendError([Self.exists, ProcessResult(status: 1, stdout: "", stderr: "weird")]).0).kind, .failed)
    }

    /// osascript 의 오류 설명에는 대화 id 가 들어 있다 — 오류에는 번호만 남긴다.
    func testErrorDescriptionKeepsOnlyTheCode() throws {
        let e = try XCTUnwrap(sendError([Self.exists, Self.scriptError(-1743)]).0)
        XCTAssertFalse(e.description.contains("fake-guid"))
        XCTAssertTrue(e.description.contains("-1743"))
        XCTAssertEqual(ErrorCodes.of(e), "MESSAGES_AUTOMATION_DENIED")
        let p = try XCTUnwrap(sendError([Self.scriptError(-1743)]).0)  // 대화 확인 단계의 거부
        XCTAssertFalse(p.description.contains("fake-guid"))
        XCTAssertEqual(p.kind, .notSent)
    }

    func testErrorCodeParsing() {
        XCTAssertEqual(AppleScriptSender.appleScriptErrorCode("x: y. (-1728)\n"), -1728)
        XCTAssertNil(AppleScriptSender.appleScriptErrorCode("no code"))
        XCTAssertNil(AppleScriptSender.appleScriptErrorCode("(abc)"))
    }
}
