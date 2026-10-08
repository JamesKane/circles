import ArgumentParser
import Foundation
import CirclesCore
import CirclesKit
import CirclesNet

@main
struct Circles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "circles",
        abstract: "A peer-to-peer social network built around Circles.",
        subcommands: [Init.self, WhoAmI.self, InviteCommand.self, ContactCommand.self, CircleCommand.self,
                      PostCommand.self, StreamCommand.self, Serve.self, SyncCommand.self, Peers.self]
    )
}

struct Global: ParsableArguments {
    @Option(help: "Data directory. Defaults to $CIRCLES_HOME or ~/.circles.")
    var home: String?

    var homeURL: URL {
        if let home { return URL(fileURLWithPath: (home as NSString).expandingTildeInPath) }
        if let env = ProcessInfo.processInfo.environment["CIRCLES_HOME"] { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".circles")
    }

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
        print("Created \(name): \(await account.user)")
        print("Share your invite with `circles invite`.")
    }
}

struct WhoAmI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "whoami", abstract: "Show this identity.")
    @OptionGroup var global: Global

    func run() async throws {
        let account = try global.open()
        print("\(await account.displayName)")
        print("  user:   \(await account.user)")
        print("  device: \(await account.deviceID)")
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

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Accept syncs from contacts, advertise on the local network, and sync with contacts found there."
    )
    @OptionGroup var global: Global
    @Option(help: "TCP port to listen on (0 picks one).") var port = 0
    @Option(help: "Seconds between discovery rounds.") var interval = 30

    func run() async throws {
        let work = Task { try await serve() }
        #if !os(Windows)
        // Ctrl-C or SIGTERM cancels the work, so the mDNS goodbye goes out
        // and connections close cleanly.
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { work.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        #endif
        if case .failure(let error) = await work.result, !(error is CancellationError) {
            throw error
        }
        say("Stopped.")
    }

    func serve() async throws {
        let account = try global.open()
        let listener = try await NoiseListener(port: port, handshake: await account.makeHandshake(role: .responder))
        let advertisement = await account.advertisement(port: listener.port)
        say("Serving \(await account.displayName) on port \(listener.port). Ctrl-C to stop.")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await listener.run { session in
                    let report = try await account.syncEngine().run(over: session)
                    try await account.absorbKeyGrants()
                    await printReport(report, account: account, direction: "incoming")
                }
            }
            group.addTask {
                do {
                    try await MulticastDNS.advertise(advertisement)
                } catch {
                    say("mDNS advertising unavailable (\(error)); peers can still connect with --peer.")
                }
            }
            group.addTask {
                while true {
                    try await syncWithDiscoveredContacts(account)
                    try await Task.sleep(for: .seconds(interval))
                }
            }
            try await group.waitForAll()
        }
    }
}

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync", abstract: "Sync once with contacts on the local network, or with one peer.")
    @OptionGroup var global: Global
    @Option(help: "Sync with host:port instead of discovering peers.") var peer: String?

    func run() async throws {
        let account = try global.open()
        if let peer {
            guard let colon = peer.lastIndex(of: ":"), let port = Int(peer[peer.index(after: colon)...]) else {
                throw ValidationError("--peer must be host:port")
            }
            await printReport(try await account.sync(host: String(peer[..<colon]), port: port), account: account, direction: "outgoing")
        } else if try await syncWithDiscoveredContacts(account) == 0 {
            print("No contacts found on the local network.")
        }
    }
}

struct Peers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Circles nodes on the local network.")
    @Option(help: "Seconds to listen.") var timeout = 2

    func run() async throws {
        for peer in try await MulticastDNS.browse(timeout: .seconds(timeout)) {
            print("\(peer.instanceName)\t\(peer.host):\(peer.port)\t\(peer.user.map { "\($0)" } ?? "?")")
        }
    }
}

/// Browses the local network and syncs with each contact found. Returns how
/// many peers were synced with.
@discardableResult
func syncWithDiscoveredContacts(_ account: Account) async throws -> Int {
    try await account.reload()
    let contacts = Set(await account.contacts.map(\.user))
    let me = await account.deviceID
    var synced = 0
    for peer in try await MulticastDNS.browse() where peer.device != me {
        guard let user = peer.user, contacts.contains(user) else { continue }
        do {
            await printReport(try await account.sync(host: peer.host, port: peer.port), account: account, direction: "outgoing")
            synced += 1
        } catch {
            say("Sync with \(await account.name(of: user)) at \(peer.host):\(peer.port) failed: \(error)")
        }
    }
    return synced
}

func printReport(_ report: SyncReport, account: Account, direction: String) async {
    let peer = report.peer.map { "\($0)" } ?? "?"
    var peerName = peer
    if let user = report.peer { peerName = await account.name(of: user) }
    let received = report.received.values.reduce(0, +)
    say("Synced with \(peerName) (\(direction)): received \(received), sent \(report.sent)"
          + (report.rejected.isEmpty ? "" : ", rejected \(report.rejected.count)"))
}

import CirclesSync
import CirclesCrypto

/// Writes a line immediately, even when stdout is redirected to a file, so
/// a long-running `serve` log is never lost in a buffer.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
