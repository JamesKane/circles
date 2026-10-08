import ArgumentParser
import Foundation
import CirclesCore
import CirclesCrypto
import CirclesSync
import CirclesNet
import CirclesKit
import CirclesCLISupport

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: """
        Accept syncs, advertise on the local network, keep reservations on your relays, \
        and sync with everyone reachable every interval.
        """)
    @OptionGroup var global: Global
    @Option(help: "TCP port to listen on (0 picks one).") var port = 0
    @Option(help: "Seconds between sync rounds.") var interval = 60
    @Flag(help: "Ask the router to forward the port (PCP, NAT-PMP or UPnP-IGD).") var mapPort = false
    @Flag(help: "With --map-port, publish the public address in your identity document. Reveals it to everyone who gets your identity document.")
    var publishDirect = false
    @Flag(help: "Don't advertise on the local network (mDNS).") var noAdvertise = false

    func run() async throws {
        let account = try await global.open()
        // Flags override the saved preferences for this run.
        var preferences = try await account.preferences()
        if port != 0 { preferences.port = port }
        preferences.syncIntervalSeconds = interval
        if mapPort { preferences.mapRouterPort = true }
        if publishDirect { preferences.publishPublicAddress = true }
        if noAdvertise { preferences.advertiseOnLocalNetwork = false }
        let name = await account.displayName
        let options = preferences
        try await runUntilInterrupted {
            try await NodeService(account: account).run(options) { event in
                if let line = describe(event, name: name) { say(line) }
            }
        }
    }
}

/// One log line per node event (nil for ones not worth a line).
func describe(_ event: NodeEvent, name: String) -> String? {
    switch event {
    case .listening(let port): "Serving \(name) on port \(port). Ctrl-C to stop."
    case .advertising: nil
    case .advertisingUnavailable(let reason): "mDNS advertising unavailable (\(reason))."
    case .reachableViaRelay(let relay): "Reachable through relay \(relay)."
    case .relayUnavailable(let relay, let reason): "Relay \(relay) unavailable (\(reason)); retrying in 30s."
    case .portMapped(let external): "Port mapped: \(external)"
    case .portMappingRemoved: "Port mapping removed."
    case .portMappingUnavailable(let reason): "Port mapping unavailable: \(reason)"
    case .synced(let peer, let direction, let received, let sent): "Synced with \(peer) (\(direction.rawValue)): received \(received), sent \(sent)"
    case .syncFailed(let route, let reason): "Could not sync with \(route): \(reason)"
    case .syncRoundFinished: nil
    }
}

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync once with everyone reachable (local network, pods, relays), or with one peer."
    )
    @OptionGroup var global: Global
    @Option(help: "Sync only with host:port.") var peer: String?

    func run() async throws {
        let account = try await global.open()
        if let peer {
            guard let colon = peer.lastIndex(of: ":"), let port = Int(peer[peer.index(after: colon)...]) else {
                throw ValidationError("--peer must be host:port")
            }
            let report = try await account.sync(host: String(peer[..<colon]), port: port)
            say(describe(report, peerName: await report.peer.asyncMap { await account.name(of: $0) } ?? peer, direction: "outgoing"))
        } else {
            await printAttempts(await account.syncAll(), account: account)
        }
    }
}

struct Peers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Circles nodes on the local network.")
    @Option(help: "Seconds to listen.") var timeout = 2

    func run() async throws {
        for peer in try await MulticastDNS.browse(timeout: .seconds(timeout)) {
            say("\(peer.instanceName)\t\(peer.host):\(peer.port)\t\(peer.user.map { "\($0)" } ?? "?")")
        }
    }
}

struct PodCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pod", abstract: "Manage your pods.",
                                                    subcommands: [Add.self, List.self])

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Certify a pod from its pairing code; prints the bundle to give it (`circles-pod pair`)."
        )
        @OptionGroup var global: Global
        @Argument(help: "The pod's pairing code (circles-pod:…).") var code: String

        func run() async throws {
            let pairing = try PodPairingCode(text: code)
            let bundle = try await global.open().addPod(pairing)
            say("Certified pod at \(pairing.host):\(pairing.port). On the pod, run:")
            say("  circles-pod pair \(try bundle.text)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your pods.")
        @OptionGroup var global: Global

        func run() async throws {
            for pod in await (try await global.open()).endpoints.pods {
                say("\(pod.host):\(pod.port)\t\(pod.device)")
            }
        }
    }
}

struct RelayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "relay", abstract: "Manage the relays you're reachable through.",
                                                    subcommands: [Add.self, List.self])

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a relay (host:port#key, as printed by circles-relay).")
        @OptionGroup var global: Global
        @Argument var address: String

        func run() async throws {
            let relay = try RelayIdentity.parse(address: address)
            try await global.open().addRelay(relay)
            say("Added relay \(relay.host):\(relay.port). `circles serve` keeps a reservation on it.")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your relays.")
        @OptionGroup var global: Global

        func run() async throws {
            for relay in await (try await global.open()).endpoints.relays {
                say("\(relay.host):\(relay.port)")
            }
        }
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}
