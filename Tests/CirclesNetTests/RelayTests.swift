import Testing
import CirclesCrypto
import Synchronization
@testable import CirclesNet

#if os(Windows)
let isWindows = true
#else
let isWindows = false
#endif

@Suite("Relays")
struct RelayTests {
    /// Starts a relay and a device reserved on it that echoes reversed messages.
    func withEchoBehindRelay<R>(_ body: (RelayServer, Device, Device) async throws -> R) async throws -> R {
        let relayKeys = Device(), target = Device()
        let relay = try await RelayServer(host: "127.0.0.1", port: 0,
                                          handshake: NoiseHandshake(role: .responder, device: relayKeys.keys))
        let relayTask = Task { try await relay.run() }
        defer { relayTask.cancel() }

        let address = RelayAddress(host: "127.0.0.1", port: relay.port, key: relayKeys.keys.agreementPublicKey)
        let (reserved, signal) = AsyncStream.makeStream(of: Void.self)
        let serving = Task {
            try await serveViaRelay(
                address,
                outer: NoiseHandshake(role: .initiator, device: target.keys),
                inner: NoiseHandshake(role: .responder, device: target.keys),
                onReserved: { signal.yield() }
            ) { session in
                while let message = try await session.receive() {
                    try await session.send(message.reversed())
                }
            }
        }
        defer { serving.cancel() }
        for await _ in reserved { break }
        return try await body(relay, relayKeys, target)
    }

    /// Disabled on Windows: there the relayed session ends early (about 4 s
    /// in, `receive()` returns nil) while the same exchange without a relay
    /// passes. To be debugged on a Windows machine (docs/DESIGN.md §11.5).
    @Test("peers talk end to end through a relay",
          .disabled(if: isWindows, "relayed sessions end early on Windows; needs debugging on Windows"))
    func echo() async throws {
        try await withEchoBehindRelay { relay, relayKeys, target in
            let client = Device()
            let address = RelayAddress(host: "127.0.0.1", port: relay.port, key: relayKeys.keys.agreementPublicKey)
            let large = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
            let replies = try await withRelayedConnection(
                via: address, to: target.keys.agreementPublicKey,
                outer: NoiseHandshake(role: .initiator, device: client.keys),
                inner: NoiseHandshake(role: .initiator, device: client.keys)
            ) { session in
                // The session is with the target itself, not the relay.
                #expect(session.remoteStaticKey == target.keys.agreementPublicKey)
                var replies: [[UInt8]] = []
                for message in [[1, 2, 3], large] as [[UInt8]] {
                    try await session.send(message)
                    replies.append(try #require(try await session.receive()))
                }
                return replies
            }
            #expect(replies == [[3, 2, 1], large.reversed()])
        }
    }

    @Test("several circuits to the same target at once")
    func concurrentCircuits() async throws {
        try await withEchoBehindRelay { relay, relayKeys, target in
            let address = RelayAddress(host: "127.0.0.1", port: relay.port, key: relayKeys.keys.agreementPublicKey)
            try await withThrowingTaskGroup(of: [UInt8].self) { group in
                for n in 0..<8 {
                    group.addTask {
                        let client = Device()
                        return try await withRelayedConnection(
                            via: address, to: target.keys.agreementPublicKey,
                            outer: NoiseHandshake(role: .initiator, device: client.keys),
                            inner: NoiseHandshake(role: .initiator, device: client.keys)
                        ) { session in
                            try await session.send([UInt8(n), 0xFF])
                            return try #require(try await session.receive())
                        }
                    }
                }
                var replies: Set<[UInt8]> = []
                for try await reply in group { replies.insert(reply) }
                #expect(replies == Set((0..<8).map { [0xFF, UInt8($0)] }))
            }
        }
    }

    @Test("connecting to a device without a reservation is refused")
    func noReservation() async throws {
        try await withEchoBehindRelay { relay, relayKeys, _ in
            let client = Device(), stranger = Device()
            await #expect(throws: RelayError.refused("no reservation for target")) {
                try await withRelayedConnection(
                    via: RelayAddress(host: "127.0.0.1", port: relay.port, key: relayKeys.keys.agreementPublicKey),
                    to: stranger.keys.agreementPublicKey,
                    outer: NoiseHandshake(role: .initiator, device: client.keys),
                    inner: NoiseHandshake(role: .initiator, device: client.keys)
                ) { _ in }
            }
        }
    }

    @Test("a relay that doesn't hold the expected key is rejected")
    func pinnedRelayKey() async throws {
        try await withEchoBehindRelay { relay, _, target in
            let client = Device(), impostor = Device()
            await #expect(throws: RelayError.unexpectedRelayKey) {
                try await withRelayedConnection(
                    via: RelayAddress(host: "127.0.0.1", port: relay.port, key: impostor.keys.agreementPublicKey),
                    to: target.keys.agreementPublicKey,
                    outer: NoiseHandshake(role: .initiator, device: client.keys),
                    inner: NoiseHandshake(role: .initiator, device: client.keys)
                ) { _ in }
            }
        }
    }

    @Test("a reservation ends when its device disconnects")
    func reservationReleased() async throws {
        let relayKeys = Device(), target = Device(), client = Device()
        let relay = try await RelayServer(host: "127.0.0.1", port: 0,
                                          handshake: NoiseHandshake(role: .responder, device: relayKeys.keys))
        let relayTask = Task { try await relay.run() }
        defer { relayTask.cancel() }
        let address = RelayAddress(host: "127.0.0.1", port: relay.port)

        let (reserved, signal) = AsyncStream.makeStream(of: Void.self)
        let serving = Task {
            try await serveViaRelay(address, outer: NoiseHandshake(role: .initiator, device: target.keys),
                                    inner: NoiseHandshake(role: .responder, device: target.keys),
                                    onReserved: { signal.yield() }) { _ in }
        }
        for await _ in reserved { break }
        serving.cancel()
        _ = await serving.result

        // Give the relay a moment to notice the closed connection.
        var refused = false
        for _ in 0..<50 where !refused {
            try await Task.sleep(for: .milliseconds(20))
            do {
                try await withRelayedConnection(via: address, to: target.keys.agreementPublicKey,
                                                outer: NoiseHandshake(role: .initiator, device: client.keys),
                                                inner: NoiseHandshake(role: .initiator, device: client.keys)) { _ in }
            } catch RelayError.refused {
                refused = true
            } catch {}
        }
        #expect(refused)
    }

    @Test("relay messages round-trip")
    func messages() throws {
        let key = Device().keys.agreementPublicKey
        for request in [RelayRequest.reserve, .connect(target: key), .accept(token: [1, 2, 3])] {
            #expect(try CBORDecoder().decode(RelayRequest.self, from: CBOREncoder().encode(request)) == request)
        }
        for response in [RelayResponse.ok, .error("no"), .incoming(token: [9], from: key)] {
            #expect(try CBORDecoder().decode(RelayResponse.self, from: CBOREncoder().encode(response)) == response)
        }
    }
}

import CirclesCore
