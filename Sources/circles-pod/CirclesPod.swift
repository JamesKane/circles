import ArgumentParser
import Foundation
import CirclesCore
import CirclesSync
import CirclesCrypto
import CirclesStorage
import CirclesNet
import CirclesKit
import CirclesDHT
import CirclesCLISupport

@main
struct CirclesPod: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "circles-pod",
        abstract: "An always-on node that stores and forwards your encrypted posts and your contacts'.",
        subcommands: [Init.self, Pair.self, Serve.self, Status.self]
    )
}

struct PodGlobal: ParsableArguments {
    @Option(help: "Data directory. Defaults to $CIRCLES_POD_HOME or ~/.circles-pod.")
    var home: String?

    var homeURL: URL { directoryURL(home, environment: "CIRCLES_POD_HOME", default: ".circles-pod") }

    func open() async throws -> PodNode {
        do {
            return try await PodNode.open(home: homeURL)
        } catch AccountError.notFound {
            throw ValidationError("No pod in \(homeURL.path). Run `circles-pod init` first.")
        }
    }
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create the pod's keys and print its pairing code.")
    @OptionGroup var global: PodGlobal
    @Option(help: "The host name or address others will reach this pod at.") var host: String
    @Option(help: "The TCP port the pod will listen on.") var port: UInt16 = 7465

    func run() async throws {
        let (_, code) = try await PodNode.create(home: global.homeURL, host: host, port: port)
        say("Pod created. On your device, run:")
        say("  circles pod add \(try code.text)")
    }
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Accept the bundle printed by `circles pod add`.")
    @OptionGroup var global: PodGlobal
    @Argument var bundle: String

    func run() async throws {
        let owner = try await global.open().pair(try PodBundle(text: bundle))
        say("Paired with \(owner). Start the pod with `circles-pod serve`, then run `circles sync` on your device.")
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve the owner and their contacts.")
    @OptionGroup var global: PodGlobal
    @Flag(help: "Ask the router to forward the port (PCP, NAT-PMP or UPnP-IGD).") var mapPort = false
    @Option(name: .customLong("dht-bootstrap"), help: "A DHT node to join through (circles-dht-node:…), repeatable.")
    var dhtBootstrap: [String] = []

    func run() async throws {
        let pod = try await global.open()
        guard let owner = await pod.owner else { throw ValidationError("Not paired yet. Run `circles-pod pair`.") }
        let mapPort = self.mapPort, dhtBootstrap = self.dhtBootstrap
        try await runUntilInterrupted {
            let listener = try await NoiseListener(port: Int(await pod.port), handshake: await pod.makeHandshake(role: .responder))
            say("Pod for \(owner) listening on port \(listener.port). Ctrl-C to stop.")
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await listener.run { session in
                        guard let report = try await pod.respond(over: session) else { return } // a DHT request
                        let peer = report.peer.map { $0 == owner ? "owner" : "contact \(String("\($0)".prefix(20)))…" } ?? "?"
                        say(describe(report, peerName: peer, direction: "incoming"))
                    }
                }
                let seeds = try dhtBootstrap.map { try DHTNodeText.contact(from: $0) }
                group.addTask {
                    say("DHT node: \(try DHTNodeText.text(for: DHTContact(key: pod.agreementKey, host: await pod.host, port: await pod.port)))")
                    while true {
                        let (nodes, stored) = await pod.maintainDHT(seeds: seeds)
                        say("DHT: \(nodes) node\(nodes == 1 ? "" : "s") known; owner's identity stored on \(stored).")
                        try await Task.sleep(for: .seconds(NodeService.dhtRefreshSeconds))
                    }
                }
                if mapPort {
                    group.addTask {
                        await PortMapper.keepPortMapped(tcpPort: listener.port, onChange: { mapping in
                            say(mapping.map { "Port mapped with \($0.method.rawValue): \($0.externalAddress ?? "?"):\($0.externalPort)" }
                                ?? "Port mapping removed.")
                        }, onError: { say("Port mapping unavailable: \($0)") })
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the pod's owner, address and configuration.")
    @OptionGroup var global: PodGlobal

    func run() async throws {
        let pod = try await global.open()
        say("device:   \(pod.deviceID)")
        say("address:  \(await pod.host):\(await pod.port)")
        say("owner:    \(await pod.owner.map { "\($0)" } ?? "not paired")")
        say("contacts: \(await pod.config?.contacts.count ?? 0) (configured by the owner on sync)")
        for author in try await pod.store.authors() {
            let entries = try await pod.store.frontier(author: author).sequences.values.reduce(0, +)
            say("  \(String("\(author)".prefix(28)))…  \(entries) entries")
        }
    }
}
