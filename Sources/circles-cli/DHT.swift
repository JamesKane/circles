import ArgumentParser
import Foundation
import CirclesCore
import CirclesKit
import CirclesDHT
import CirclesCrypto

struct DHTCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dht", abstract: "The DHT, where people find each other's current addresses.",
        subcommands: [Status.self, Refresh.self, Lookup.self, Bootstrap.self]
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show DHT settings and the nodes known from the last refresh.")
        @OptionGroup var global: Global

        func run() async throws {
            let account = try await global.open()
            let preferences = try await account.preferences()
            print("DHT: " + (preferences.useDHT ? "on" : "off (`circles serve` won't publish or look up)"))
            print("Bootstrap nodes: \(preferences.dhtBootstrap.count) configured, plus your pods and your contacts' pods.")
            let seeds = await account.dhtSeeds()
            print("Would join through \(seeds.count) node\(seeds.count == 1 ? "" : "s").")
        }
    }

    struct Refresh: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Join the DHT now and publish your identity document.")
        @OptionGroup var global: Global

        func run() async throws {
            let (nodes, stored) = await (try await global.open()).maintainDHT()
            print(nodes == 0 ? "No DHT nodes reachable. Add one with `circles dht bootstrap add`, or add a pod."
                             : "Know \(nodes) node\(nodes == 1 ? "" : "s"); your identity is stored on \(stored).")
        }
    }

    struct Lookup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Look someone up by user ID.")
        @OptionGroup var global: Global
        @Argument(help: "A user ID (circles:…).") var user: String

        func run() async throws {
            guard let id = UserID(user) else { throw ValidationError("That isn't a user ID.") }
            let account = try await global.open()
            _ = await account.dht.bootstrap(await account.dhtSeeds())
            guard let identity = try await account.lookUp(id) else { print("Not found."); return }
            print("\(identity.document.displayName ?? "(no name)") · identity version \(identity.version)")
            let endpoints = identity.endpoints
            for pod in endpoints.pods { print("  pod \(pod.host):\(pod.port)") }
            for direct in endpoints.direct { print("  direct \(direct.host):\(direct.port)") }
            for relay in endpoints.relays { print("  relay \(relay.host):\(relay.port)") }
            if endpoints.pods.isEmpty && endpoints.direct.isEmpty && endpoints.relays.isEmpty {
                print("  no addresses published (reachable on their local network only)")
            }
        }
    }

    struct Bootstrap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage extra DHT nodes to join through.",
                                                        subcommands: [Add.self, Remove.self, List.self])

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Add a node (circles-dht-node:…, printed by `circles-relay --dht-port` and `circles-pod serve`).")
            @OptionGroup var global: Global
            @Argument var node: String

            func run() async throws {
                let contact = try DHTNodeText.contact(from: node)
                let account = try await global.open()
                var preferences = try await account.preferences()
                preferences.dhtBootstrap.removeAll { (try? DHTNodeText.contact(from: $0))?.key == contact.key }
                preferences.dhtBootstrap.append(node.trimmingCharacters(in: .whitespacesAndNewlines))
                try await account.setPreferences(preferences)
                print("Added \(contact.host):\(contact.port).")
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Remove a node by host[:port].")
            @OptionGroup var global: Global
            @Argument var address: String

            func run() async throws {
                let account = try await global.open()
                var preferences = try await account.preferences()
                let before = preferences.dhtBootstrap.count
                preferences.dhtBootstrap.removeAll { text in
                    guard let contact = try? DHTNodeText.contact(from: text) else { return false }
                    return address == contact.host || address == "\(contact.host):\(contact.port)"
                }
                try await account.setPreferences(preferences)
                print(before == preferences.dhtBootstrap.count ? "No bootstrap node at \(address)." : "Removed.")
            }
        }

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "List configured bootstrap nodes.")
            @OptionGroup var global: Global

            func run() async throws {
                for text in try await global.open().preferences().dhtBootstrap {
                    if let contact = try? DHTNodeText.contact(from: text) { print("\(contact.host):\(contact.port)") }
                }
            }
        }
    }
}
