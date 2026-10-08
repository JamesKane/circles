import ArgumentParser
import Foundation
import CirclesNet
import CirclesKit
import CirclesDHT
import CirclesCLISupport

@main
struct CirclesRelay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "circles-relay",
        abstract: "A public relay that lets Circles devices behind NATs reach each other. It sees only ciphertext."
    )

    @Option(help: "Data directory for the relay key. Defaults to $CIRCLES_RELAY_HOME or ~/.circles-relay.") var home: String?
    @Option(help: "Address to bind.") var bind = "0.0.0.0"
    @Option(help: "TCP port to listen on.") var port = 7466
    @Option(help: "The public host name or address to print in the relay address.") var publicHost: String?
    @Option(help: "Also run a DHT bootstrap node on this TCP port (same key).") var dhtPort: Int?
    @Option(name: .customLong("dht-bootstrap"), help: "Another DHT node to join through (circles-dht-node:…), repeatable.")
    var dhtBootstrap: [String] = []

    func run() async throws {
        let directory = directoryURL(home, environment: "CIRCLES_RELAY_HOME", default: ".circles-relay")
        let identity = try RelayIdentity(home: directory)
        let (bind, port, publicHost, dhtPort) = (self.bind, self.port, self.publicHost, self.dhtPort)
        let seeds = try dhtBootstrap.map { try DHTNodeText.contact(from: $0) }
        try await runUntilInterrupted {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let relay = try await RelayServer(host: bind, port: port, handshake: identity.makeHandshake())
                say("Relay listening on \(bind):\(relay.port). Users add it with:")
                say("  circles relay add \(identity.address(host: publicHost ?? bind, port: relay.port))")
                group.addTask { try await relay.run() }
                if let dhtPort {
                    let dht = try await DHTServer(home: directory, host: bind, port: dhtPort)
                    let text = try DHTNodeText.text(for: DHTContact(key: dht.node.key, host: publicHost ?? bind, port: UInt16(dht.port)))
                    say("DHT node listening on \(bind):\(dht.port). Others join through it with:")
                    say("  circles dht bootstrap add \(text)")
                    group.addTask {
                        try await dht.run(seeds: seeds) { nodes in say("DHT: \(nodes) node\(nodes == 1 ? "" : "s") known.") }
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
