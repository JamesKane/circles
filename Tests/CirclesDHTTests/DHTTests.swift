import Testing
import Synchronization
import CirclesCore
import CirclesCrypto
import CirclesSync
@testable import CirclesDHT

/// An in-memory network of DHT nodes. Nodes can be taken offline.
final class MemoryNetwork: Sendable {
    private let nodes = Mutex<[AgreementPublicKey: DHTNode]>([:])
    private let offline = Mutex<Set<AgreementPublicKey>>([])
    let clock = Mutex<UInt64>(1_000_000)

    func add(_ node: DHTNode, key: AgreementPublicKey) { nodes.withLock { $0[key] = node } }
    func setOffline(_ key: AgreementPublicKey, _ isOffline: Bool) {
        offline.withLock { if isOffline { $0.insert(key) } else { $0.remove(key) } }
    }

    func deliver(_ request: DHTMessage, to contact: DHTContact, from sender: DHTContact) async throws -> DHTMessage {
        guard !offline.withLock({ $0.contains(contact.key) }), let node = nodes.withLock({ $0[contact.key] }) else {
            throw DHTError.unexpectedResponse
        }
        let port: UInt16? = switch request {
        case .findNode(_, let port), .findValue(_, let port), .store(_, let port): port
        default: nil
        }
        let from = port.map { DHTContact(key: sender.key, host: sender.host, port: $0) }
        return await node.handle(request, from: from, observedHost: sender.host)
    }
}

struct MemoryTransport: DHTTransport {
    let me: DHTContact
    let network: MemoryNetwork

    func send(_ request: DHTMessage, to contact: DHTContact) async throws -> DHTMessage {
        try await network.deliver(request, to: contact, from: me)
    }
}

/// `count` nodes, each listening at 10.0.<i>.1:4000.
func makeNetwork(_ count: Int) -> (MemoryNetwork, [DHTNode], [DHTContact]) {
    let network = MemoryNetwork()
    var nodes: [DHTNode] = [], contacts: [DHTContact] = []
    for index in 0..<count {
        let key = DeviceKeyPair().agreementPublicKey
        let contact = DHTContact(key: key, host: "10.0.\(index / 250).\(index % 250 + 1)", port: 4000)
        let node = DHTNode(key: key, listenPort: 4000, transport: MemoryTransport(me: contact, network: network),
                           now: { network.clock.withLock { $0 } })
        network.add(node, key: key)
        nodes.append(node)
        contacts.append(contact)
    }
    return (network, nodes, contacts)
}

/// A signed identity document at `version`.
func identityDocument(_ identity: borrowing IdentityKeyPair, version: UInt64, name: String) throws -> SignedObject {
    let device = DeviceKeyPair()
    let certificate = try DeviceCertificate.issue(for: device, by: identity, capabilities: .author,
                                                  issuedMillis: 1, validForMillis: 1 << 50)
    return try IdentityDocument(user: identity.userID, version: version, certificates: [certificate], displayName: name).signed(by: identity)
}

extension DHTMessage {
    var record: SignedObject? { if case .value(let record, _) = self { record } else { nil } }
}

func name(in document: SignedObject?) -> String? {
    document.flatMap { try? CBORDecoder().decode(IdentityDocument.self, from: $0.payload).displayName }
}

@Suite("DHT")
struct DHTTests {
    @Test("messages round-trip and are told apart from sync messages by their first frame")
    func wire() throws {
        let identity = IdentityKeyPair()
        let key = DeviceKeyPair().agreementPublicKey
        let messages: [DHTMessage] = [
            .findNode(target: NodeID.random(), listenPort: 4000),
            .findValue(key: NodeID(user: identity.userID), listenPort: nil),
            .store(try identityDocument(identity, version: 1, name: "A"), listenPort: 9),
            .nodes([DHTContact(key: key, host: "192.0.2.1", port: 7)], observed: "198.51.100.2"),
            .nodes([], observed: nil),
            .value(try identityDocument(identity, version: 2, name: "A"), nodes: []),
            .stored(true),
        ]
        for message in messages {
            let bytes = try CBOREncoder().encode(message)
            #expect(try CBORDecoder().decode(DHTMessage.self, from: bytes) == message)
            #expect(DHTMessage.isDHT(bytes))
        }
        for sync: SyncMessage in [.ready, .done, .entriesDone, .wantBlobs([])] {
            #expect(!DHTMessage.isDHT(try CBOREncoder().encode(sync)))
        }
        #expect(!DHTMessage.isDHT([0xFF, 0x00]))
    }

