import ArgumentParser
import Foundation
import Synchronization
import CirclesCore
import CirclesCrypto
import CirclesDHT

/// `circles-sim`: the DHT at scale (docs/DESIGN.md §12, M7). Thousands of
/// real `DHTNode`s on an in-memory network, measuring lookups as the network
/// grows, under churn, and under an eclipse attack, with and without
/// disjoint paths.
@main
struct Simulation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "circles-sim", abstract: "Simulate the Circles DHT at scale.")

    @Option(help: "Nodes in the network.") var nodes = 10_000
    @Option(help: "Identity documents published, and lookups per scenario.") var trials = 200
    @Option(help: "Attacker fractions to try, in percent.") var attackers: [Int] = [10, 20, 30]
    @Option(help: "Sybil counts for the targeted eclipse.") var sybils: [Int] = [5, 10, 20, 40]
    @Option(help: "DHT puzzle difficulty: node keys must solve it (S/Kademlia).") var puzzleBits = 0

    func run() async throws {
        let started = ContinuousClock.now
        let network = SimNetwork()
        print("Building a network of \(nodes) nodes…")
        let puzzle = puzzleBits
        let (all, contacts) = await network.build(count: nodes, puzzleBits: puzzle) { joined in
            if joined % 1000 == 0 { print("  \(joined) joined (\(elapsed(since: started)))") }
        }
        let tableSizes = await withTaskGroup(of: Int.self) { group in
            for node in all.prefix(500) { group.addTask { await node.contacts.count } }
            return await group.reduce(into: [Int]()) { $0.append($1) }
        }
        print("Built in \(elapsed(since: started)); routing tables hold \(tableSizes.min()!)–\(tableSizes.max()!) contacts (mean \(tableSizes.reduce(0, +) / tableSizes.count)).\n")

        // Documents to publish, each from a random node.
        var documents: [(user: UserID, document: SignedObject)] = []
        for _ in 0..<trials {
            let identity = IdentityKeyPair(), device = DeviceKeyPair()
            let certificate = try DeviceCertificate.issue(for: device, by: identity, capabilities: .author, issuedMillis: 0, validForMillis: 1 << 50)
            documents.append((identity.userID, try IdentityDocument(user: identity.userID, version: 1, certificates: [certificate],
                                                                    displayName: "sim").signed(by: identity)))
        }

        print("Scenario                                   paths  found   requests/lookup")
        func report(_ label: String, paths: Int, publishers: [DHTNode], finders: [DHTNode]) async {
            network.resetCount()
            var found = 0
            for (index, entry) in documents.enumerated() {
                if await finders[index % finders.count].find(entry.user, paths: paths) != nil { found += 1 }
            }
            let perLookup = Double(network.requestCount) / Double(documents.count)
            print(label.padding(toLength: 43, withPad: " ", startingAt: 0) + "\(paths)      "
                  + String(format: "%5.1f%%  %6.1f", 100 * Double(found) / Double(documents.count), perLookup))
        }

        let honest = all.shuffled()
        for (index, entry) in documents.enumerated() { await honest[index].publish(entry.document) }
        let finders = Array(honest.suffix(documents.count))
        await report("Baseline", paths: 1, publishers: honest, finders: finders)
        await report("Baseline", paths: 3, publishers: honest, finders: finders)

        for percent in [25, 50] {
            network.setOffline(Set(contacts.shuffled().prefix(nodes * percent / 100).map(\.key)))
            let online = finders.filter { !network.isOffline($0.key) }
            await report("Churn: \(percent)% of nodes offline", paths: 3, publishers: honest, finders: online)
        }
        network.setOffline([])

        for percent in attackers {
            // Attackers joined like everyone else, so they sit in routing
            // tables; now they answer every lookup with only each other,
            // withhold records, and drop stores.
            let attackerKeys = Set(contacts.shuffled().prefix(nodes * percent / 100).map(\.key))
            network.setAttackers(attackerKeys, contacts: contacts.filter { attackerKeys.contains($0.key) })
            let goodNodes = honest.filter { !attackerKeys.contains($0.key) }
            for (index, entry) in documents.enumerated() { await goodNodes[index % goodNodes.count].publish(entry.document) }
            let goodFinders = Array(goodNodes.suffix(documents.count))
            await report("Eclipse: \(percent)% of nodes attacking", paths: 1, publishers: goodNodes, finders: goodFinders)
            await report("Eclipse: \(percent)% of nodes attacking", paths: 3, publishers: goodNodes, finders: goodFinders)
            network.setAttackers([], contacts: [])
        }

        // A targeted eclipse: Sybils whose IDs were ground to sit right next
        // to one victim's key join normally, then turn.
        print("\nTargeted eclipse of one identity (Sybil IDs ground to be its nearest neighbors):")
        print("Sybils   paths  found   (of \(documents.count) lookups, each from a different node)")
        let victim = documents[0]
        let victimKey = NodeID(user: victim.user)
        let honestNearest = victimKey.sortByDistance(contacts).first!.id
        for count in sybils {
            var sybilContacts: [DHTContact] = []
            var tries = 0
            while sybilContacts.count < count {
                let key = DeviceKeyPair().agreementPublicKey
                tries += 1
                if NodeID(node: key).distance(to: victimKey).lexicographicallyPrecedes(honestNearest.distance(to: victimKey)),
                   DHTPuzzle.isSolved(key, bits: puzzle) {
                    sybilContacts.append(DHTContact(key: key, host: "172.16.\(sybilContacts.count / 250).\(sybilContacts.count % 250 + 1)", port: 4000))
                }
            }
            let sybilNodes = await network.join(sybilContacts, through: contacts, puzzleBits: puzzle)
            network.setAttackers(Set(sybilContacts.map(\.key)), contacts: sybilContacts)
            await honest[0].publish(victim.document)
            for paths in [1, 3] {
                var found = 0
                for finder in finders where await finder.find(victim.user, paths: paths) != nil { found += 1 }
                print("\(count)".padding(toLength: 9, withPad: " ", startingAt: 0) + "\(paths)      "
                      + String(format: "%5.1f%%", 100 * Double(found) / Double(finders.count)) + (paths == 1 ? "   (\(tries) keys ground)" : ""))
            }
            network.remove(sybilNodes)
            network.setAttackers([], contacts: [])
        }
        print("\nDone in \(elapsed(since: started)).")
    }
}

