import Testing
import CirclesCore
import CirclesCrypto
import CirclesSync
import NIOCore
import NIOPosix
@testable import CirclesNet

/// Holds device keys for use from @Sendable closures.
final class Device: Sendable {
    let keys = DeviceKeyPair()
}

@Suite("Noise sessions over TCP")
struct NoiseSessionTests {
    @Test("messages of any size round-trip, and each side authenticates the other")
    func echo() async throws {
        let server = Device(), client = Device()
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, device: server.keys)
        let serverTask = Task {
            try await listener.run { session in
                #expect(session.remoteStaticKey == client.keys.agreementPublicKey)
                while let message = try await session.receive() {
                    try await session.send(message.reversed())
                }
            }
        }
        defer { serverTask.cancel() }

        let large = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let replies = try await withNoiseConnection(host: "127.0.0.1", port: listener.port, device: client.keys) { session in
            #expect(session.remoteStaticKey == server.keys.agreementPublicKey)
            var replies: [[UInt8]] = []
            for message in [[1, 2, 3], [], large] as [[UInt8]] {
                try await session.send(message)
                replies.append(try #require(try await session.receive()))
            }
            return replies
        }
        #expect(replies == [[3, 2, 1], [], large.reversed()])
    }

    @Test("a handshake that stalls times out")
    func handshakeTimeout() async throws {
        // A TCP server that accepts and never says anything.
        let silent = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel) }
            }
        let port = silent.channel.localAddress!.port!
        let holder = Task {
            try await silent.executeThenClose { connections in
                for try await connection in connections {
                    // Hold the connection open without answering. (It must go
                    // through executeThenClose: NIO traps if an accepted
                    // NIOAsyncChannel is dropped unused.)
                    try await connection.executeThenClose { _, _ in
                        try await Task.sleep(for: .seconds(30))
                    }
                }
            }
        }
        defer { holder.cancel() }

        let device = Device()
        await #expect(throws: NetError.self) {
            try await withNoiseConnection(host: "127.0.0.1", port: port, device: device.keys,
                                          handshakeTimeout: .milliseconds(300)) { _ in }
        }
    }

    @Test("two nodes sync over Noise/TCP")
    func syncOverTCP() async throws {
        let alice = try Peer(), bob = try Peer()
        try await alice.meet(bob)
        try await bob.meet(alice)
        for i in 1...50 { try await alice.post("post \(i)") }

        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, device: alice.device.keys)
        let aliceEngine = alice.engine()
        let serverTask = Task {
            try await listener.run { session in
                _ = try await aliceEngine.run(over: session)
            }
        }
        defer { serverTask.cancel() }

        let bobEngine = bob.engine()
        let report = try await withNoiseConnection(host: "127.0.0.1", port: listener.port, device: bob.device.keys) { session in
            try await bobEngine.run(over: session)
        }
        #expect(report.peer == alice.user)
        #expect(report.received[alice.user] == 50, "report: \(report)")
        #expect(try await bob.store.allEntries(author: alice.user).count == 50)
    }

    @Test("messages are chunked to fit Noise's limit and reassembled exactly")
    func reassembly() throws {
        for size in [0, 1, MessageReassembler.maxChunk - 4, MessageReassembler.maxChunk - 3, 200_000] {
            let message = (0..<size).map { UInt8(truncatingIfNeeded: $0) }
            let chunks = MessageReassembler.chunks(message)
            #expect(chunks.allSatisfy { $0.count <= MessageReassembler.maxChunk })
            var reassembler = MessageReassembler()
            var output: [UInt8]?
            for (i, chunk) in chunks.enumerated() {
                output = try reassembler.add(Array(chunk))
                #expect((output == nil) == (i < chunks.count - 1))
            }
            #expect(output == message)
        }
        var reassembler = MessageReassembler()
        #expect(throws: NetError.self) { try reassembler.add([0xFF, 0xFF, 0xFF, 0xFF]) } // over the size limit
    }
}

/// A minimal node for network tests.
final class Peer: Sendable {
    let identity = IdentityKeyPair()
    let device = Device()
    let document: SignedObject
    let store = MemoryLogStore()
    let contacts = Mutex<Set<UserID>>([])

    init() throws {
        let certificate = try DeviceCertificate.issue(for: device.keys, by: identity, capabilities: .author,
                                                      issuedMillis: 0, validForMillis: 1 << 50)
        document = try IdentityDocument(user: identity.userID, version: 1, certificates: [certificate]).signed(by: identity)
    }

    var user: UserID { identity.userID }

    func meet(_ other: Peer) async throws {
        contacts.withLock { _ = $0.insert(other.user) }
        try await store.saveIdentityDocument(other.document, verified: VerifiedIdentity(verifying: other.document, for: other.user))
    }

    func post(_ text: String) async throws {
        let created = HLCTimestamp(millis: 1_000)
        let post = Post(author: user, created: created, body: RichText(plain: text))
        let item = ContentItem(kind: .post, object: try SignedObject(encoding: post, label: .post, with: device.keys))
        try await store.appendLocal(.publicContent(item), author: user, device: device.keys, created: created)
    }

    func engine() -> SyncEngine {
        let contacts = contacts.withLock { $0 }, me = user
        return SyncEngine(store: store, identityDocument: document,
                          policy: SyncPolicy(allowing: { contacts.contains($0) }, interests: { Array(contacts) + [me] }),
                          now: { 2_000 })
    }
}

import Synchronization
