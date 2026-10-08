import Testing
import Foundation
import CirclesCore
import CirclesCrypto
import CirclesSync
import CirclesNet
@testable import CirclesKit

/// Runs a pod's listener for the duration of `body`.
func servingPod<R>(_ pod: PodNode, port: Int = 0, _ body: (Int) async throws -> R) async throws -> R {
    let listener = try await NoiseListener(host: "127.0.0.1", port: port, handshake: await pod.makeHandshake(role: .responder))
    let task = Task {
        try await listener.run { session in _ = try await pod.respond(over: session) }
    }
    defer { task.cancel() }
    return try await body(listener.port)
}

func texts(_ account: Account) async throws -> [String] {
    try await account.stream().map(\.body.plainText)
}

@Suite("Pods and relays end to end")
struct PodAndRelayTests {
    @Test("a pod stores and forwards while its owner is offline")
    func storeAndForward() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let (pod, _) = try await PodNode.create(home: temporaryHome(), host: "127.0.0.1", port: 0)

        // The pod's port is only known once it listens; then Alice pairs it.
        let probe = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await pod.makeHandshake(role: .responder))
        let podPort = probe.port
        try await pod.setAddress(host: "127.0.0.1", port: UInt16(podPort))
        let bundle = try await alice.addPod(await pod.pairingCode)
        #expect(try await pod.pair(bundle) == alice.user)
        #expect(await alice.endpoints.pods.count == 1)

        // Contacts exchange invites after the pod exists, so Bob learns of it.
        try await alice.addContact(invite: await bob.invite())
        try await bob.addContact(invite: await alice.invite())
        try await alice.createCircle("Friends")
        try await alice.addToCircle("Friends", members: [bob.user])
        try await alice.post(RichText(plain: "for friends, via my pod"), to: .circles(["Friends"]))

        let probeTask = Task { try await probe.run { session in _ = try await pod.syncEngine().run(over: session) } }
        defer { probeTask.cancel() }

        // Alice syncs with her pod (and configures it), then goes offline.
        let aliceAttempts = await alice.syncAll(discoveryTimeout: .milliseconds(200))
        #expect(aliceAttempts.contains { $0.route.hasPrefix("my pod") && (try? $0.result.get()) != nil })
        #expect(await pod.config?.contacts == [bob.user])

        // Bob reaches only the pod, and can read the circle post.
        let bobAttempts = await bob.syncAll(discoveryTimeout: .milliseconds(200))
        #expect(bobAttempts.contains { $0.route.hasPrefix("Alice's pod") && (try? $0.result.get()) != nil })
        #expect(try await texts(bob) == ["for friends, via my pod"])

        // Bob replies; the pod keeps it; Alice picks it up later from the pod.
        try await bob.post(RichText(plain: "hi Alice, from Bob"), to: .everyone)
        _ = await bob.syncAll(discoveryTimeout: .milliseconds(200))
        _ = await alice.syncAll(discoveryTimeout: .milliseconds(200))
        #expect(try await texts(alice).contains("hi Alice, from Bob"))
    }

    @Test("only the owner can configure a pod, and only for a certified pod")
    func podSecurity() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let mallory = try await Account.create(home: temporaryHome(), displayName: "Mallory")
        let (pod, code) = try await PodNode.create(home: temporaryHome(), host: "127.0.0.1", port: 1)

        // A bundle that doesn't certify this pod is refused.
        await #expect(throws: PodError.notCertified) {
            try await pod.pair(PodBundle(identityDocument: await mallory.identityDocument))
        }
        _ = try await pod.pair(try await alice.addPod(code))
        try await mallory.addContact(invite: await alice.invite())
        try await alice.addContact(invite: await mallory.invite())

        // Mallory, a contact, connects and sends her own "pod config".
        let forged = try await mallory.forgedPodConfig(owner: alice.user)
        let engine = SyncEngine(
            store: mallory.store, identityDocument: await mallory.identityDocument,
            policy: SyncPolicy(isAllowed: { _ in true }, interests: { [] }, outgoingControl: { _ in [forged] }),
            now: { UInt64(Date().timeIntervalSince1970 * 1000) }
        )
        // The pod only knows Alice's contacts once Alice configures it.
        try await servingPod(pod) { port in
            _ = try await alice.sync(host: "127.0.0.1", port: port)
            _ = try await withNoiseConnection(host: "127.0.0.1", port: port,
                                              handshake: await mallory.makeHandshake(role: .initiator)) { session in
                try await engine.run(over: session)
            }
        }
        // Alice's real config (contacts: just Mallory) is in force, not the
        // forgery (which also lists a stranger, at the highest version).
        #expect(await pod.config?.contacts == [mallory.user])
        #expect(await pod.config?.version != .max)
    }

    @Test("contacts reach each other through a relay")
    func relay() async throws {
        let relayKeys = DeviceKeyPair()
        let relayKey = relayKeys.agreementPublicKey
        let relay = try await RelayServer(host: "127.0.0.1", port: 0, handshake: NoiseHandshake(role: .responder, device: relayKeys))
        let relayTask = Task { try await relay.run() }
        defer { relayTask.cancel() }

        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let endpoint = RelayEndpoint(host: "127.0.0.1", port: UInt16(relay.port), key: relayKey)
        try await alice.addRelay(endpoint)
        try await alice.addContact(invite: await bob.invite())
        try await bob.addContact(invite: await alice.invite())
        try await alice.post(RichText(plain: "reached through a relay"), to: .everyone)

        let (reserved, signal) = AsyncStream.makeStream(of: Void.self)
        let serving = Task { try await alice.serveViaRelay(endpoint, onReserved: { signal.yield() }) }
        defer { serving.cancel() }
        for await _ in reserved { break }

        let attempts = await bob.syncAll(discoveryTimeout: .milliseconds(200))
        #expect(attempts.contains { $0.route.contains("via relay") && (try? $0.result.get()) != nil })
        #expect(try await texts(bob) == ["reached through a relay"])
    }
}

