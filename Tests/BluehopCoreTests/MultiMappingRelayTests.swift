import Foundation
import XCTest
@testable import BluehopCore

let tokenA = "111111:AAAATESTTOKENAAAATESTTOKEN"
let tokenB = "222222:BBBBTESTTOKENBBBBTESTTOKEN"
let guidB = "any;-;+821033334444"
let handleB = "+821033334444"

/// 여러 매핑이 한 프로세스·한 상태 DB·한 chat.db 를 함께 쓸 때 서로 섞이거나 멈추지 않는지.
final class MultiMappingRelayTests: XCTestCase {
    /// 매핑 두 개(대화 1 ↔ 봇 A, 대화 2 ↔ 봇 B), 같은 fixture·같은 상태 파일.
    func makePair(activity: ChatActivity? = nil) throws -> (Harness, Harness) {
        let a = try Harness.make(mappingID: "a", token: tokenA, activity: activity)
        let b = try Harness.make(fixture: a.fixture, statePath: a.statePath, mappingID: "b", token: tokenB,
                                 chatGuid: guidB, handle: handleB, activity: activity, resetMock: false)
        return (a, b)
    }

    func waitUntil(_ seconds: Double = 5, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cond()
    }

    func testEchoMatchingIsPerMapping() async throws {
        let (a, b) = try makePair()
        try await a.relay.start()
        try await b.relay.start()
        // 두 봇은 서로 다른 방이라 같은 message_id·같은 글이 동시에 올 수 있다
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 10, text: "같은 글")], token: tokenA)
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 10, text: "같은 글")], token: tokenB)
        await a.relay.tick()
        await b.relay.tick()
        XCTAssertEqual(a.sender.sent.map(\.chat), [FixtureChatDB.chatGuid])
        XCTAssertEqual(b.sender.sent.map(\.chat), [guidB])
        await a.relay.tick()
        await b.relay.tick()
        for h in [a, b] {
            XCTAssertEqual(try h.state.outbox(tgMessageID: 10).map(\.status), [.confirmed])
        }
        // 메아리를 "🙋 나:" 로 다시 올리지도, 거짓 ⚠️ 를 달지도 않는다
        a.clock.now += 120
        b.clock.now += 120
        await a.relay.tick()
        await b.relay.tick()
        XCTAssertTrue(MockTelegram.calls("sendMessage", token: tokenA).isEmpty)
        XCTAssertTrue(MockTelegram.calls("sendMessage", token: tokenB).isEmpty)
    }

    func testIMessageGoesOnlyToItsOwnBot() async throws {
        let (a, b) = try makePair()
        try await a.relay.start()
        try await b.relay.start()
        try a.fixture.insert(chat: 2, text: "B 대화의 글")
        await a.relay.tick()
        await b.relay.tick()
        XCTAssertTrue(MockTelegram.calls("sendMessage", token: tokenA).isEmpty)
        XCTAssertEqual(MockTelegram.calls("sendMessage", token: tokenB).map { $0.json["text"] as? String }, ["B 대화의 글"])
    }

    func testHaltIsPerMapping() async throws {
        let (a, b) = try makePair()
        try await a.relay.start()
        try await b.relay.start()
        MockTelegram.enqueue([Harness.textUpdate(1, messageID: 1, text: "/pause")], token: tokenA)
        await a.relay.tick()
        XCTAssertTrue(a.relay.isHalted)
        XCTAssertFalse(b.relay.isHalted)
        try a.fixture.insert(chat: 2, text: "B 는 계속")
        await b.relay.tick()
        XCTAssertEqual(MockTelegram.calls("sendMessage", token: tokenB).count, 1)
    }

    func testTelegramFailureBacksOffOnlyThatWorkerAndIsRecorded() async throws {
        let (a, b) = try makePair()
        try await a.relay.start()
        try await b.relay.start()
        MockTelegram.failuresByToken[tokenA] = ["getUpdates": ["ok": false, "error_code": 401, "description": "Unauthorized"]]
        let before = a.clock.slept
        await a.relay.tick()
        await a.relay.tick()
        await a.relay.tick()
        XCTAssertEqual(a.clock.slept - before, 3 + 6 + 12)  // 3초부터 두 배
        XCTAssertTrue(a.state.health().lastError?.contains("401") == true)
        XCTAssertTrue(a.state.health().lastError?.contains("토큰이 거부됨") == true)
        let bSlept = b.clock.slept
        await b.relay.tick()
        XCTAssertEqual(b.clock.slept, bSlept)
        XCTAssertNil(b.state.health().lastError)
        // 회복하면 오류를 지운다
        MockTelegram.failuresByToken = [:]
        await a.relay.tick()
        XCTAssertNil(a.state.health().lastError)
        XCTAssertNotNil(a.state.health().lastTelegramOK)
    }

    func testBaselineFailureBacksOffInsteadOfSpinning() async throws {
        let h = try Harness.make(token: tokenA)
        MockTelegram.failuresByToken[tokenA] = ["getUpdates": ["ok": false, "error_code": 409, "description": "Conflict"]]
        try await h.relay.start()   // 시작은 막히지 않는다
        XCTAssertFalse(h.state.hasTGBaseline)
        let before = h.clock.slept
        await h.relay.tick()
        XCTAssertGreaterThan(h.clock.slept - before, 0)
        XCTAssertTrue(h.state.health().lastError?.contains("409") == true)
    }

    func testSharedActivitySkipsRowQueriesWhenNothingIsNew() async throws {
        let fx = try FixtureChatDB()
        let activity = ChatActivity(chatDB: try fx.reader(), minInterval: 0)
        let h = try Harness.make(fixture: fx, activity: activity)
        try await h.relay.start()
        for _ in 0..<3 { await h.relay.tick() }
        XCTAssertEqual(h.relay.chatDB.messageQueryCount, 0)
        try fx.insert(chat: 2, text: "다른 대화")   // 다른 대화의 새 글은 이 매핑의 행 조회를 부르지 않는다
        await h.relay.tick()
        XCTAssertEqual(h.relay.chatDB.messageQueryCount, 0)
        try fx.insert(text: "새 글")
        await h.relay.tick()
        XCTAssertEqual(h.relay.chatDB.messageQueryCount, 1)
        XCTAssertEqual(MockTelegram.calls("sendMessage").count, 1)
        await h.relay.tick()
        XCTAssertEqual(h.relay.chatDB.messageQueryCount, 1)
    }

    func testOneGroupedQueryServesAllMappings() async throws {
        let fx = try FixtureChatDB()
        let activity = ChatActivity(chatDB: try fx.reader(), minInterval: 100, now: { 1000 })
        activity.watch(1)
        activity.watch(2)
        try fx.insert(chat: 1, text: "x")
        try fx.insert(chat: 2, text: "y")
        XCTAssertEqual(activity.latestRowID(chat: 1), 1)
        XCTAssertEqual(activity.latestRowID(chat: 2), 2)
        XCTAssertEqual(activity.refreshCount, 1)
        XCTAssertNil(activity.latestRowID(chat: 3))  // 감시하지 않는 대화는 모른다(직접 조회로)
    }

    // MARK: 일꾼·감독

    func makeSupervisor(_ harnesses: [String: Harness], mappings: [MappingConfig], failures: LogBox) -> Supervisor {
        let claims = BotClaims()
        let box = ConfigBox(BluehopConfig(mappings: mappings))
        return Supervisor(source: Supervisor.Source(load: { box.value }, stamp: { box.stamp }), clock: FakeClock(), makeWorker: { m in
            let h = harnesses[m.id]!
            return MappingWorker(mapping: m, claims: claims, clock: h.clock, build: { m in
                guard let h = harnesses[m.id] else { throw ConfigError.invalid("없음") }
                return h.relay
            }, recordFailure: { id, msg in failures.append("\(id): \(msg)") }, log: { _ in })
        }, log: { _ in })
    }

    /// 테스트가 중간에 실패해도 일꾼이 남아 다음 테스트의 목 텔레그램을 건드리지 않게 한다.
    func stopAtEnd(_ sup: Supervisor) {
        addTeardownBlock { await sup.stopAll() }
    }

    func testFailingWorkerDoesNotStopAnother() async throws {
        let (a, b) = try makePair()
        MockTelegram.failuresByToken[tokenA] = ["getUpdates": ["ok": false, "error_code": 401, "description": "Unauthorized"]]
        let failures = LogBox()
        let sup = makeSupervisor(["a": a, "b": b],
                                 mappings: [mapping("a", bot: 111111), mapping("b", guid: guidB, handle: handleB, bot: 222222)],
                                 failures: failures)
        stopAtEnd(sup)
        try await sup.reconcile(initial: true)
        XCTAssertEqual(sup.runningIDs, ["a", "b"])
        // 일꾼이 도는 동안 상태는 따로 연 연결로 본다(연결 하나를 두 스레드가 나눠 쓰지 않는다)
        let seeA = try StateStore(path: a.statePath, mappingID: "a")
        let seeB = try StateStore(path: b.statePath, mappingID: "b")
        let ok1 = await waitUntil { seeB.hasTGBaseline }
        XCTAssertTrue(ok1)
        try a.fixture.insert(chat: 2, text: "B 로 가야 할 글")
        let delivered = await waitUntil { MockTelegram.calls("sendMessage", token: tokenB).count == 1 }
        XCTAssertTrue(delivered)
        let ok9 = await waitUntil { seeA.health().lastError?.contains("401") == true }
        XCTAssertTrue(ok9)
        XCTAssertEqual(seeB.health().state, "running")
        await sup.stopAll()
        XCTAssertEqual(sup.runningIDs, [])
    }

    func testWorkerThatCannotStartRetriesWhileOthersRun() async throws {
        let a = try Harness.make(mappingID: "a", token: tokenA, chatGuid: "any;-;+15555550123", handle: "+15555550123")
        let b = try Harness.make(fixture: a.fixture, statePath: a.statePath, mappingID: "b", token: tokenB,
                                 chatGuid: guidB, handle: handleB, resetMock: false)
        let failures = LogBox()
        let sup = makeSupervisor(["a": a, "b": b],
                                 mappings: [mapping("a", guid: "any;-;+15555550123", handle: "+15555550123"),
                                            mapping("b", guid: guidB, handle: handleB)],
                                 failures: failures)
        stopAtEnd(sup)
        try await sup.reconcile(initial: true)
        let ok2 = await waitUntil { failures.lines.count >= 2 }
        XCTAssertTrue(ok2)   // 물러섰다가 다시 시도
        XCTAssertTrue(failures.lines.allSatisfy { $0.hasPrefix("a: ") && $0.contains("찾지 못했다") })
        try a.fixture.insert(chat: 2, text: "B 는 돈다")
        let ok3 = await waitUntil { MockTelegram.calls("sendMessage", token: tokenB).count == 1 }
        XCTAssertTrue(ok3)
        await sup.stopAll()
    }

    func testSameBotInTwoMappingsRunsOnlyOnce() async throws {
        // 손으로 고친 설정(botId 없음, 다른 Keychain 계정)이라 설정 검사를 지나도 실행 중에 막는다
        let a = try Harness.make(mappingID: "a", token: tokenA)
        let b = try Harness.make(fixture: a.fixture, statePath: a.statePath, mappingID: "b", token: tokenA,
                                 chatGuid: guidB, handle: handleB, resetMock: false)
        let failures = LogBox()
        let sup = makeSupervisor(["a": a, "b": b],
                                 mappings: [mapping("a"), mapping("b", guid: guidB, handle: handleB)], failures: failures)
        stopAtEnd(sup)
        try await sup.reconcile(initial: true)
        let ok4 = await waitUntil { !failures.lines.isEmpty }
        XCTAssertTrue(ok4)
        XCTAssertTrue(failures.lines[0].contains("이미 쓰고 있다"))
        await sup.stopAll()
    }
}

