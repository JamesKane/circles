import Foundation
import CirclesCore
import CirclesCrypto
import CirclesSync
import CirclesNet
import CirclesStorage
import CirclesDHT

/// How a device takes part in the network, saved with the account.
public struct NodePreferences: Sendable, Codable, Equatable {
    public var advertiseOnLocalNetwork = true
    /// Ask the router to forward the port (PCP, NAT-PMP or UPnP-IGD).
    public var mapRouterPort = false
    /// With port mapping, list the public address in our identity document.
    /// Reveals it to everyone who receives the document.
    public var publishPublicAddress = false
    /// 0 picks a free port each time.
    public var port = 0
    public var syncIntervalSeconds = 60
    /// Take part in the DHT: publish our identity document, and look up
    /// contacts we can't otherwise reach.
    public var useDHT = true
    /// Extra DHT nodes to join through (`circles-dht-node:` texts), besides
    /// our pods and our contacts' pods.
    public var dhtBootstrap: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case advertiseOnLocalNetwork, mapRouterPort, publishPublicAddress, port, syncIntervalSeconds, useDHT, dhtBootstrap
    }

    /// Fields added later are optional, so older preference files still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NodePreferences()
        advertiseOnLocalNetwork = try container.decodeIfPresent(Bool.self, forKey: .advertiseOnLocalNetwork) ?? defaults.advertiseOnLocalNetwork
        mapRouterPort = try container.decodeIfPresent(Bool.self, forKey: .mapRouterPort) ?? defaults.mapRouterPort
        publishPublicAddress = try container.decodeIfPresent(Bool.self, forKey: .publishPublicAddress) ?? defaults.publishPublicAddress
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        syncIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds) ?? defaults.syncIntervalSeconds
        useDHT = try container.decodeIfPresent(Bool.self, forKey: .useDHT) ?? defaults.useDHT
        dhtBootstrap = try container.decodeIfPresent([String].self, forKey: .dhtBootstrap) ?? defaults.dhtBootstrap
    }
}

/// Something the node did, for logs and status displays.
public enum NodeEvent: Sendable, Equatable {
    public enum Direction: String, Sendable { case incoming, outgoing }

    case listening(port: Int)
    case advertising
    case advertisingUnavailable(String)
    case reachableViaRelay(String)
    case relayUnavailable(String, reason: String)
    case portMapped(external: String)
    case portMappingRemoved
    case portMappingUnavailable(String)
    /// `received` counts new log entries; nonzero means there's new content.
    case synced(peer: String, direction: Direction, received: Int, sent: Int)
    case syncFailed(route: String, reason: String)
    case syncRoundFinished
    /// We (re)joined the DHT: how many nodes we know, and how many stored
    /// our identity document (and our communities').
    case dhtRefreshed(nodes: Int, stored: Int)
}

/// Keeps a device online (docs/DESIGN.md §5.1, §7): accepts syncs, advertises
/// on the local network, holds reservations on our relays, optionally maps
/// the router port, and syncs with everyone reachable on an interval. Used
/// by `circles serve` and by the apps.
public struct NodeService: Sendable {
    public let account: Account

    public init(account: Account) {
        self.account = account
    }

    /// Runs until cancelled. `onEvent` is called for everything notable.
    public func run(_ preferences: NodePreferences, onEvent: @escaping @Sendable (NodeEvent) async -> Void) async throws {
        let account = self.account
        let listener = try await account.makeListener(port: preferences.port)
        await onEvent(.listening(port: listener.port))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await listener.run { session in
                    guard let report = try await account.respond(over: session) else { return } // a DHT request
                    await onEvent(.synced(peer: await Self.name(of: report.peer, in: account), direction: .incoming,
                                          received: report.received.values.reduce(0, +), sent: report.sent))
                }
            }
            if preferences.advertiseOnLocalNetwork {
                group.addTask {
                    do {
                        await onEvent(.advertising)
                        try await MulticastDNS.advertise(await account.advertisement(port: listener.port))
                    } catch is CancellationError {
                    } catch {
                        await onEvent(.advertisingUnavailable(String(describing: error)))
                    }
                }
            }
            for relay in await account.endpoints.relays {
                group.addTask { await Self.holdReservation(on: relay, account: account, onEvent: onEvent) }
            }
            if preferences.mapRouterPort {
                let publish = preferences.publishPublicAddress
                group.addTask {
                    await PortMapper.keepPortMapped(tcpPort: listener.port, onChange: { mapping in
                        if let mapping {
                            await onEvent(.portMapped(external: "\(mapping.externalAddress ?? "?"):\(mapping.externalPort)"))
                        } else {
                            await onEvent(.portMappingRemoved)
                        }
                        if publish {
                            try? await account.setDirectEndpoint(host: mapping?.externalAddress, port: mapping?.externalPort ?? 0)
                        }
                        // Only a mapped port is reachable from outside, so only
                        // then do we offer ourselves as a DHT node.
                        await account.dht.setListenPort(mapping.map { UInt16($0.externalPort) })
                    }, onError: { error in
                        await onEvent(.portMappingUnavailable(String(describing: error)))
                    })
                }
            }
            if preferences.useDHT {
                group.addTask {
                    while true {
                        let (nodes, stored) = await account.maintainDHT()
                        await onEvent(.dhtRefreshed(nodes: nodes, stored: stored))
                        try await Task.sleep(for: .seconds(Self.dhtRefreshSeconds))
                    }
                }
            }
            group.addTask {
                while true {
                    await Self.syncRound(account: account, onEvent: onEvent)
                    try await Task.sleep(for: .seconds(max(5, preferences.syncIntervalSeconds)))
                }
            }
            try await group.waitForAll()
        }
    }

    /// How often to rejoin the DHT and republish. Records live 24 hours.
    public static let dhtRefreshSeconds = 30 * 60

    /// Syncs once with everyone reachable, reporting each attempt.
    public static func syncRound(account: Account, onEvent: @escaping @Sendable (NodeEvent) async -> Void) async {
        for attempt in await account.syncAll() {
            switch attempt.result {
            case .success(let report):
                await onEvent(.synced(peer: attempt.route, direction: .outgoing,
                                      received: report.received.values.reduce(0, +), sent: report.sent))
            case .failure(let error):
                await onEvent(.syncFailed(route: attempt.route, reason: String(describing: error)))
            }
        }
        await onEvent(.syncRoundFinished)
    }

    private static func holdReservation(on relay: RelayEndpoint, account: Account, onEvent: @escaping @Sendable (NodeEvent) async -> Void) async {
        let name = "\(relay.host):\(relay.port)"
        while !Task.isCancelled {
            do {
                try await account.serveViaRelay(relay, onReserved: {
                    Task { await onEvent(.reachableViaRelay(name)) }
                }, onSync: { report in
                    await onEvent(.synced(peer: await Self.name(of: report.peer, in: account) + " via relay", direction: .incoming,
                                          received: report.received.values.reduce(0, +), sent: report.sent))
                })
            } catch is CancellationError {
                return
            } catch {
                await onEvent(.relayUnavailable(name, reason: String(describing: error)))
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private static func name(of user: UserID?, in account: Account) async -> String {
        guard let user else { return "unknown peer" }
        // Peers who aren't contacts (community members) by their own name.
        return await account.displayName(of: user, identity: try? await account.store.verifiedIdentity(for: user))
    }
}

extension Account {
    public func preferences() throws -> NodePreferences {
        try files.load(NodePreferences.self, from: files.preferences) ?? NodePreferences()
    }

    public func setPreferences(_ preferences: NodePreferences) throws {
        try files.save(preferences, to: files.preferences)
    }
}
