import Testing
import CirclesCore
import CirclesCrypto
@testable import CirclesSync

@Suite("Sync engine")
struct SyncEngineTests {
    func pair() async throws -> (Node, Node) {
        let alice = try Node(), bob = try Node()
        try await alice.bootstrap()
        try await bob.bootstrap()
        try await alice.meet(bob)
        try await bob.meet(alice)
        return (alice, bob)
    }

    @Test("entries flow both ways, and a repeat sync sends nothing")
    func basicSync() async throws {
        let (alice, bob) = try await pair()
        for i in 1...3 { try await alice.post("alice \(i)") }
        try await bob.post("bob 1")

        let (ra, rb) = try await sync(alice, bob)
        #expect(rb.received[alice.user] == 3)
        #expect(ra.received[bob.user] == 1)
        #expect(ra.peer == bob.user && rb.peer == alice.user)
        #expect(try await bob.postTexts(by: alice.user) == ["alice 1", "alice 2", "alice 3"])
        #expect(try await alice.postTexts(by: bob.user) == ["bob 1"])

        let (again, againB) = try await sync(alice, bob)
        #expect(again.sent == 0 && againB.sent == 0)
        #expect(again.received.isEmpty && againB.received.isEmpty)
    }

    @Test("logs are relayed: Bob gets Carol's posts through Alice")
    func relay() async throws {
        let (alice, bob) = try await pair()
        let carol = try Node()
        try await carol.bootstrap()
        try await carol.meet(alice)
        try await alice.meet(carol)
        try await carol.post("hello from carol")
        _ = try await sync(carol, alice)

        // Bob knows only Carol's user ID; Alice supplies her identity document.
        bob.follow(carol.user)
        let (_, rb) = try await sync(alice, bob)
        #expect(rb.received[carol.user] == 1)
        #expect(try await bob.postTexts(by: carol.user) == ["hello from carol"])
    }

    @Test("a peer that policy doesn't allow is refused")
    func notAllowed() async throws {
        let (alice, bob) = try await pair()
        await #expect(throws: SyncError.self) {
            _ = try await sync(alice, bob, engines: (alice.engine(), bob.engine(allowing: { _ in false })))
        }
    }

    @Test("a peer whose identity doesn't certify its connection key is refused")
    func unauthenticatedKey() async throws {
        let (alice, bob) = try await pair()
        let impostorKey = DeviceKeyPair().agreementPublicKey
        await #expect(throws: SyncError.self) {
            _ = try await sync(alice, bob, staticKeys: (impostorKey, bob.device.agreementPublicKey))
        }
    }

    @Test("forged entries served by a malicious peer are rejected and not stored")
    func forgedEntries() async throws {
        let (alice, bob) = try await pair()
        let mallory = try Node()
        try await mallory.bootstrap()
        try await mallory.meet(bob)
        try await mallory.meet(alice)
        try await bob.meet(mallory)

        // Mallory writes entries into her copy of "Alice's log", signed by her own device.
        let fakePost = Post(author: alice.user, created: HLCTimestamp(millis: now), body: RichText(plain: "forged"))
        let item = ContentItem(kind: .post, object: try SignedObject(encoding: fakePost, label: .post, with: mallory.device))
        try await mallory.store.appendLocal(.publicContent(item), author: alice.user, device: mallory.device,
                                            created: HLCTimestamp(millis: now))

        let (_, rb) = try await sync(mallory, bob)
        #expect(rb.received[alice.user] == nil)
        #expect(rb.rejected.contains { $0.contains("unknownDevice") })
        #expect(try await bob.store.allEntries(author: alice.user).isEmpty)
    }

    @Test("large logs are sent in batches")
    func batching() async throws {
        let (alice, bob) = try await pair()
        for i in 1...300 { try await alice.post("\(i)") }
        for i in 1...200 { try await bob.post("\(i)") }
        var ea = alice.engine(), eb = bob.engine()
        ea.batchSize = 64
        eb.batchSize = 64
        let (ra, rb) = try await sync(alice, bob, engines: (ea, eb))
        #expect(rb.received[alice.user] == 300)
        #expect(ra.received[bob.user] == 200)
        #expect(await bob.store.frontier(author: alice.user)[alice.device.deviceID] == 300)
    }
}

