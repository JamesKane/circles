public import Foundation
public import CirclesCore
public import CirclesCrypto
public import CirclesSync
public import CirclesNet
public import CirclesDHT
import CirclesStorage

// The DHT in a running node (docs/DESIGN.md §7.2): every listener answers
// DHT requests on its usual port, telling them from sync by the first frame.

/// Sends DHT requests over Noise sessions, checking that the node that
/// answers holds the contact's key.
public struct NoiseDHTTransport: DHTTransport {
    let handshake: @Sendable () async -> NoiseHandshake?
    let timeout: Duration

    public init(timeout: Duration = .seconds(5), handshake: @escaping @Sendable () async -> NoiseHandshake?) {
        self.handshake = handshake
        self.timeout = timeout
    }

    public func send(_ request: DHTMessage, to contact: DHTContact) async throws -> DHTMessage {
        guard let handshake = await handshake() else { throw CancellationError() }
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: DHTMessage.self) { group in
            group.addTask {
                try await withNoiseConnection(host: contact.host, port: Int(contact.port), handshake: handshake,
                                              handshakeTimeout: timeout) { session in
                    guard session.remoteStaticKey == contact.key else { throw DHTError.wrongNode }
                    try await session.send(try CBOREncoder().encode(request))
                    guard let reply = try await session.receive() else { throw DHTError.unexpectedResponse }
                    return try CBORDecoder().decode(DHTMessage.self, from: reply)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DHTError.unexpectedResponse
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// Answers one DHT request whose frame has already been read.
public func answerDHT(_ frame: [UInt8], over channel: some MessageChannel, node: DHTNode) async throws {
    let request = try CBORDecoder().decode(DHTMessage.self, from: frame)
    let port: UInt16? = switch request {
    case .findNode(_, let port), .findValue(_, let port), .store(_, let port): port
    default: nil
    }
    // The requester is recorded at the address its connection came from,
    // and only if it says it listens.
    var contact: DHTContact?
    if let port, port != 0, let key = channel.remoteStaticKey, let host = channel.remoteHost {
        contact = DHTContact(key: key, host: host, port: port)
    }
    let response = await node.handle(request, from: contact, observedHost: channel.remoteHost)
    try await channel.send(try CBOREncoder().encode(response))
}

/// Text for a DHT node, to configure as a bootstrap node.
public enum DHTNodeText {
    static let prefix = "circles-dht-node:"

    public static func text(for contact: DHTContact) throws -> String {
        prefix + Base32.encode(try CBOREncoder().encode(contact))
    }

    public static func contact(from text: String) throws -> DHTContact {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), let bytes = Base32.decode(trimmed.dropFirst(prefix.count)) else {
            throw AccountError.invalidInvite
        }
        return try CBORDecoder().decode(DHTContact.self, from: bytes)
    }
}

/// A node that only takes part in the DHT, e.g. a bootstrap node run beside
/// a relay. It answers DHT requests and nothing else.
public struct DHTServer: Sendable {
    public let node: DHTNode
    let listener: NoiseListener

    public init(identity: RelayIdentity, host: String, port: Int) async throws {
        listener = try await NoiseListener(host: host, port: port, handshake: identity.makeHandshake())
        node = DHTNode(key: identity.agreementKey, listenPort: UInt16(listener.port),
                       transport: NoiseDHTTransport { identity.makeHandshake(role: .initiator) },
                       now: { wallClockMillis() })
    }

    public var port: Int { listener.port }

    /// Runs until cancelled, rejoining through `seeds` (and the nodes it has
    /// met) every `refresh`.
    public func run(seeds: [DHTContact], refresh: Duration = .seconds(NodeService.dhtRefreshSeconds),
                    onRefresh: @escaping @Sendable (Int) -> Void = { _ in }) async throws {
        let node = self.node
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await listener.run { session in
                    guard let first = try await session.receive(), DHTMessage.isDHT(first) else { return }
                    try await answerDHT(first, over: session, node: node)
                }
            }
            group.addTask {
                while true {
                    onRefresh(await node.bootstrap(seeds))
                    try await Task.sleep(for: refresh)
                }
            }
            try await group.waitForAll()
        }
    }
}

/// Lets the account's DHT transport reach the account's device key without
/// a reference cycle.
final class WeakAccount: @unchecked Sendable {
    weak var account: Account?
}

extension Account {
    // MARK: Answering

