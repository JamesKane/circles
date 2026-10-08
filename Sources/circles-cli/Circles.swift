import ArgumentParser
import Foundation
import CirclesCore
import CirclesKit
import CirclesNet
import CirclesCLISupport
import CirclesPresentation

@main
struct Circles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "circles",
        abstract: "A peer-to-peer social network built around Circles.",
        subcommands: [Init.self, WhoAmI.self, InviteCommand.self, ContactCommand.self, CircleCommand.self,
                      PostCommand.self, StreamCommand.self, Serve.self, SyncCommand.self, Peers.self,
                      PodCommand.self, RelayCommand.self, CommentCommand.self, PlusOneCommand.self,
                      ReshareCommand.self, AttachmentCommand.self, CommunityCommand.self]
    )
}

struct Global: ParsableArguments {
    @Option(help: "Data directory. Defaults to $CIRCLES_HOME or ~/.circles.")
    var home: String?

    var homeURL: URL { directoryURL(home, environment: "CIRCLES_HOME", default: ".circles") }

    func open() async throws -> Account {
        do {
            return try await Account.open(home: homeURL)
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
        let account = try await Account.create(home: global.homeURL, displayName: name)
        print("Created \(name): \(account.user)")
        print("Share your invite with `circles invite`.")
    }
}

struct WhoAmI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "whoami", abstract: "Show this identity.")
    @OptionGroup var global: Global

    func run() async throws {
        let account = try await global.open()
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
            for contact in await (try await global.open()).contacts {
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
            let account = try await global.open()
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
            let account = try await global.open()
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
            let account = try await global.open()
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
    @Option(name: .customLong("attach"), help: "A file to attach (repeatable).") var attachments: [String] = []
    @Flag(help: "Don't allow comments.") var noComments = false
    @Flag(help: "Don't allow resharing.") var noReshares = false

    func validate() throws {
        guard everyone != !circles.isEmpty else {
            throw ValidationError("Choose an audience: --everyone, or one or more --circle.")
        }
    }

    func run() async throws {
        let files = try attachments.map { path in
            Attachment(data: Array(try Data(contentsOf: URL(fileURLWithPath: path))), mediaType: mediaType(for: path))
        }
        let id = try await global.open().post(
            RichText(plain: text), to: everyone ? .everyone : .circles(circles), attachments: files,
            replyPolicy: ReplyPolicy(commentsEnabled: !noComments, resharesEnabled: !noReshares)
        )
        print((everyone ? "Posted to everyone" : "Posted to \(circles.joined(separator: ", "))") + " (\(shortID(id))).")
    }
}

struct StreamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stream", abstract: "Show posts you can read, with comments and +1s.")
    @OptionGroup var global: Global
    @Option(help: "How many posts to show.") var limit = 20
    @Option(help: "Only posts by members of this circle.") var circle: String?

    func run() async throws {
        let account = try await global.open()
        let circle = self.circle, limit = self.limit
        // The CLI is one more backend over the shared screen models.
        let lines = try await Task { @MainActor in
            let model = StreamScreenModel(account: account)
            await model.perform(circle.map { .selectFilter(.circle($0)) } ?? .refresh)
            if case .failed(let reason) = model.state.phase { throw ValidationError(reason) }
            return model.state.cards.prefix(limit).flatMap(render)
        }.value
        print(lines.isEmpty ? "Nothing here yet." : lines.joined(separator: "\n"))
    }
}