@Suite("Log entries")
struct LogEntryTests {
    @Test("entries must follow the head exactly: right sequence, right previous hash")
    func chain() async throws {
        let alice = try Node()
        let identity = try VerifiedIdentity(verifying: alice.document, for: alice.user)
        let first = try await alice.post("one")
        let second = try await alice.post("two")

        #expect(throws: Never.self) { try VerifiedLogEntry(verifying: first.signed, author: identity, after: nil) }
        let head = LogHead(sequence: 1, id: first.id)
        #expect(throws: Never.self) { try VerifiedLogEntry(verifying: second.signed, author: identity, after: head) }

        // Skipping an entry, or a head with a different hash, is rejected.
        #expect(throws: SyncError.self) { try VerifiedLogEntry(verifying: second.signed, author: identity, after: nil) }
        let wrongHead = LogHead(sequence: 1, id: ContentID(hashing: [0]))
        #expect(throws: SyncError.self) { try VerifiedLogEntry(verifying: second.signed, author: identity, after: wrongHead) }
    }

    @Test("an entry claiming another author is rejected")
    func wrongAuthor() async throws {
        let alice = try Node(), bob = try Node()
        let entry = LogEntry(author: alice.user, device: bob.device.deviceID, sequence: 1, previous: nil,
                             created: HLCTimestamp(millis: now), body: .keyGrant(SealedKeyGrant.placeholder))
        let signed = try VerifiedLogEntry(signing: entry, with: bob.device).signed
        let bobIdentity = try VerifiedIdentity(verifying: bob.document, for: bob.user)
        #expect(throws: SyncError.self) { try VerifiedLogEntry(verifying: signed, author: bobIdentity, after: nil) }
    }

    @Test("frontiers encode deterministically, sorted by device")
    func frontierEncoding() throws {
        let devices = (0..<20).map { _ in DeviceKeyPair().deviceID }
        var forward: [DeviceID: UInt64] = [:], backward: [DeviceID: UInt64] = [:]
        for (i, d) in devices.enumerated() { forward[d] = UInt64(i) }
        for (i, d) in devices.enumerated().reversed() { backward[d] = UInt64(i) }
        let a = try CBOREncoder().encode(Frontier(forward)), b = try CBOREncoder().encode(Frontier(backward))
        #expect(a == b)
        #expect(try CBORDecoder().decode(Frontier.self, from: a) == Frontier(forward))
    }
}

extension SealedKeyGrant {
    static var placeholder: SealedKeyGrant {
        try! CBORDecoder().decode(SealedKeyGrant.self, from: CBOREncoder().encode(Stub()))
    }
    private struct Stub: Codable { var encapsulatedKey: [UInt8] = [1]; var ciphertext: [UInt8] = [2] }
}

@Suite("Control messages")
struct ControlMessageTests {
    @Test("a control message shapes the receiver's wants in the same session")
    func controlBeforeWant() async throws {
        let owner = try Node(), pod = try Node(), carol = try Node()
        for node in [owner, pod, carol] { try await node.bootstrap() }
        try await owner.meet(pod)
        try await pod.meet(owner)
        try await owner.meet(carol)
        try await carol.post("carol's post")
        try await carol.meet(owner)
        _ = try await sync(carol, owner)

        // The pod only learns to want Carol's log from the owner's control message.
        let ownerUser = owner.user, carolUser = carol.user
        let instruction = try SignedObject(signing: Array("want carol".utf8), label: .podConfig, with: owner.device)
        let extra = Mutex<[UserID]>([])
        let ownerEngine = SyncEngine(
            store: owner.store, identityDocument: owner.document,
            policy: SyncPolicy(isAllowed: { _ in true }, interests: { [ownerUser, carolUser] },
                               outgoingControl: { _ in [instruction] }),
            now: { now }
        )
        let podUser = pod.user
        let podEngine = SyncEngine(
            store: pod.store, identityDocument: pod.document,
            policy: SyncPolicy(
                isAllowed: { _ in true },
                interests: { [podUser, ownerUser] + extra.withLock { $0 } },
                handleControl: { control, peer in
                    _ = try control.verifiedPayload(label: .podConfig, signer: try #require(peer.device).device.publicKey)
                    extra.withLock { $0.append(carolUser) }
                }
            ),
            now: { now }
        )
        let (_, podReport) = try await sync(owner, pod, engines: (ownerEngine, podEngine))
        #expect(podReport.rejected.isEmpty)
        #expect(podReport.received[carol.user] == 1)
        #expect(try await pod.postTexts(by: carol.user) == ["carol's post"])
    }
}

import Synchronization
