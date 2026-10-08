import ArgumentParser
import Foundation
import CirclesCore
import CirclesKit
import CirclesSync
import CirclesPresentation

extension CommunityVisibility: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument {
        case "public": self = .public
        case "private": self = .private
        default: return nil
        }
    }
}

extension JoinPolicy: ExpressibleByArgument {
    public init?(argument: String) {
        switch argument {
        case "open": self = .open
        case "approval": self = .approval
        case "invite-only", "invite": self = .inviteOnly
        default: return nil
        }
    }
}

/// Finds one of our communities by a prefix of its name (case-insensitive).
func findCommunity(_ name: String, in account: Account) async throws -> CommunitySummary {
    let all = try await account.communities()
    if let exact = all.first(where: { $0.name.lowercased() == name.lowercased() }) { return exact }
    let matches = all.filter { $0.name.lowercased().hasPrefix(name.lowercased()) }
    guard matches.count == 1, let match = matches.first else {
        throw ValidationError(matches.isEmpty ? "No community matches \(name). See `circles community list`."
                                              : "\(name) matches several communities; use more of the name.")
    }
    return match
}

/// Finds a post in a community by a prefix of its short ID.
func findCommunityPost(_ prefix: String, in community: UserID, account: Account) async throws -> StreamItem {
    let matches = try await account.communityFeed(community).filter { shortID($0.id).hasPrefix(prefix) }
    guard matches.count == 1, let match = matches.first else {
        throw ValidationError(matches.isEmpty ? "No post matches \(prefix)." : "\(prefix) matches several posts; use more characters.")
    }
    return match
}

/// Finds a member, or someone waiting to join, by a prefix of their name.
func findPerson(_ name: String, among people: [(user: UserID, name: String)]) throws -> UserID {
    let matches = people.filter { $0.name.lowercased().hasPrefix(name.lowercased()) }
    guard matches.count == 1, let match = matches.first else {
        throw ValidationError(matches.isEmpty ? "Nobody called \(name) here." : "\(name) matches several people; use more of the name.")
    }
    return match.user
}