final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cfg: BluehopConfig
    private var n = 0
    init(_ c: BluehopConfig) { cfg = c }
    var value: BluehopConfig { lock.lock(); defer { lock.unlock() }; return cfg }
    var stamp: String { lock.lock(); defer { lock.unlock() }; return String(n) }
    func set(_ c: BluehopConfig) { lock.lock(); cfg = c; n += 1; lock.unlock() }
}

/// 설정 변화 → 일꾼 맞추기.
final class SupervisorTests: XCTestCase {
    func testReconcilePlan() {
        let a = mapping("a"), b = mapping("b", guid: guidB, handle: handleB)
        let fp = { (m: MappingConfig) in MappingOptions.fingerprint(m) }
        XCTAssertEqual(ReconcilePlan.make(running: [:], desired: [a, b]), ReconcilePlan(stop: [], start: ["a", "b"]))
        XCTAssertEqual(ReconcilePlan.make(running: ["a": fp(a), "b": fp(b)], desired: [a, b]), ReconcilePlan(stop: [], start: []))
        XCTAssertEqual(ReconcilePlan.make(running: ["a": fp(a), "b": fp(b)], desired: [a]), ReconcilePlan(stop: ["b"], start: []))
        var paused = b
        paused.enabled = false
        XCTAssertEqual(ReconcilePlan.make(running: ["a": fp(a), "b": fp(b)], desired: [a, paused]), ReconcilePlan(stop: ["b"], start: []))
        var changed = a
        changed.telegram.allowedUserId = 999
        XCTAssertEqual(ReconcilePlan.make(running: ["a": fp(a)], desired: [changed]), ReconcilePlan(stop: ["a"], start: ["a"]))
    }

