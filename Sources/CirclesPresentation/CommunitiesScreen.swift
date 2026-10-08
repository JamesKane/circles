import Foundation
public import Observation
public import CirclesCore
public import CirclesKit
public import CirclesSync

/// A community as a row in a list.
public struct CommunityRow: Sendable, Equatable, Identifiable {
    public var community: UserID
    public var name: String
    public var initials: String
    public var description: String
    /// "Private · Approval needed", etc.
    public var detail: String
    public var role: CommunitySummary.Role
    /// "Owner", "Member", "Waiting to be let in", "Removed".
    public var roleLabel: String
    public var memberCount: Int
    public var pendingCount: Int
    public var id: UserID { community }

    init(_ summary: CommunitySummary) {
        community = summary.community
        name = summary.name
        initials = Format.initials(summary.name)
        description = summary.description
        detail = CommunityStrings.visibility(summary.visibility) + " · " + CommunityStrings.policy(summary.joinPolicy)
        role = summary.role
        roleLabel = CommunityStrings.role(summary.role)
        memberCount = summary.memberCount
        pendingCount = summary.pendingRequests.count
    }
}

public enum CommunityStrings {
    public static func visibility(_ visibility: CommunityVisibility) -> String {
        visibility == .public ? "Public" : "Private"
    }

    public static func policy(_ policy: JoinPolicy) -> String {
        switch policy {
        case .open: "Anyone can join"
        case .approval: "Approval needed"
        case .inviteOnly: "Invite only"
        }
    }

    public static func role(_ role: CommunitySummary.Role) -> String {
        switch role {
        case .owner: "Owner"
        case .member: "Member"
        case .pending: "Waiting to be let in"
        case .removed: "Removed"
        }
    }

    public static let privateHistory = "Members see posts from when they joined."
    public static let pendingNotice = "Your request goes out the next time you sync with the community."
    public static let removedNotice = "You're no longer a member of this community."
}

public struct CommunitiesState: Sendable, Equatable {
    public var communities: [CommunityRow] = []
    public var phase: Phase = .idle
    /// The community just created or joined, for the UI to open.
    public var opened: UserID?
}

public enum CommunitiesIntent: Sendable {
    case load
    case sync
    case create(name: String, description: String, visibility: CommunityVisibility, joinPolicy: JoinPolicy)
    /// Accepts invite text (circles-community:…).
    case join(invite: String)
}

/// The communities we own, belong to or are joining.
@MainActor
@Observable
public final class CommunitiesScreenModel: ScreenModel {
    public private(set) var state = CommunitiesState()
    private let account: Account

    public init(account: Account) {
        self.account = account
    }

    public func perform(_ intent: CommunitiesIntent) async {
        do {
            state.opened = nil
            switch intent {
            case .load:
                break
            case .sync:
                state.phase = .syncing
                _ = await account.syncAll()
            case .create(let name, let description, let visibility, let joinPolicy):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw CommunityInputError.nameRequired }
                state.opened = try await account.createCommunity(name: trimmed, description: description,
                                                                 visibility: visibility, joinPolicy: joinPolicy)
            case .join(let invite):
                state.opened = try await account.joinCommunity(invite: invite)
            }
            state.communities = try await account.communities().map(CommunityRow.init)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            state.phase = .idle
        } catch {
            state.phase = .failed(CommunityInputError.describe(error))
        }
    }
}

enum CommunityInputError: Error {
    case nameRequired

    static func describe(_ error: any Error) -> String {
        switch error {
        case CommunityInputError.nameRequired: "Give the community a name."
        case CommunityError.invalidInvite: "That isn't a community invite."
        case CommunityError.inviteRequired: "This community is invite-only; you need an invite from its owner."
        case CommunityError.notAMember: "Only members can do that."
        case CommunityError.notOwner: "Only the community's owner can do that."
        default: String(describing: error)
        }
    }
}

// MARK: - One community