    @Test("a hundred nodes bootstrap from one seed, and a record published at one end is found from the other")
    func publishAndFind() async throws {
        let (_, nodes, contacts) = makeNetwork(100)
        for node in nodes.dropFirst() { await node.bootstrap([contacts[0]]) }
        await nodes[0].bootstrap([contacts[1]])
        for node in nodes { #expect(await node.contacts.count >= DHTNode.k) }

        let alice = IdentityKeyPair()
        let accepted = await nodes[17].publish(try identityDocument(alice, version: 1, name: "Alice"))
        #expect(accepted >= DHTNode.k - 1)
        for finder in [nodes[3], nodes[64], nodes[99]] {
            #expect(name(in: await finder.find(alice.userID)) == "Alice")
        }
        #expect(await nodes[50].find(IdentityKeyPair().userID) == nil)
    }

    @Test("a newer version wins, an older one is refused, and one stale node can't hide the newer")
    func versions() async throws {
        let (network, nodes, contacts) = makeNetwork(40)
        for node in nodes.dropFirst() { await node.bootstrap([contacts[0]]) }
        let alice = IdentityKeyPair()
        let v1 = try identityDocument(alice, version: 1, name: "Alice v1")
        let v2 = try identityDocument(alice, version: 2, name: "Alice v2")
        await nodes[5].publish(v1)
        // The node closest to Alice's key misses v2 while offline, so it
        // comes back holding only v1: a stale responder.
        let stale = NodeID(user: alice.userID).sortByDistance(contacts)[0]
        network.setOffline(stale.key, true)
        await nodes[6].publish(v2)
        network.setOffline(stale.key, false)
        let staleNode = nodes[contacts.firstIndex(of: stale)!]
        #expect(name(in: await staleNode.handle(.findValue(key: NodeID(user: alice.userID), listenPort: nil), from: nil, observedHost: nil).record)
                == "Alice v1")
        #expect(name(in: await nodes[30].find(alice.userID)) == "Alice v2")

        // A node holding v2 refuses v1.
        let holder = nodes[0]
        _ = await holder.handle(.store(v2, listenPort: nil), from: nil, observedHost: nil)
        #expect(await holder.handle(.store(v1, listenPort: nil), from: nil, observedHost: nil) == .stored(false))

        // Republishing the old version can land on nodes that never got v2,
        // but lookups take the newest version any responder holds.
        await nodes[7].publish(v1)
        for finder in [nodes[20], nodes[31], nodes[39]] {
            #expect(name(in: await finder.find(alice.userID)) == "Alice v2")
        }
    }

    @Test("forged and tampered records are refused")
    func forgery() async throws {
        let (_, nodes, _) = makeNetwork(1)
        let alice = IdentityKeyPair(), mallory = IdentityKeyPair()
        let genuine = try identityDocument(alice, version: 1, name: "Alice")
        var payload = genuine.payload
        payload[payload.count - 1] ^= 0x01
        let tampered = SignedObject(payload: payload, signer: genuine.signer, signature: genuine.signature)
        #expect(await nodes[0].handle(.store(tampered, listenPort: nil), from: nil, observedHost: nil) == .stored(false))
        // Mallory signs a document claiming to be Alice's.
        let device = DeviceKeyPair()
        let certificate = try DeviceCertificate.issue(for: device, by: mallory, capabilities: .author, issuedMillis: 1, validForMillis: 1 << 50)
        let claim = try IdentityDocument(user: alice.userID, version: 9, certificates: [certificate], displayName: "Alice")
        let forged = try SignedObject(signing: try CBOREncoder().encode(claim), label: .identityDocument, with: mallory)
        #expect(await nodes[0].handle(.store(forged, listenPort: nil), from: nil, observedHost: nil) == .stored(false))
        #expect(await nodes[0].recordCount == 0)
    }

    @Test("records survive a third of the network going offline, and expire unless republished")
    func churnAndExpiry() async throws {
        let (network, nodes, contacts) = makeNetwork(60)
        for node in nodes.dropFirst() { await node.bootstrap([contacts[0]]) }
        let alice = IdentityKeyPair()
        let document = try identityDocument(alice, version: 1, name: "Alice")
        await nodes[10].publish(document)

        for index in stride(from: 0, to: 60, by: 3) where index != 40 { network.setOffline(contacts[index].key, true) }
        #expect(name(in: await nodes[40].find(alice.userID)) == "Alice")

        network.clock.withLock { $0 += DHTNode.recordLifetimeMillis + 1 }
        #expect(await nodes[41].find(alice.userID) == nil)
        await nodes[10].publish(document)
        #expect(name(in: await nodes[41].find(alice.userID)) == "Alice")
    }

    @Test("nodes learn the address others see them at, and only nodes that listen are added to tables")
    func observedAddresses() async throws {
        let (network, nodes, contacts) = makeNetwork(2)
        await nodes[1].bootstrap([contacts[0]])
        #expect(await nodes[1].observedAddress == contacts[1].host)
        #expect(await nodes[0].contacts.map(\.key) == [contacts[1].key])

        // A node that doesn't listen asks, but isn't added.
        let key = DeviceKeyPair().agreementPublicKey
        let client = DHTNode(key: key, listenPort: nil,
                             transport: MemoryTransport(me: DHTContact(key: key, host: "203.0.113.9", port: 0), network: network),
                             now: { 0 })
        await client.bootstrap([contacts[0]])
        #expect(await nodes[0].contacts.count == 1)
        #expect(await client.contacts.count == 2)
    }

    @Test("full buckets keep long-lived contacts; a failure promotes a waiting one")
    func routingTable() throws {
        let me = NodeID.random()
        var table = RoutingTable(me: me, k: 2)
        // Keys whose IDs share no prefix bit with ours all land in bucket 0.
        var bucketZero: [DHTContact] = []
        while bucketZero.count < 3 {
            let contact = DHTContact(key: DeviceKeyPair().agreementPublicKey, host: "h", port: 1)
            if me.sharedPrefixLength(with: contact.id) == 0 { bucketZero.append(contact) }
        }
        for contact in bucketZero { table.saw(contact) }
        #expect(Set(table.all.map(\.key)) == Set(bucketZero.prefix(2).map(\.key)))
        table.failed(bucketZero[0])
        #expect(Set(table.all.map(\.key)) == [bucketZero[1].key, bucketZero[2].key])
    }
}