    func testReloadStartsStopsAndKeepsWorkersOnBadConfig() async throws {
        let a = try Harness.make(mappingID: "a", token: tokenA)
        let b = try Harness.make(fixture: a.fixture, statePath: a.statePath, mappingID: "b", token: tokenB,
                                 chatGuid: guidB, handle: handleB, resetMock: false)
        let ma = mapping("a"), mb = mapping("b", guid: guidB, handle: handleB)
        let box = ConfigBox(BluehopConfig(mappings: [ma]))
        let claims = BotClaims()
        let harnesses = ["a": a, "b": b]
        var broken = false
        let sup = Supervisor(source: Supervisor.Source(load: {
            if broken { throw ConfigError.invalid("깨진 설정") }
            return box.value
        }, stamp: { box.stamp }), clock: FakeClock(), makeWorker: { m in
            MappingWorker(mapping: m, claims: claims, clock: harnesses[m.id]!.clock, build: { m in harnesses[m.id]!.relay },
                          recordFailure: { _, _ in }, log: { _ in })
        }, log: { _ in })
        addTeardownBlock { await sup.stopAll() }
        try await sup.reconcile(initial: true)
        XCTAssertEqual(sup.runningIDs, ["a"])

        box.set(BluehopConfig(mappings: [ma, mb]))
        try await sup.reconcile()
        XCTAssertEqual(sup.runningIDs, ["a", "b"])

        var pausedB = mb
        pausedB.enabled = false
        box.set(BluehopConfig(mappings: [ma, pausedB]))
        try await sup.reconcile()
        XCTAssertEqual(sup.runningIDs, ["a"])

        broken = true
        box.set(BluehopConfig(mappings: []))
        try await sup.reconcile()   // 다시 못 읽으면 지금 일꾼을 그대로 둔다
        XCTAssertEqual(sup.runningIDs, ["a"])

        broken = false
        box.set(BluehopConfig(mappings: []))
        try await sup.reconcile()
        XCTAssertEqual(sup.runningIDs, [])
    }