public struct CommunityScreenState: Sendable, Equatable {
    public struct Member: Sendable, Equatable, Identifiable {
        public var user: UserID
        public var name: String
        public var initials: String
        public var isOwner: Bool
        public var id: UserID { user }
    }

    public var header: CommunityRow?
    public var notice: String?
    public var cards: [PostCard] = []
    public var members: [Member] = []
    /// Owner, approval policy: who's waiting.
    public var requests: [Member] = []
    public var canPost = false
    public var isOwner = false
    /// Invite text, once asked for, to show or copy.
    public var invite: String?
    public var phase: Phase = .idle
}

public enum CommunityIntent: Sendable {
    case refresh
    case sync
    case post(String)
    case comment(on: ObjectRef, String)
    case setPlusOne(ObjectRef, Bool)
    /// Owner: approve or reject a join request.
    case approve(UserID)
    case reject(UserID)
    /// Owner: remove a member, or a post or comment.
    case removeMember(UserID)
    case removeItem(ContentID)
    /// Makes invite text (for invite-only communities, a token for anyone
    /// holding it, valid for a week) and copies it.
    case makeInvite
}

/// One community: its posts, members and, for its owner, moderation.
@MainActor
@Observable
public final class CommunityScreenModel: ScreenModel {
    public private(set) var state = CommunityScreenState()
    public let community: UserID
    private let account: Account
    private let services: (any PlatformServices)?
    private let now: @Sendable () -> Date

    public init(account: Account, community: UserID, services: (any PlatformServices)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.community = community
        self.services = services
        self.now = now
    }

    public func perform(_ intent: CommunityIntent) async {
        do {
            switch intent {
            case .refresh:
                break
            case .sync:
                state.phase = .syncing
                _ = await account.syncAll()
            case .post(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                try await account.post(RichText(plain: trimmed), toCommunity: community)
            case .comment(let post, let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                try await account.comment(RichText(plain: trimmed), on: post, inCommunity: community)
            case .setPlusOne(let post, let on):
                try await account.setPlusOne(on, on: post, inCommunity: community)
            case .approve(let user):
                try await account.approveJoin(user, in: community)
            case .reject(let user):
                try await account.rejectJoin(user, in: community)
            case .removeMember(let user):
                try await account.removeFromCommunity([user], in: community)
            case .removeItem(let id):
                try await account.removeCommunityItem(id, from: community)
            case .makeInvite:
                let text = try await account.communityInvite(community)
                state.invite = text
                await services?.copyToClipboard(text)
            }
            try await reload()
        } catch {
            state.phase = .failed(CommunityInputError.describe(error))
        }
    }

    private func reload() async throws {
        guard let summary = try await account.communities().first(where: { $0.community == community }) else {
            throw CommunityError.unknownCommunity
        }
        let row = CommunityRow(summary)
        let owner = summary.role == .owner
        state.header = row
        state.isOwner = owner
        state.canPost = owner || summary.role == .member
        switch summary.role {
        case .pending: state.notice = CommunityStrings.pendingNotice
        case .removed: state.notice = CommunityStrings.removedNotice
        default: state.notice = summary.visibility == .private ? CommunityStrings.privateHistory : nil
        }
        let date = now()
        state.cards = try await account.communityFeed(community).map { PostCard(communityItem: $0, now: date, moderator: owner, communityName: row.name) }
        let ownerID = try await account.communityOwner(community)
        state.members = try await account.communityMembers(community).map { member in
            .init(user: member.user, name: member.name, initials: Format.initials(member.name), isOwner: member.user == ownerID)
        }.sorted { ($0.isOwner ? 0 : 1, $0.name) < ($1.isOwner ? 0 : 1, $1.name) }
        state.requests = summary.pendingRequests.map {
            .init(user: $0.user, name: $0.name, initials: Format.initials($0.name), isOwner: false)
        }
        state.phase = .idle
    }
}
