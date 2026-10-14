import Foundation

public protocol Clock: AnyObject {
    var now: Double { get }
    func sleep(seconds: Double) async
}

public final class SystemClock: Clock {
    public init() {}
    public var now: Double { Date().timeIntervalSince1970 }
    public func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// 토큰 버킷. 한도를 넘으면 버리지 않고 기다린다.
public final class RateLimiter {
    let capacity: Double
    let refillPerSecond: Double
    var tokens: Double
    var last: Double
    let clock: Clock

    public init(perMinute: Int, clock: Clock) {
        self.capacity = Double(perMinute)
        self.refillPerSecond = Double(perMinute) / 60.0
        self.tokens = Double(perMinute)
        self.clock = clock
        self.last = clock.now
    }

    private func refill() {
        let now = clock.now
        tokens = min(capacity, tokens + (now - last) * refillPerSecond)
        last = now
    }

    /// 토큰 하나를 얻을 때까지 기다린다. 기다린 초를 돌려준다.
    @discardableResult
    public func acquire() async -> Double {
        refill()
        var waited = 0.0
        while tokens < 1 {
            let need = (1 - tokens) / refillPerSecond
            await clock.sleep(seconds: need)
            waited += need
            refill()
        }
        tokens -= 1
        return waited
    }
}

/// 안전 정지: 창(window) 안에서 보낸 수가 한도를 넘으면 트립한다.
public final class SafetyBreaker {
    let window: Double
    let limit: Int
    var events: [Double] = []
    let clock: Clock

    public init(limit: Int, windowSeconds: Double, clock: Clock) {
        self.limit = limit
        self.window = windowSeconds
        self.clock = clock
    }

    /// 한 건을 보내기 **전에** 부른다. false 면 보내지 말고 정지해야 한다.
    public func allow() -> Bool {
        let now = clock.now
        events.removeAll { now - $0 > window }
        guard events.count < limit else { return false }
        events.append(now)
        return true
    }

    public var recentCount: Int {
        let now = clock.now
        return events.filter { now - $0 <= window }.count
    }
}

public struct SafetyLimits {
    public var toTelegramPerMinute = 20
    public var toIMessagePerMinute = 10
    public var toTelegramPerWindow = 120
    public var toIMessagePerWindow = 40
    public var windowSeconds: Double = 600
    /// 시작(또는 재개) 시 밀린 iMessage 가 이보다 많으면 쏟지 않고 정지한다.
    public var maxBacklog = 50
    public var maxOutgoingTextLength = 4000
    public init() {}
}
