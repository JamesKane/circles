import ArgumentParser
import Foundation
import CirclesNet
import CirclesKit
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

    func run() async throws {
        let identity = try RelayIdentity(home: directoryURL(home, environment: "CIRCLES_RELAY_HOME", default: ".circles-relay"))
        let (bind, port, publicHost) = (self.bind, self.port, self.publicHost)
        try await runUntilInterrupted {
            let relay = try await RelayServer(host: bind, port: port, handshake: identity.makeHandshake())
            say("Relay listening on \(bind):\(relay.port). Users add it with:")
            say("  circles relay add \(identity.address(host: publicHost ?? bind, port: relay.port))")
            try await relay.run()
        }
    }
}
