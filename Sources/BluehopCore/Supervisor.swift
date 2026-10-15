import Foundation

/// 매핑 하나의 실행 옵션. 보낼 첨부는 매핑마다 `<첨부 폴더>/<id>/` 에 둔다(텔레그램 message_id 는 봇마다 겹칠 수 있다).
public enum MappingOptions {
    public static func make(_ m: MappingConfig, tmpDir: String = Paths.tmpDir) -> Relay.Options {
        let base = m.relay?.outboxDirectory.map { ($0 as NSString).expandingTildeInPath } ?? Paths.defaultOutboxDir
        let baseURL = URL(fileURLWithPath: base, isDirectory: true)
        var o = Relay.Options(chatGuid: m.imessage.chatGuid, handle: m.imessage.handle,
                              allowedUserID: m.telegram.allowedUserId, chatID: m.telegram.chatId,
                              outboxDir: baseURL.appendingPathComponent(m.id, isDirectory: true),
                              tmpDir: URL(fileURLWithPath: tmpDir, isDirectory: true).appendingPathComponent(m.id, isDirectory: true))
        o.mirrorOwnMessages = m.mirrorOwnMessages
        o.reactionMode = m.reactionMode
        if m.id == MappingConfig.legacyID { o.legacyOutboxRoot = baseURL }
        return o
    }

    /// 실행 중인 일꾼을 다시 띄워야 하는지 판단하는 지문(설정 내용 전체).
    public static func fingerprint(_ m: MappingConfig) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(m)).map { String(decoding: $0, as: UTF8.self) } ?? m.id
    }
}

/// 설정 변화 → 멈출 일꾼·띄울 일꾼. 순수 함수(테스트 대상).
public struct ReconcilePlan: Equatable {
    public var stop: [String]
    public var start: [String]

    public static func make(running: [String: String], desired: [MappingConfig]) -> ReconcilePlan {
        let want = Dictionary(desired.filter(\.enabled).map { ($0.id, MappingOptions.fingerprint($0)) }, uniquingKeysWith: { a, _ in a })
        var stop: [String] = [], start: [String] = []
        for (id, fp) in running where want[id] != fp { stop.append(id) }
        for (id, fp) in want where running[id] != fp { start.append(id) }
        return ReconcilePlan(stop: stop.sorted(), start: start.sorted())
    }
}

/// 같은 봇 토큰을 두 매핑이 동시에 쓰지 못하게 하는 실행 중 장부(설정 검사를 피한 손 편집 대비).
public final class BotClaims {
    let lock = NSLock()
    var owners: [Int64: String] = [:]
    public init() {}

    /// 다른 매핑이 이미 이 봇을 쓰고 있으면 그 매핑 id.
    public func claim(bot: Int64, for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let o = owners[bot], o != id { return o }
        owners[bot] = id
        return nil
    }

    public func release(id: String) {
        lock.lock(); defer { lock.unlock() }
        owners = owners.filter { $0.value != id }
    }
}

/// 매핑 하나를 돌리는 일꾼. 시작에 실패하면(토큰 없음·대화 없음·같은 봇) 오류를 남기고 5초부터 두 배씩 최대 5분 쉬었다가
/// 다시 시도한다. 다른 일꾼과 아무것도 나눠 쓰지 않으므로(공용 chat.db 감시 제외) 이 일꾼의 실패가 다른 매핑을 멈추지 않는다.
public final class MappingWorker {
    public let mapping: MappingConfig
    let build: (MappingConfig) throws -> Relay
    let claims: BotClaims
    let clock: Clock
    let log: (String) -> Void
    let recordFailure: (String, Error) -> Void
    let afterStart: ((Relay) -> Void)?
    public private(set) var relay: Relay?
    public private(set) var startFailures = 0

    public init(mapping: MappingConfig, claims: BotClaims, clock: Clock,
                build: @escaping (MappingConfig) throws -> Relay,
                recordFailure: @escaping (_ id: String, _ error: Error) -> Void,
                afterStart: ((Relay) -> Void)? = nil,
                log: @escaping (String) -> Void) {
        self.afterStart = afterStart
        self.mapping = mapping
        self.build = build
        self.claims = claims
        self.clock = clock
        self.recordFailure = recordFailure
        self.log = log
    }

    static func startBackoff(failures: Int) -> Double {
        min(300, 5 * pow(2, Double(max(0, failures - 1))))
    }

