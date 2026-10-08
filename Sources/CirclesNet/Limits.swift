import Synchronization

/// What a listener accepts (docs/DESIGN.md §7.5, §12): a cap on concurrent
/// connections in total and per remote IP, and a per-IP rate of new
/// connections (a token bucket). Connections over a limit are closed before
/// the handshake, so they cost almost nothing.
public struct ConnectionLimits: Sendable {
    public var maxConnections: Int
    public var maxConnectionsPerIP: Int
    /// New connections per second per IP, sustained…
    public var connectionsPerSecondPerIP: Double
    /// …and in a burst.
    public var connectionBurstPerIP: Double
    /// A session with no traffic either way for this long is closed.
    public var idleTimeout: Duration

    public init(maxConnections: Int = 512, maxConnectionsPerIP: Int = 32, connectionsPerSecondPerIP: Double = 10,
                connectionBurstPerIP: Double = 40, idleTimeout: Duration = .seconds(120)) {
        self.maxConnections = maxConnections
        self.maxConnectionsPerIP = maxConnectionsPerIP
        self.connectionsPerSecondPerIP = connectionsPerSecondPerIP
        self.connectionBurstPerIP = connectionBurstPerIP
        self.idleTimeout = idleTimeout
    }

    public static let `default` = ConnectionLimits()
}

/// Admits or refuses connections under `ConnectionLimits`.
final class ConnectionLimiter: Sendable {
    private struct State {
        var total = 0
        var perIP: [String: Int] = [:]
        var buckets: [String: (tokens: Double, updated: ContinuousClock.Instant)] = [:]
    }

    let limits: ConnectionLimits
    private let state = Mutex(State())
    private let now: @Sendable () -> ContinuousClock.Instant

    init(_ limits: ConnectionLimits, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.limits = limits
        self.now = now
    }

    /// Whether to accept a connection from `ip`; if so, the caller must
    /// `release` it when it ends.
    func admit(_ ip: String) -> Bool {
        let time = now()
        return state.withLock { state in
            guard state.total < limits.maxConnections, state.perIP[ip, default: 0] < limits.maxConnectionsPerIP else { return false }
            var bucket = state.buckets[ip] ?? (limits.connectionBurstPerIP, time)
            let elapsed = Double((time - bucket.updated).components.seconds) + Double((time - bucket.updated).components.attoseconds) / 1e18
            bucket.tokens = min(limits.connectionBurstPerIP, bucket.tokens + elapsed * limits.connectionsPerSecondPerIP)
            bucket.updated = time
            guard bucket.tokens >= 1 else {
                state.buckets[ip] = bucket
                return false
            }
            bucket.tokens -= 1
            state.buckets[ip] = bucket
            state.total += 1
            state.perIP[ip, default: 0] += 1
            // Forget full buckets of idle IPs now and then, so the table
            // can't grow without bound.
            if state.buckets.count > 4 * limits.maxConnections {
                state.buckets = state.buckets.filter { $0.value.tokens < limits.connectionBurstPerIP || state.perIP[$0.key] != nil }
            }
            return true
        }
    }

    func release(_ ip: String) {
        state.withLock { state in
            state.total -= 1
            state.perIP[ip, default: 1] -= 1
            if state.perIP[ip] == 0 { state.perIP[ip] = nil }
        }
    }

    var active: Int { state.withLock { $0.total } }
}

/// When a session last sent or received anything.
final class Activity: Sendable {
    private let last = Mutex(ContinuousClock.now)

    func touch() { last.withLock { $0 = .now } }
    var idle: Duration { ContinuousClock.now - last.withLock { $0 } }
}