func elapsed(since start: ContinuousClock.Instant) -> String {
    let seconds = (ContinuousClock.now - start).components.seconds
    return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
}

/// An in-memory network that can take nodes offline and turn some into attackers.
final class SimNetwork: Sendable {
    private let nodes = Mutex<[AgreementPublicKey: DHTNode]>([:])
    private let offline = Mutex<Set<AgreementPublicKey>>([])
    private let attackers = Mutex<(keys: Set<AgreementPublicKey>, contacts: [DHTContact])>(([], []))
    private let requests = Atomic<Int>(0)

    var requestCount: Int { requests.load(ordering: .relaxed) }
    func resetCount() { requests.store(0, ordering: .relaxed) }
    func setOffline(_ keys: Set<AgreementPublicKey>) { offline.withLock { $0 = keys } }
    func isOffline(_ key: AgreementPublicKey) -> Bool { offline.withLock { $0.contains(key) } }
    func setAttackers(_ keys: Set<AgreementPublicKey>, contacts: [DHTContact]) { attackers.withLock { $0 = (keys, contacts) } }

    /// Builds `count` nodes, each joining through a random earlier one.
    func build(count: Int, puzzleBits: Int, progress: (Int) -> Void) async -> ([DHTNode], [DHTContact]) {
        var all: [DHTNode] = [], contacts: [DHTContact] = []
        for index in 0..<count {
            let key = puzzleBits > 0 ? DHTPuzzle.grind(bits: puzzleBits).agreementPublicKey : DeviceKeyPair().agreementPublicKey
            let contact = DHTContact(key: key, host: "10.\(index >> 16 & 255).\(index >> 8 & 255).\(index & 255)", port: 4000)
            let node = DHTNode(key: key, listenPort: 4000, transport: SimTransport(me: contact, network: self), now: { 1 },
                               puzzleBits: puzzleBits)
            nodes.withLock { $0[key] = node }
            if let seed = contacts.randomElement() { await node.bootstrap([seed]) }
            all.append(node)
            contacts.append(contact)
            progress(index + 1)
        }
        return (all, contacts)
    }

    /// Adds nodes that join through random existing ones (as Sybils would).
    func join(_ newcomers: [DHTContact], through existing: [DHTContact], puzzleBits: Int) async -> [AgreementPublicKey] {
        for contact in newcomers {
            let node = DHTNode(key: contact.key, listenPort: 4000, transport: SimTransport(me: contact, network: self), now: { 1 },
                               puzzleBits: puzzleBits)
            nodes.withLock { $0[contact.key] = node }
            await node.bootstrap([existing.randomElement()!])
        }
        return newcomers.map(\.key)
    }

    func remove(_ keys: [AgreementPublicKey]) {
        nodes.withLock { for key in keys { $0[key] = nil } }
        offline.withLock { $0.formUnion(keys) } // gone for good
    }

    func deliver(_ request: DHTMessage, to contact: DHTContact, from sender: DHTContact) async throws -> DHTMessage {
        requests.add(1, ordering: .relaxed)
        if offline.withLock({ $0.contains(contact.key) }) { throw DHTError.unexpectedResponse }
        let attack = attackers.withLock { $0 }
        if attack.keys.contains(contact.key) {
            switch request {
            case .store: return .stored(true) // and drop it
            case .findNode(let target, _), .findValue(let target, _):
                // Steer the lookup into attacker territory.
                return .nodes(Array(target.sortByDistance(attack.contacts).prefix(DHTNode.k)), observed: sender.host)
            default: return .stored(false)
            }
        }
        guard let node = nodes.withLock({ $0[contact.key] }) else { throw DHTError.unexpectedResponse }
        let port: UInt16? = switch request {
        case .findNode(_, let port), .findValue(_, let port), .store(_, let port): port
        default: nil
        }
        return await node.handle(request, from: port.map { DHTContact(key: sender.key, host: sender.host, port: $0) },
                                 observedHost: sender.host)
    }
}

struct SimTransport: DHTTransport {
    let me: DHTContact
    let network: SimNetwork

    func send(_ request: DHTMessage, to contact: DHTContact) async throws -> DHTMessage {
        try await network.deliver(request, to: contact, from: me)
    }
}