    public func run() async {
        defer { claims.release(id: mapping.id) }
        while !Task.isCancelled {
            do {
                let relay = try build(mapping)
                if let bot = relay.telegram.botID, let other = claims.claim(bot: bot, for: mapping.id) {
                    throw ConfigError.conflict("봇(id \(bot))을 매핑 '\(other)' 가 이미 쓰고 있다 — 봇 하나는 매핑 하나에만")
                }
                relay.state.setHealthState("starting")
                try await relay.start()
                relay.state.setHealthState("running")
                relay.state.recordError(nil, at: clock.now)
                self.relay = relay
                startFailures = 0
                log("시작 halted=\(relay.isHalted)")
                afterStart?(relay)
                await relay.runForever()
                relay.state.setHealthState("stopped")
                return
            } catch {
                if Task.isCancelled { return }
                startFailures += 1
                let wait = Self.startBackoff(failures: startFailures)
                log("시작 실패(\(startFailures)회), \(Int(wait))초 뒤 다시: \(error)")
                recordFailure(mapping.id, error)
                await clock.sleep(seconds: wait)
            }
        }
    }
}

/// 한 프로세스에서 켜진 매핑마다 일꾼을 하나씩 띄운다. 설정 파일이 바뀌면(5초마다 확인) 일꾼을 맞춰 멈추고 띄운다.
/// 바뀐 설정이 잘못됐으면 로그만 남기고 지금 일꾼들을 그대로 둔다.
public final class Supervisor {
    public struct Source {
        /// 설정을 읽는다(검사 포함).
        public var load: () throws -> BluehopConfig
        /// 설정 파일의 변화 표시(수정 시각 등). 바뀌었을 때만 다시 읽는다.
        public var stamp: () -> String?
        public init(load: @escaping () throws -> BluehopConfig, stamp: @escaping () -> String?) {
            self.load = load
            self.stamp = stamp
        }
    }

    let source: Source
    let makeWorker: (MappingConfig) -> MappingWorker
    let clock: Clock
    let log: (String) -> Void
    public var reloadInterval: Double = 5

    var running: [String: (fingerprint: String, worker: MappingWorker, task: Task<Void, Never>)] = [:]
    var lastStamp: String?

    public init(source: Source, clock: Clock, makeWorker: @escaping (MappingConfig) -> MappingWorker, log: @escaping (String) -> Void) {
        self.source = source
        self.clock = clock
        self.makeWorker = makeWorker
        self.log = log
    }

    public var runningIDs: [String] { running.keys.sorted() }
    public func worker(_ id: String) -> MappingWorker? { running[id]?.worker }

    /// 설정을 읽어 일꾼을 맞춘다. 처음 부를 때 설정을 못 읽으면 오류를 던진다(실행 시작 실패).
    public func reconcile(initial: Bool = false) async throws {
        let stamp = source.stamp()
        if !initial, stamp == lastStamp { return }
        let cfg: BluehopConfig
        do {
            cfg = try source.load()
        } catch {
            if initial { throw error }
            log("설정을 다시 읽지 못해 지금 매핑을 그대로 둠: \(error)")
            lastStamp = stamp
            return
        }
        lastStamp = stamp
        await apply(cfg)
    }

    public func apply(_ cfg: BluehopConfig) async {
        let plan = ReconcilePlan.make(running: running.mapValues(\.fingerprint), desired: cfg.mappings)
        for id in plan.stop { await stop(id) }
        for id in plan.start {
            guard let m = cfg.mapping(id) else { continue }
            let w = makeWorker(m)
            let task = Task { await w.run() }
            running[id] = (MappingOptions.fingerprint(m), w, task)
            log("[\(id)] 일꾼 띄움")
        }
        if cfg.enabledMappings.isEmpty { log("켜진 매핑이 없음 — 설정이 바뀌기를 기다림") }
    }

    /// 일꾼을 멈추고 끝날 때까지 기다린다(같은 봇으로 두 일꾼이 겹쳐 돌지 않게).
    public func stop(_ id: String) async {
        guard let r = running.removeValue(forKey: id) else { return }
        r.task.cancel()
        await r.task.value
        log("[\(id)] 일꾼 멈춤")
    }

    public func stopAll() async {
        for id in runningIDs { await stop(id) }
    }

    public func runForever() async throws {
        try await reconcile(initial: true)
        while !Task.isCancelled {
            await clock.sleep(seconds: reloadInterval)
            try? await reconcile()
        }
        await stopAll()
    }
}