func render(_ card: PostCard) -> [String] {
    var lines = ["\(card.authorName) · \(card.timestamp) · \(card.audienceLabel) · \(shortID(card.id))"]
    if !card.body.plainText.isEmpty { lines.append("  \(card.body.plainText)") }
    if let original = card.reshared {
        lines.append("  ↻ \(original.authorName) · \(original.timestamp)")
        lines.append("    \(original.body.plainText)")
    }
    for (index, attachment) in card.attachments.enumerated() {
        lines.append("  📎 [\(index + 1)] \(attachment.mediaType), \(attachment.sizeLabel)")
    }
    var counts: [String] = []
    if card.plusOnes > 0 { counts.append("+\(card.plusOnes)" + (card.plusOnedByMe ? " (incl. you)" : "")) }
    if !card.comments.isEmpty { counts.append("\(card.comments.count) comment" + (card.comments.count == 1 ? "" : "s")) }
    if !card.canComment { counts.append("comments off") }
    if !counts.isEmpty { lines.append("  " + counts.joined(separator: " · ")) }
    for comment in card.comments {
        lines.append("    \(comment.authorName): \(comment.body.plainText)" + (comment.pending ? "  (pending approval)" : ""))
    }
    lines.append("")
    return lines
}

/// A short, copyable post ID: the first characters of its ContentID.
func shortID(_ id: ContentID) -> String {
    String(id.description.dropFirst(5).prefix(10))
}

/// Finds a readable post by a prefix of its short ID.
func findPost(_ prefix: String, in account: Account) async throws -> StreamItem {
    let matches = try await account.stream().filter { shortID($0.id).hasPrefix(prefix) || $0.id.description.hasPrefix(prefix) }
    guard matches.count == 1, let match = matches.first else {
        throw ValidationError(matches.isEmpty ? "No post matches \(prefix)." : "\(prefix) matches several posts; use more characters.")
    }
    return match
}

func mediaType(for path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "jpg", "jpeg": "image/jpeg"
    case "png": "image/png"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "heic": "image/heic"
    case "mp4": "video/mp4"
    case "txt": "text/plain"
    default: "application/octet-stream"
    }
}

struct CommentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "comment", abstract: "Comment on a post (the author approves it into the thread).")
    @OptionGroup var global: Global
    @Argument(help: "The post's ID, as shown by `circles stream`.") var post: String
    @Argument var text: String

    func run() async throws {
        let account = try await global.open()
        let item = try await findPost(post, in: account)
        try await account.comment(RichText(plain: text), on: item.reference)
        print(item.author == account.user ? "Commented." : "Comment sent to \(item.authorName); it appears for others once they sync and approve it.")
    }
}

struct PlusOneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plusone", abstract: "+1 a post, or take it back with --undo.")
    @OptionGroup var global: Global
    @Argument var post: String
    @Flag(help: "Take back your +1.") var undo = false

    func run() async throws {
        let account = try await global.open()
        let item = try await findPost(post, in: account)
        try await account.setPlusOne(!undo, on: item.reference)
        print(undo ? "Took back your +1." : "+1'd \(item.authorName)'s post.")
    }
}

struct ReshareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reshare", abstract: "Reshare a public post to everyone.")
    @OptionGroup var global: Global
    @Argument var post: String
    @Option(help: "Your comment on it.") var comment = ""

    func run() async throws {
        let account = try await global.open()
        let item = try await findPost(post, in: account)
        try await account.reshare(item.reference, comment: RichText(plain: comment), to: .everyone)
        print("Reshared \(item.authorName)'s post.")
    }
}

struct AttachmentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attachment", abstract: "Save a post's attachment to a file.")
    @OptionGroup var global: Global
    @Argument var post: String
    @Argument(help: "Which attachment (1-based).") var index = 1
    @Option(help: "Where to save it.") var output: String

    func run() async throws {
        let account = try await global.open()
        let item = try await findPost(post, in: account)
        guard item.attachments.indices.contains(index - 1) else { throw ValidationError("That post has \(item.attachments.count) attachment(s).") }
        guard let data = try await account.attachmentData(item.attachments[index - 1]) else {
            throw ValidationError("The attachment hasn't synced yet. Try `circles sync`.")
        }
        try Data(data).write(to: URL(fileURLWithPath: output))
        print("Saved \(data.count) bytes to \(output).")
    }
}
