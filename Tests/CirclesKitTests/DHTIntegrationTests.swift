import Testing
import Foundation
import CirclesCore
import CirclesCrypto
import CirclesNet
import CirclesSync
import CirclesDHT
@testable import CirclesKit

/// A DHT bootstrap node like the one `circles-relay --dht-port` runs.
func withBootstrapNode<R>(_ body: (String) async throws -> R) async throws -> R {
    let server = try await DHTServer(home: temporaryHome(), host: "127.0.0.1", port: 0)
    let task = Task { try await server.run(seeds: []) }
    defer { task.cancel() }
    return try await body(try DHTNodeText.text(for: DHTContact(key: server.node.key, host: "127.0.0.1", port: UInt16(server.port))))
}

func useBootstrap(_ text: String, _ accounts: Account...) async throws {
    for account in accounts {
        var preferences = try await account.preferences()
        preferences.dhtBootstrap = [text]
        try await account.setPreferences(preferences)
    }
}

/// Serves `account` (sync and DHT) on a fresh port until `body` returns.
func listening<R>(_ account: Account, _ body: (Int) async throws -> R) async throws -> R {
    let listener = try await account.makeListener(host: "127.0.0.1", port: 0)
    let task = Task { try await listener.run { session in _ = try await account.respond(over: session) } }
    defer { task.cancel() }
    return try await body(listener.port)
}

@Suite("DHT in the running node")
struct DHTIntegrationTests {
    @Test("add a contact by user ID alone, found through a bootstrap node")
    func addByUserID() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await withBootstrapNode { node in
            try await useBootstrap(node, alice, bob)
            let (nodes, stored) = await alice.maintainDHT()
            #expect(nodes == 1 && stored == 1)
            let contact = try await bob.addContact(user: alice.user)
            #expect(contact.name == "Alice")
            await #expect(throws: AccountError.notFoundInDHT) {
                try await bob.addContact(user: IdentityKeyPair().userID)
            }
        }
    }

    @Test("a contact who moved is found again through the DHT")
    func movedContact() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await withBootstrapNode { node in
            try await useBootstrap(node, alice, bob)
            // Alice was at one address when Bob last heard from her…
            try await listening(alice) { port in
                try await alice.setDirectEndpoint(host: "127.0.0.1", port: port)
                _ = try await bob.sync(host: "127.0.0.1", port: port)
            }
            // …then moved, and published the new one only to the DHT.
            try await listening(alice) { port in
                try await alice.setDirectEndpoint(host: "127.0.0.1", port: port)
                try await alice.post(RichText(plain: "from my new place"), to: .everyone)
                await alice.maintainDHT()
                let attempts = await bob.syncAll(discoveryTimeout: .milliseconds(10))
                #expect(attempts.contains { $0.route.contains("addresses from the DHT") && $0.succeeded })
                #expect(try await bob.stream().map(\.body.plainText).contains("from my new place"))
            }
        }
    }

    @Test("a pod keeps its owner findable while the owner is away")
    func podPublishesOwner() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let dave = try await Account.create(home: temporaryHome(), displayName: "Dave")
        let (pod, _) = try await PodNode.create(home: temporaryHome(), host: "127.0.0.1", port: 0)
        let listener = try await pod.makeListener(host: "127.0.0.1", port: 0)
        try await pod.setAddress(host: "127.0.0.1", port: UInt16(listener.port))
        _ = try await pod.pair(try await alice.addPod(await pod.pairingCode))
        let task = Task { try await listener.run { session in _ = try await pod.respond(over: session) } }
        defer { task.cancel() }

        // Pairing told Alice's identity the pod's DHT key, so contacts can join through it.
        #expect(await alice.endpoints.pods.first?.dhtKey == pod.dht.key)
        // The pod publishes; Alice's own devices never do.
        #expect(await pod.maintainDHT().stored == 1)
        let podNode = try DHTNodeText.text(for: DHTContact(key: pod.dht.key, host: "127.0.0.1", port: UInt16(listener.port)))
        try await useBootstrap(podNode, dave)
        #expect(try await dave.addContact(user: alice.user).name == "Alice")
    }

    @Test("one listener answers DHT requests and sync; the wrong key is refused")
    func sharedPort() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await listening(alice) { port in
            let transport = NoiseDHTTransport { await bob.makeDHTHandshake(role: .initiator) }
            let aliceNode = DHTContact(key: alice.dht.key, host: "127.0.0.1", port: UInt16(port))
            let reply = try await transport.send(.findNode(target: NodeID.random(), listenPort: 4000), to: aliceNode)
            #expect(reply == .nodes([], observed: "127.0.0.1"))
            // Bob said he listens on 4000, so Alice records him at the address she saw.
            #expect(await alice.dht.contacts == [DHTContact(key: bob.dht.key, host: "127.0.0.1", port: 4000)])

            let impostor = DHTContact(key: DeviceKeyPair().agreementPublicKey, host: "127.0.0.1", port: UInt16(port))
            await #expect(throws: DHTError.wrongNode) {
                try await transport.send(.findNode(target: NodeID.random(), listenPort: nil), to: impostor)
            }
            // Sync on the same port still works.
            #expect(try await bob.sync(host: "127.0.0.1", port: port).peer == alice.user)
        }
    }

    @Test("preferences saved before the DHT existed still load, with it on")
    func oldPreferences() throws {
        struct Old: Encodable {
            var advertiseOnLocalNetwork = false
            var mapRouterPort = true
            var publishPublicAddress = false
            var port = 7000
            var syncIntervalSeconds = 30
        }
        let preferences = try CBORDecoder().decode(NodePreferences.self, from: try CBOREncoder().encode(Old()))
        #expect(preferences.port == 7000 && preferences.mapRouterPort && !preferences.advertiseOnLocalNetwork)
        #expect(preferences.useDHT && preferences.dhtBootstrap.isEmpty)
    }
}
