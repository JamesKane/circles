import ArgumentParser
import Foundation
import CirclesKit
import CirclesPush

extension PushPlatform: ExpressibleByArgument {
    public init?(argument: String) { self.init(name: argument) }
}

struct PushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push", abstract: "Wake-ups for this device through a push relay (for phones).",
        subcommands: [Register.self, Status.self, Unregister.self]
    )

    struct Register: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register this device's push token with a push relay.")
        @OptionGroup var global: Global
        @Argument(help: "The relay's address (host:port#key), printed by circles-push.") var relay: String
        @Option(help: "apns, fcm or test.") var platform: PushPlatform
        @Option(help: "The device's push token from the platform.") var token: String
        @Option(help: "APNs: the app's bundle ID.") var topic: String?

        func run() async throws {
            let target = try await global.open().registerPush(relay: relay, platform: platform, token: token, topic: topic)
            print("Registered with \(target.host):\(target.port). Your pods learn of it at your next sync with them.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show this device's push registrations.")
        @OptionGroup var global: Global

        func run() async throws {
            let targets = await (try await global.open()).pushTargets()
            if targets.isEmpty { print("Not registered with any push relay."); return }
            for target in targets { print("\(target.host):\(target.port)") }
        }
    }

    struct Unregister: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove this device's push registrations.")
        @OptionGroup var global: Global

        func run() async throws {
            try await global.open().unregisterPush()
            print("Unregistered.")
        }
    }
}