    func testInitialConfigErrorFailsStart() async {
        let sup = Supervisor(source: Supervisor.Source(load: { throw ConfigError.missing("x") }, stamp: { nil }),
                             clock: FakeClock(), makeWorker: { _ in fatalError() }, log: { _ in })
        do {
            try await sup.reconcile(initial: true)
            XCTFail("던져야 함")
        } catch {}
    }

    func testBotClaims() {
        let c = BotClaims()
        XCTAssertNil(c.claim(bot: 1, for: "a"))
        XCTAssertNil(c.claim(bot: 1, for: "a"))
        XCTAssertEqual(c.claim(bot: 1, for: "b"), "a")
        c.release(id: "a")
        XCTAssertNil(c.claim(bot: 1, for: "b"))
    }

    func testBackoffSchedules() {
        XCTAssertEqual(MappingWorker.startBackoff(failures: 1), 5)
        XCTAssertEqual(MappingWorker.startBackoff(failures: 2), 10)
        XCTAssertEqual(MappingWorker.startBackoff(failures: 20), 300)
        XCTAssertEqual(Relay.telegramBackoff(failures: 1), 3)
        XCTAssertEqual(Relay.telegramBackoff(failures: 3), 12)
        XCTAssertEqual(Relay.telegramBackoff(failures: 10), 60)
    }
}
