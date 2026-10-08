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
        let (port, interval, mapPort, publishDirect, advertise) = (self.port, self.interval, self.mapPort, self.publishDirect, !self.noAdvertise)
        try await runUntilInterrupted {
            let listener = try await NoiseListener(port: port, handshake: await account.makeHandshake(role: .responder))
            say("Serving \(await account.displayName) on port \(listener.port). Ctrl-C to stop.")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await listener.run { session in
                        let report = try await account.syncEngine().run(over: session)
                        try await account.absorbKeyGrants()
                        let name = await report.peer.asyncMap { await account.name(of: $0) } ?? "?"
                        say(describe(report, peerName: name, direction: "incoming"))
                    }
                }
                if advertise { group.addTask {
                    do {
                        try await MulticastDNS.advertise(await account.advertisement(port: listener.port))
                    } catch is CancellationError {
                    } catch {
                        say("mDNS advertising unavailable (\(error)).")
                    }
                } }
                for relay in await account.endpoints.relays {
                    group.addTask { await holdReservation(on: relay, for: account) }
                }
                if mapPort {
                    group.addTask {
                        await PortMapper.keepPortMapped(tcpPort: listener.port, onChange: { mapping in
                            if let mapping {
                                say("Port mapped with \(mapping.method.rawValue): \(mapping.externalAddress ?? "?"):\(mapping.externalPort)")
                            } else {
                                say("Port mapping removed.")
                            }
                            guard publishDirect else { return }
                            try? await account.setDirectEndpoint(host: mapping?.externalAddress, port: mapping?.externalPort ?? 0)
                        }, onError: { error in
                            say("Port mapping unavailable: \(error)")
                        })
                    }
                }
                group.addTask {
                    while true {
                        await printAttempts(await account.syncAll(), account: account)
                        try await Task.sleep(for: .seconds(interval))
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}

/// Keeps a reservation on a relay, reconnecting after failures.
func holdReservation(on relay: RelayEndpoint, for account: Account) async {
    while !Task.isCancelled {
        do {
            try await account.serveViaRelay(relay, onReserved: {
                say("Reachable through relay \(relay.host):\(relay.port).")
            }, onSync: { report in
                say(describe(report, peerName: "a peer via relay", direction: "incoming"))
            })
        } catch is CancellationError {
            return
        } catch {
            say("Relay \(relay.host):\(relay.port) unavailable (\(error)); retrying in 30s.")
        }
        try? await Task.sleep(for: .seconds(30))
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
