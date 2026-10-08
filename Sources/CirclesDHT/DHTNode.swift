public import CirclesCore
public import CirclesCrypto

/// How a node reaches others: sends one request, returns the response. The
/// production transport opens a Noise session and checks the contact's key;
/// tests use an in-memory network.
public protocol DHTTransport: Sendable {
    func send(_ request: DHTMessage, to contact: DHTContact) async throws -> DHTMessage
}

public enum DHTError: Error, Sendable, Equatable {
    case unexpectedResponse
    case wrongNode
}

/// Kademlia routing: 256 buckets of up to `k` contacts, by shared prefix
/// with our own ID. Long-lived contacts are kept over new ones (they're
/// likelier to stay up, and it resists table flooding); newcomers wait in a
/// small replacement list until a contact fails.
struct RoutingTable: Sendable {
    let me: NodeID
    let k: Int
    private(set) var buckets: [[DHTContact]]
    private var replacements: [[DHTContact]]

    init(me: NodeID, k: Int) {
        self.me = me
        self.k = k
        buckets = Array(repeating: [], count: 256)
        replacements = Array(repeating: [], count: 256)
    }

    private func bucket(for id: NodeID) -> Int? {
        let shared = me.sharedPrefixLength(with: id)
        return shared == 256 ? nil : shared
    }

    /// Records that `contact` answered us (or reached us).
    mutating func saw(_ contact: DHTContact) {
        guard let index = bucket(for: contact.id) else { return }
        if let existing = buckets[index].firstIndex(where: { $0.key == contact.key }) {
            buckets[index].remove(at: existing)
            buckets[index].append(contact) // most recently seen last, address refreshed
        } else if buckets[index].count < k {
            buckets[index].append(contact)
        } else {
            replacements[index].removeAll { $0.key == contact.key }
            replacements[index].append(contact)
            if replacements[index].count > k { replacements[index].removeFirst() }
        }
    }

    /// Drops a contact that failed to answer, promoting a replacement.
    mutating func failed(_ contact: DHTContact) {
        guard let index = bucket(for: contact.id),
              let existing = buckets[index].firstIndex(where: { $0.key == contact.key })
        else { return }
        buckets[index].remove(at: existing)
        if !replacements[index].isEmpty { buckets[index].append(replacements[index].removeLast()) }
    }

    func closest(to target: NodeID, count: Int) -> [DHTContact] {
        Array(target.sortByDistance(buckets.joined()).prefix(count))
    }

    var all: [DHTContact] { Array(buckets.joined()) }
}

