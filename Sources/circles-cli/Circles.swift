import ArgumentParser
import Foundation
import CirclesCore
import CirclesKit
import CirclesNet
import CirclesCLISupport

@main
struct Circles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "circles",
        abstract: "A peer-to-peer social network built around Circles.",
        subcommands: [Init.self, WhoAmI.self, InviteCommand.self, ContactCommand.self, CircleCommand.self,
                      PostCommand.self, StreamCommand.self, Serve.self, SyncCommand.self, Peers.self,
                      PodCommand.self, RelayCommand.self]
    )
}

struct Global: ParsableArguments {
    @Option(help: "Data directory. Defaults to $CIRCLES_HOME or ~/.circles.")
    var home: String?

    var homeURL: URL { directoryURL(home, environment: "CIRCLES_HOME", default: ".circles") }

    func open() throws -> Account {
        do {
            return try Account.open(home: homeURL)
        } catch AccountError.notFound {
            throw ValidationError("No account in \(homeURL.path). Run `circles init --name <name>` first.")
        }
    }
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a new identity on this device.")
    @OptionGroup var global: Global
    @Option(help: "Your display name.") var name: String

    func run() async throws {
        let account = try Account.create(home: global.homeURL, displayName: name)
        print("Created \(name): \(account.user)")
        print("Share your invite with `circles invite`.")
    }
}

struct WhoAmI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "whoami", abstract: "Show this identity.")
    @OptionGroup var global: Global

    func run() async throws {
        let account = try global.open()
        print("\(await account.displayName)")
        print("  user:   \(account.user)")
        print("  device: \(account.deviceID)")
    }
}

struct InviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "invite", abstract: "Print an invite for others to add you.")
    @OptionGroup var global: Global

    func run() async throws {
        print(try await global.open().invite())
    }
}

struct ContactCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "contact", abstract: "Manage contacts.",
                                                    subcommands: [Add.self, List.self])

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a contact from their invite.")
        @OptionGroup var global: Global
        @Argument(help: "The invite text (circles-invite:…).") var invite: String
        @Option(help: "A local name for them (defaults to the name in the invite).") var name: String?

        func run() async throws {
            let contact = try await global.open().addContact(invite: invite, name: name)
            print("Added \(contact.name) (\(contact.user))")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List contacts.")
        @OptionGroup var global: Global

        func run() async throws {
            for contact in await (try global.open()).contacts {
                print("\(contact.name)\t\(contact.user)")
            }
        }
    }
}

struct CircleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "circle", abstract: "Manage your circles.",
                                                    subcommands: [Create.self, Add.self, Remove.self, List.self])

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a circle.")
        @OptionGroup var global: Global
        @Argument var name: String

        func run() async throws {
            try await global.open().createCircle(name)
            print("Created circle \(name)")
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add contacts to a circle.")
        @OptionGroup var global: Global
        @Argument var circle: String
        @Argument(help: "Contact names.") var contacts: [String]

        func run() async throws {
            let account = try global.open()
            var members: [UserID] = []
            for name in contacts { members.append(try await account.contact(named: name).user) }
            try await account.addToCircle(circle, members: members)
            print("Added \(contacts.joined(separator: ", ")) to \(circle)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove contacts from a circle (rotates its key).")
        @OptionGroup var global: Global
        @Argument var circle: String
        @Argument(help: "Contact names.") var contacts: [String]

        func run() async throws {
            let account = try global.open()
            var members: [UserID] = []
            for name in contacts { members.append(try await account.contact(named: name).user) }
            try await account.removeFromCircle(circle, members: members)
            print("Removed \(contacts.joined(separator: ", ")) from \(circle)")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your circles and their members.")
        @OptionGroup var global: Global

        func run() async throws {
            let account = try global.open()
            for circle in await account.circles {
                var names: [String] = []
                for member in circle.members { names.append(await account.name(of: member)) }
                print("\(circle.name) (\(circle.members.count)): \(names.joined(separator: ", "))")
            }
        }
    }
}

struct PostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "post", abstract: "Post to circles or to everyone.")
    @OptionGroup var global: Global
    @Argument var text: String
    @Option(name: .customLong("circle"), help: "A circle to share with (repeatable).") var circles: [String] = []
    @Flag(help: "Share with everyone.") var everyone = false

    func validate() throws {
        guard everyone != !circles.isEmpty else {
            throw ValidationError("Choose an audience: --everyone, or one or more --circle.")
        }
    }

    func run() async throws {
        try await global.open().post(RichText(plain: text), to: everyone ? .everyone : .circles(circles))
        print(everyone ? "Posted to everyone." : "Posted to \(circles.joined(separator: ", ")).")
    }
}

struct StreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stream", abstract: "Show posts you can read.")
    @OptionGroup var global: Global
    @Option(help: "How many posts to show.") var limit = 20

    func run() async throws {
        let items = try await global.open().stream()
        if items.isEmpty { print("Nothing here yet.") }
        for item in items.prefix(limit) {
            let date = Date(timeIntervalSince1970: Double(item.created.millis) / 1000)
            let audience = item.audience == .everyone ? "everyone" : "limited"
            print("\(item.authorName) · \(date.formatted(date: .abbreviated, time: .shortened)) · \(audience)")
            print("  \(item.body.plainText)\n")
        }
    }
}