struct CommunityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "community", abstract: "Create, join and take part in communities.",
        subcommands: [Create.self, List.self, Invite.self, Join.self, Feed.self, Post.self, Comment.self, PlusOne.self,
                      Members.self, Requests.self, Approve.self, Reject.self, Remove.self, RemovePost.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a community you own, served by this device.")
        @OptionGroup var global: Global
        @Argument var name: String
        @Option(help: "What it's about.") var description = ""
        @Option(help: "public (anyone can read) or private (members only, encrypted).") var visibility: CommunityVisibility = .private
        @Option(help: "open, approval or invite-only.") var join: JoinPolicy = .approval

        func run() async throws {
            let account = try await global.open()
            try await account.createCommunity(name: name, description: description, visibility: visibility, joinPolicy: join)
            print("Created \(name): \(CommunityStrings.visibility(visibility)), \(CommunityStrings.policy(join).lowercased()).")
            print("Share `circles community invite \"\(name)\"`. Keep `circles serve` running so members can reach it.")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List your communities.")
        @OptionGroup var global: Global

        func run() async throws {
            let rows = try await global.open().communities()
            if rows.isEmpty { print("No communities yet. Create one, or join with an invite."); return }
            for summary in rows {
                var line = "\(summary.name) · \(CommunityStrings.role(summary.role)) · "
                    + "\(CommunityStrings.visibility(summary.visibility)) · \(CommunityStrings.policy(summary.joinPolicy)) · "
                    + "\(summary.memberCount) member" + (summary.memberCount == 1 ? "" : "s")
                if !summary.pendingRequests.isEmpty { line += " · \(summary.pendingRequests.count) waiting" }
                print(line)
                if !summary.description.isEmpty { print("  \(summary.description)") }
            }
        }
    }

    struct Invite: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print invite text for a community.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Option(name: .customLong("for"), help: "Invite-only communities: a contact the invite is for (otherwise anyone holding it).")
        var invitee: String?
        @Option(help: "Invite-only communities: days the invite stays valid.") var days = 7

        func run() async throws {
            let account = try await global.open()
            let summary = try await findCommunity(community, in: account)
            var user: UserID?
            if let invitee { user = try await account.contact(named: invitee).user }
            let invitee = user
            print(try await account.communityInvite(summary.community, for: invitee, validFor: .seconds(days * 24 * 3600)))
        }
    }

    struct Join: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask to join a community from its invite text.")
        @OptionGroup var global: Global
        @Argument(help: "The invite text (circles-community:…).") var invite: String

        func run() async throws {
            let account = try await global.open()
            let community = try await account.joinCommunity(invite: invite)
            let name = try await account.communities().first { $0.community == community }?.name ?? "the community"
            print("Asked to join \(name). \(CommunityStrings.pendingNotice) Run `circles sync`.")
        }
    }

    struct Feed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a community's posts.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Option(help: "How many posts to show.") var limit = 20

        func run() async throws {
            let account = try await global.open()
            let id = try await findCommunity(community, in: account).community
            let limit = self.limit
            let (notice, lines) = try await Task { @MainActor in
                let model = CommunityScreenModel(account: account, community: id)
                await model.perform(.refresh)
                if case .failed(let reason) = model.state.phase { throw ValidationError(reason) }
                return (model.state.notice, model.state.cards.prefix(limit).flatMap(render))
            }.value
            if let notice { print("(\(notice))\n") }
            print(lines.isEmpty ? "Nothing here yet." : lines.joined(separator: "\n"))
        }
    }

    struct Post: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Post to a community.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Argument var text: String
        @Option(name: .customLong("attach"), help: "A file to attach (repeatable).") var attachments: [String] = []

        func run() async throws {
            let account = try await global.open()
            let summary = try await findCommunity(community, in: account)
            let files = try attachments.map { path in
                Attachment(data: Array(try Data(contentsOf: URL(fileURLWithPath: path))), mediaType: mediaType(for: path))
            }
            try await account.post(RichText(plain: text), toCommunity: summary.community, attachments: files)
            print(summary.role == .owner ? "Posted to \(summary.name)."
                                         : "Sent to \(summary.name); it appears once the community's owner device picks it up.")
        }
    }

    struct Comment: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Comment on a community post.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Argument(help: "The post's ID, as shown by `circles community feed`.") var post: String
        @Argument var text: String

        func run() async throws {
            let account = try await global.open()
            let id = try await findCommunity(community, in: account).community
            let item = try await findCommunityPost(post, in: id, account: account)
            try await account.comment(RichText(plain: text), on: item.reference, inCommunity: id)
            print("Commented.")
        }
    }

    struct PlusOne: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "plusone", abstract: "+1 a community post, or take it back with --undo.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Argument var post: String
        @Flag(help: "Take back your +1.") var undo = false

        func run() async throws {
            let account = try await global.open()
            let id = try await findCommunity(community, in: account).community
            let item = try await findCommunityPost(post, in: id, account: account)
            try await account.setPlusOne(!undo, on: item.reference, inCommunity: id)
            print(undo ? "Took back your +1." : "+1'd \(item.authorName)'s post.")
        }
    }

    struct Members: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a community's members.")
        @OptionGroup var global: Global
        @Argument var community: String

        func run() async throws {
            let account = try await global.open()
            let id = try await findCommunity(community, in: account).community
            let owner = try await account.communityOwner(id)
            for member in try await account.communityMembers(id) {
                print(member.name + (member.user == owner ? " (owner)" : ""))
            }
        }
    }

    struct Requests: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List requests to join a community you own.")
        @OptionGroup var global: Global
        @Argument var community: String

        func run() async throws {
            let summary = try await findCommunity(community, in: try await global.open())
            if summary.pendingRequests.isEmpty { print("Nobody is waiting."); return }
            for request in summary.pendingRequests { print("\(request.name)\t\(request.user)") }
        }
    }

    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Let someone into a community you own.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Argument(help: "Their name, as shown by `requests`.") var person: String

        func run() async throws {
            let account = try await global.open()
            let summary = try await findCommunity(community, in: account)
            try await account.approveJoin(try findPerson(person, among: summary.pendingRequests), in: summary.community)
            print("Approved. They'll be in once they next sync with \(summary.name).")
        }
    }

    struct Reject: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn down a request to join.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Argument var person: String

        func run() async throws {
            let account = try await global.open()
            let summary = try await findCommunity(community, in: account)
            try await account.rejectJoin(try findPerson(person, among: summary.pendingRequests), in: summary.community)
            print("Turned down.")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a member from a community you own.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Argument var person: String

        func run() async throws {
            let account = try await global.open()
            let id = try await findCommunity(community, in: account).community
            let user = try findPerson(person, among: try await account.communityMembers(id))
            try await account.removeFromCommunity([user], in: id)
            print("Removed.")
        }
    }

    struct RemovePost: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove-post", abstract: "Remove a post from a community you own.")
        @OptionGroup var global: Global
        @Argument var community: String
        @Argument var post: String

        func run() async throws {
            let account = try await global.open()
            let id = try await findCommunity(community, in: account).community
            let item = try await findCommunityPost(post, in: id, account: account)
            try await account.removeCommunityItem(item.id, from: id)
            print("Removed \(item.authorName)'s post.")
        }
    }
}
