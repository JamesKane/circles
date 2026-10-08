import Testing
import Synchronization
import CirclesCrypto
@testable import CirclesNet

@Suite("Connection limits")
struct LimitsTests {
    @Test("caps per IP and in total, and a token bucket for new connections")
    func limiter() {
        let clock = Mutex(ContinuousClock.now)
        let limiter = ConnectionLimiter(ConnectionLimits(maxConnections: 5, maxConnectionsPerIP: 3, connectionsPerSecondPerIP: 2,
                                                         connectionBurstPerIP: 4), now: { clock.withLock { $0 } })
        // Three at once from one IP, then the per-IP cap.
        #expect((0..<3).allSatisfy { _ in limiter.admit("10.0.0.1") })
        #expect(!limiter.admit("10.0.0.1"))
        // Others still get in, up to the total.
        #expect(limiter.admit("10.0.0.2") && limiter.admit("10.0.0.3"))
        #expect(!limiter.admit("10.0.0.4"))
        #expect(limiter.active == 5)

        // Closing frees a slot, but the burst of 4 is spent after one more.
        limiter.release("10.0.0.1"); limiter.release("10.0.0.1"); limiter.release("10.0.0.1")
        #expect(limiter.admit("10.0.0.1"))
        limiter.release("10.0.0.1")
        #expect(!limiter.admit("10.0.0.1")) // no tokens left
        clock.withLock { $0 += .milliseconds(500) } // one token back at 2 per second
        #expect(limiter.admit("10.0.0.1"))
        #expect(!limiter.admit("10.0.0.1"))
    }

    @Test("a peer that goes quiet after the handshake is disconnected")
    func idleTimeout() async throws {
        let server = Device(), client = Device()
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, device: server.keys,
                                               limits: ConnectionLimits(idleTimeout: .milliseconds(400)))
        let task = Task { try await listener.run { session in _ = try await session.receive() } }
        defer { task.cancel() }
        let start = ContinuousClock.now
        let received = try await withNoiseConnection(host: "127.0.0.1", port: listener.port, device: client.keys) { session in
            try await session.receive() // the server sends nothing; the watchdog hangs up
        }
        #expect(received == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("connections over the per-IP cap are refused before the handshake")
    func refusal() async throws {
        let server = Device(), client = Device()
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, device: server.keys,
                                               limits: ConnectionLimits(maxConnectionsPerIP: 1))
        let release = Mutex(false)
        let task = Task {
            try await listener.run { session in
                while !release.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
            }
        }
        defer { task.cancel() }
        let first = Task {
            try await withNoiseConnection(host: "127.0.0.1", port: listener.port, device: client.keys) { _ in
                try await Task.sleep(for: .milliseconds(600))
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: (any Error).self) {
            try await withNoiseConnection(host: "127.0.0.1", port: listener.port, device: client.keys, handshakeTimeout: .seconds(2)) { _ in }
        }
        release.withLock { $0 = true }
        try await first.value
    }
}