/// A Kademlia node (docs/DESIGN.md §7.2) that stores signed identity
/// documents, keyed by `NodeID(user:)`, and nothing else. Records verify
/// themselves, a higher version replaces a lower, and records expire unless
/// their owner republishes them.
public actor DHTNode {
    public nonisolated let id: NodeID
    public nonisolated let key: AgreementPublicKey
    /// Where we accept connections; nil for a node that only asks.
    public var listenPort: UInt16?
    /// Our address as other nodes see it, most recently reported.
    public private(set) var observedAddress: String?

    public static let k = 20
    public static let alpha = 3
    public static let recordLifetimeMillis: UInt64 = 24 * 3600 * 1000
    public static let maxRecords = 10_000
    /// Disjoint paths for value lookups and publishing (S/Kademlia).
    public static let lookupPaths = 3
    /// Stores accepted per requesting IP per hour: room for a household of
    /// owners republishing every 30 minutes, not for flooding.
    public static let storesPerHostPerHour = 60

    private var table: RoutingTable
    private var records: [NodeID: Record] = [:]
    private var storeCounts: [String: (count: Int, windowStart: UInt64)] = [:]
    private let transport: any DHTTransport
    private let now: @Sendable () -> UInt64
    private let capacity: Int

    struct Record: Sendable {
        var document: SignedObject
        var version: UInt64
        var expiresMillis: UInt64
    }

    public init(key: AgreementPublicKey, listenPort: UInt16?, transport: any DHTTransport,
                now: @escaping @Sendable () -> UInt64, capacity: Int = DHTNode.maxRecords) {
        self.capacity = capacity
        self.key = key
        id = NodeID(node: key)
        self.listenPort = listenPort
        self.transport = transport
        self.now = now
        table = RoutingTable(me: NodeID(node: key), k: Self.k)
    }

    public func setListenPort(_ port: UInt16?) { listenPort = port }

    public var contacts: [DHTContact] { table.all }
    public var recordCount: Int { records.count }

    // MARK: Answering

    /// Answers a request. `from` is the requester as the connection saw it
    /// (its proven key and observed address, with the port it said it
    /// listens on), or nil if it doesn't accept connections.
    public func handle(_ request: DHTMessage, from contact: DHTContact?, observedHost: String?) -> DHTMessage {
        if let contact { table.saw(contact) }
        switch request {
        case .findNode(let target, _):
            return .nodes(closest(to: target, excluding: contact), observed: observedHost)
        case .findValue(let key, _):
            expire()
            if let record = records[key] { return .value(record.document, nodes: closest(to: key, excluding: contact)) }
            return .nodes(closest(to: key, excluding: contact), observed: observedHost)
        case .store(let document, _):
            guard withinStoreQuota(observedHost) else { return .stored(false) }
            return .stored(accept(document))
        case .nodes, .value, .stored:
            return .stored(false)
        }
    }

    private func closest(to target: NodeID, excluding contact: DHTContact?) -> [DHTContact] {
        table.closest(to: target, count: Self.k + 1).filter { $0.key != contact?.key }.prefix(Self.k).map { $0 }
    }

    /// Counts a store from `host` against its hourly quota.
    private func withinStoreQuota(_ host: String?) -> Bool {
        guard let host else { return true } // ourselves, in tests
        let time = now()
        var entry = storeCounts[host] ?? (0, time)
        if time - entry.windowStart >= 3600 * 1000 { entry = (0, time) }
        guard entry.count < Self.storesPerHostPerHour else { return false }
        entry.count += 1
        storeCounts[host] = entry
        if storeCounts.count > 4 * capacity {
            storeCounts = storeCounts.filter { time - $0.value.windowStart < 3600 * 1000 }
        }
        return true
    }

    /// Keeps a valid identity document, unless we hold a newer one. When
    /// full, a record replaces the one farthest from our ID if it's closer:
    /// Kademlia nodes answer for keys near them, so flooding can't push
    /// those out.
    private func accept(_ document: SignedObject) -> Bool {
        guard let verified = Self.verify(document) else { return false }
        let key = NodeID(user: verified.user)
        expire()
        if let existing = records[key], existing.version > verified.version { return false }
        if records[key] == nil, records.count >= capacity {
            guard let farthest = records.keys.max(by: { $0.distance(to: id).lexicographicallyPrecedes($1.distance(to: id)) }),
                  key.distance(to: id).lexicographicallyPrecedes(farthest.distance(to: id))
            else { return false }
            records[farthest] = nil
        }
        records[key] = Record(document: document, version: verified.version, expiresMillis: now() + Self.recordLifetimeMillis)
        return true
    }

    private func expire() {
        let time = now()
        records = records.filter { $0.value.expiresMillis > time }
    }

    static func verify(_ document: SignedObject) -> VerifiedIdentity? {
        guard let claimed = try? CBORDecoder().decode(IdentityDocument.self, from: document.payload) else { return nil }
        return try? VerifiedIdentity(verifying: document, for: claimed.user)
    }

    // MARK: Asking

    /// Joins the network through known nodes, then fills the table by
    /// looking up our own ID. Returns how many nodes we now know.
    @discardableResult
    public func bootstrap(_ seeds: [DHTContact]) async -> Int {
        for seed in seeds where seed.key != key { table.saw(seed) }
        _ = await lookup(id, value: nil)
        // Also look up a random ID, to learn nodes beyond our neighborhood.
        _ = await lookup(NodeID.random(), value: nil)
        return table.all.count
    }

    /// Finds the newest identity document for `user` the network holds.
    public func find(_ user: UserID) async -> SignedObject? {
        let key = NodeID(user: user)
        let found = await lookup(key, value: key, paths: Self.lookupPaths).records.compactMap { record -> (SignedObject, UInt64)? in
            guard let verified = Self.verify(record), verified.user == user else { return nil }
            return (record, verified.version)
        }
        return found.max { $0.1 < $1.1 }?.0
    }

    /// Stores an identity document at the nodes closest to its user.
    /// Returns how many accepted it, counting ourselves when we listen
    /// (others can then find it here).
    @discardableResult
    public func publish(_ document: SignedObject) async -> Int {
        guard let verified = Self.verify(document) else { return 0 }
        let key = NodeID(user: verified.user)
        let keptHere = accept(document) && listenPort != nil
        let targets = await lookup(key, value: nil, paths: Self.lookupPaths).closest
        return await withTaskGroup(of: Bool.self) { group in
            for contact in targets {
                group.addTask { [transport, listenPort] in
                    (try? await transport.send(.store(document, listenPort: listenPort), to: contact)) == .stored(true)
                }
            }
            var accepted = keptHere ? 1 : 0
            for await ok in group where ok { accepted += 1 }
            return accepted
        }
    }

    /// Iterative Kademlia lookup along `paths` disjoint paths (S/Kademlia):
    /// the closest known nodes are dealt out among the paths, and each path
    /// asks the closest unasked nodes on its own list, `alpha` at a time,
    /// until its `k` closest have all answered. A node asked by one path is
    /// never asked by another, so an attacker has to sit on every path to
    /// hide or poison the result. With `value`, also collects records from
    /// every responder (so one stale or lying node can't hide a newer version).
    func lookup(_ target: NodeID, value: NodeID?, paths: Int = 1) async -> (closest: [DHTContact], records: [SignedObject]) {
        let pathCount = max(1, paths)
        var shortlists = Array(repeating: [NodeID: DHTContact](), count: pathCount)
        for (index, contact) in table.closest(to: target, count: Self.k).enumerated() {
            shortlists[index % pathCount][contact.id] = contact
        }
        var asked: Set<NodeID> = [], answered: [DHTContact] = [], records: [SignedObject] = []
        let request: DHTMessage = value.map { .findValue(key: $0, listenPort: listenPort) }
            ?? .findNode(target: target, listenPort: listenPort)
        var active = Set(0..<pathCount)
        while !active.isEmpty {
            for path in active.sorted() {
                let closest = target.sortByDistance(shortlists[path].values).prefix(Self.k)
                let batch = closest.filter { !asked.contains($0.id) }.prefix(Self.alpha)
                if batch.isEmpty {
                    active.remove(path)
                    continue
                }
                for contact in batch { asked.insert(contact.id) }
                let responses = await withTaskGroup(of: (DHTContact, DHTMessage?).self) { group in
                    for contact in batch {
                        group.addTask { [transport] in (contact, try? await transport.send(request, to: contact)) }
                    }
                    var all: [(DHTContact, DHTMessage?)] = []
                    for await response in group { all.append(response) }
                    return all
                }
                for (contact, response) in responses {
                    let nodes: [DHTContact]
                    switch response {
                    case .nodes(let found, let observed)?:
                        nodes = found
                        if let observed { observedAddress = observed }
                    case .value(let record, let found)?:
                        nodes = found
                        records.append(record)
                    default:
                        table.failed(contact)
                        shortlists[path][contact.id] = nil
                        continue
                    }
                    table.saw(contact)
                    answered.append(contact)
                    // Nodes another path has asked stay that path's.
                    for node in nodes.prefix(Self.k) where node.key != key && !asked.contains(node.id) {
                        shortlists[path][node.id] = shortlists[path][node.id] ?? node
                    }
                }
            }
        }
        return (Array(target.sortByDistance(answered).prefix(Self.k)), records)
    }
}