extension Account {
    /// A pod config signed by this account's device, for testing that pods
    /// refuse configuration from anyone but their owner.
    func forgedPodConfig(owner: UserID) throws -> SignedObject {
        let stranger = try UserID(ed25519PublicKey: [UInt8](repeating: 0x5A, count: 32))
        let config = PodConfig(owner: owner, version: .max, contacts: [user, stranger])
        return try signForTesting(config, label: .podConfig)
    }
}

@Suite("Revoking devices")
struct RevokeDeviceTests {
    @Test("a revoked pod loses its address and can't authenticate, even with its old identity document")
    func revokePod() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let (pod, _) = try await PodNode.create(home: temporaryHome(), host: "127.0.0.1", port: 0)
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await pod.makeHandshake(role: .responder))
        try await pod.setAddress(host: "127.0.0.1", port: UInt16(listener.port))
        _ = try await pod.pair(try await alice.addPod(await pod.pairingCode))
        try await befriend(alice, bob)
        let task = Task { try await listener.run { session in _ = try await pod.respond(over: session) } }
        defer { task.cancel() }
        _ = try await alice.sync(host: "127.0.0.1", port: listener.port) // configures the pod (Bob is a contact)
        _ = try await bob.sync(host: "127.0.0.1", port: listener.port) // works before

        await #expect(throws: AccountError.cannotRevokeThisDevice) { try await alice.revokeDevice(alice.deviceID) }
        try await alice.revokeDevice(pod.deviceID)
        #expect(await alice.endpoints.pods.isEmpty)
        #expect(try await alice.devices().first { $0.device == pod.deviceID }?.revoked == true)

        // Bob learns of the revocation from Alice; the pod still holds and
        // presents the old document, which no longer gets it in.
        try await serving(alice) { port in _ = try await bob.sync(host: "127.0.0.1", port: port) }
        await #expect(throws: (any Error).self) { try await bob.sync(host: "127.0.0.1", port: listener.port) }
    }
}