    /// Answers an incoming session: a DHT request, or sync as ourselves or
    /// as a community we sequence. Returns the sync report, if it was sync.
    @discardableResult
    public func respond(over channel: some MessageChannel) async throws -> SyncReport? {
        guard let first = try await channel.receive() else { return nil }
        if DHTMessage.isDHT(first) {
            try await answerDHT(first, over: channel, node: dht)
            return nil
        }
        let me = user
        let report = try await SyncEngine.respond(over: channel, first: first) { target in
            guard let target, target != me else { return await self.syncEngine() }
            guard (try? await self.community(target).role) == .owner else { return nil }
            return try await self.communityEngine(target)
        }
        try await absorbKeyGrants()
        try await processCommunities()
        return report
    }

    // MARK: Joining and publishing

    /// Nodes to join the DHT through: configured bootstrap nodes, nodes
    /// remembered from last time, our pods and our contacts' pods.
    public func dhtSeeds() async -> [DHTContact] {
        var seeds = ((try? preferences().dhtBootstrap) ?? []).compactMap { try? DHTNodeText.contact(from: $0) }
        seeds += (try? files.load([DHTContact].self, from: files.dhtContacts)) ?? nil ?? []
        var identities: [VerifiedIdentity] = []
        if let mine = try? VerifiedIdentity(verifying: identityDocument, for: user) { identities.append(mine) }
        for contact in contacts {
            if let identity = try? await store.verifiedIdentity(for: contact.user) { identities.append(identity) }
        }
        for identity in identities {
            for pod in identity.endpoints.pods {
                guard let certificate = identity.certificates[pod.device] else { continue }
                seeds.append(DHTContact(key: certificate.agreementKey, host: pod.host, port: pod.port))
            }
        }
        var seen: Set<AgreementPublicKey> = [device.agreementPublicKey]
        return seeds.filter { seen.insert($0.key).inserted }
    }

    /// Joins (or refreshes our place in) the DHT and publishes our identity
    /// document and our communities'. Returns how many nodes we know and
    /// how many accepted our document.
    @discardableResult
    public func maintainDHT() async -> (nodes: Int, stored: Int) {
        let known = await dht.bootstrap(await dhtSeeds())
        var stored = await dht.publish(identityDocument)
        for state in (try? loadCommunities()) ?? [] where state.role == .owner {
            if let document = try? await store.identityDocument(for: state.community) {
                stored += await dht.publish(document)
            }
        }
        try? files.save(await dht.contacts, to: files.dhtContacts)
        return (known, stored)
    }

    /// Looks a user up in the DHT. A newer identity document than the one we
    /// hold (e.g. with new addresses) is saved. Returns the newest we have.
    @discardableResult
    public func lookUp(_ user: UserID) async throws -> VerifiedIdentity? {
        let current = try await store.verifiedIdentity(for: user)
        if await dht.contacts.isEmpty { await dht.bootstrap(await dhtSeeds()) }
        guard let found = await dht.find(user) else { return current }
        let verified = try VerifiedIdentity(verifying: found, for: user)
        guard verified.version > current?.version ?? 0 else { return current }
        try await store.saveIdentityDocument(found, verified: verified)
        return verified
    }

    /// Adds a contact by user ID alone, finding their identity document in
    /// the DHT.
    @discardableResult
    public func addContact(user: UserID, name: String? = nil) async throws -> Contact {
        guard let identity = try await lookUp(user) else { throw AccountError.notFoundInDHT }
        return try saveContact(Contact(user: user, name: name ?? identity.document.displayName ?? String(user.description.prefix(20))))
    }
}
