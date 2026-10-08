public import CirclesCore
public import CirclesCrypto

// The records a community's log carries (docs/DESIGN.md §8.3, "Community
// design for M5"). A community is an identity of its own; its log is written
// by one sequencer device, and that log's order is the order MLS needs.

public enum CommunityVisibility: UInt64, Sendable, Hashable, Codable {
    /// Signed but not encrypted: anyone can follow it.
    case `public` = 0
    /// MLS-encrypted: only members can read it, from when they joined.
    case `private` = 1
}

public enum JoinPolicy: UInt64, Sendable, Hashable, Codable {
    /// Requests are accepted automatically.
    case open = 0
    /// The owner approves or rejects each request.
    case approval = 1
    /// A request must carry an invite token signed by the community key.
    case inviteOnly = 2
}

/// What a community is, signed by the community key
/// (`SignatureLabel.communityProfile`). A higher version replaces a lower.
public struct CommunityProfile: Sendable, Hashable, Codable {
    public var community: UserID
    public var version: UInt64
    public var name: String
    public var description: String
    public var visibility: CommunityVisibility
    public var joinPolicy: JoinPolicy
    public var owner: UserID

    public init(community: UserID, version: UInt64, name: String, description: String,
                visibility: CommunityVisibility, joinPolicy: JoinPolicy, owner: UserID) {
        self.community = community
        self.version = version
        self.name = name
        self.description = description
        self.visibility = visibility
        self.joinPolicy = joinPolicy
        self.owner = owner
    }
}

/// Permission to join an invite-only community, signed by the community key
/// (`SignatureLabel.communityInvite`). Without an invitee, anyone holding the
/// token may use it until it expires.
public struct CommunityInvite: Sendable, Hashable, Codable {
    public var community: UserID
    public var invitee: UserID?
    public var expiresMillis: UInt64
    public var nonce: [UInt8]

    public init(community: UserID, invitee: UserID?, expiresMillis: UInt64, nonce: [UInt8]) {
        self.community = community
        self.invitee = invitee
        self.expiresMillis = expiresMillis
        self.nonce = nonce
    }
}

/// A request to join, signed by one of the requester's certified devices
/// (`SignatureLabel.communityJoin`) and sent to a serving device as a sync
/// control message. For private communities it carries the MLS KeyPackage
/// to add; its credential must name `user`.
public struct JoinRequest: Sendable, Hashable, Codable {
    public var community: UserID
    public var user: UserID
    public var keyPackage: [UInt8]?
    /// A signed `CommunityInvite`, for invite-only communities.
    public var invite: SignedObject?
    public var createdMillis: UInt64

    public init(community: UserID, user: UserID, keyPackage: [UInt8]?, invite: SignedObject?, createdMillis: UInt64) {
        self.community = community
        self.user = user
        self.keyPackage = keyPackage
        self.invite = invite
        self.createdMillis = createdMillis
    }
}

/// A member's contribution as the sequencer republishes it: the member's own
/// signed post, comment or +1, with their identity document, so every member
/// can verify it, including members who don't know them.
public struct CommunityItem: Sendable, Hashable, Codable {
    public var contribution: ContentItem
    public var contributorIdentity: SignedObject

    public init(contribution: ContentItem, contributorIdentity: SignedObject) {
        self.contribution = contribution
        self.contributorIdentity = contributorIdentity
    }
}

/// What members read from a community. For private communities this is
/// the plaintext of an MLS application message, so even the roster is
/// hidden from everyone but members.
public enum CommunityContent: Sendable, Hashable {
    case members(added: [UserID], removed: [UserID])
    case item(CommunityItem)
    /// The owner removing an item (moderation).
    case deletion(ContentID)
}

/// A record in a community's log.
public enum CommunityRecord: Sendable, Hashable {
    /// A signed `CommunityProfile`.
    case profile(SignedObject)
    /// Content of a public community.
    case open(CommunityContent)
    /// Content of a private community: an MLS application message whose
    /// plaintext is an encoded `CommunityContent`.
    case sealed([UInt8])
    /// An MLS commit (private communities).
    case commit([UInt8])
    /// An MLS Welcome, with the references of the KeyPackages it answers, so
    /// each joiner can find theirs.
    case welcome([UInt8], keyPackages: [[UInt8]])
}

// MARK: - Wire forms ([tag, fields…]; tags are permanent)

extension CommunityContent: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        switch try container.decode(UInt64.self) {
        case 0: self = .members(added: try container.decode([UserID].self), removed: try container.decode([UserID].self))
        case 1: self = .item(try container.decode(CommunityItem.self))
        case 2: self = .deletion(try container.decode(ContentID.self))
        case let tag: throw CBORError.custom("unknown community content tag \(tag)")
        }
        guard container.isAtEnd else { throw CBORError.custom("trailing fields in community content") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .members(let added, let removed):
            try container.encode(UInt64(0))
            try container.encode(added)
            try container.encode(removed)
        case .item(let item):
            try container.encode(UInt64(1))
            try container.encode(item)
        case .deletion(let target):
            try container.encode(UInt64(2))
            try container.encode(target)
        }
    }
}

extension CommunityRecord: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        switch try container.decode(UInt64.self) {
        case 0: self = .profile(try container.decode(SignedObject.self))
        case 1: self = .open(try container.decode(CommunityContent.self))
        case 2: self = .sealed(try container.decode([UInt8].self))
        case 3: self = .commit(try container.decode([UInt8].self))
        case 4: self = .welcome(try container.decode([UInt8].self), keyPackages: try container.decode([[UInt8]].self))
        case let tag: throw CBORError.custom("unknown community record tag \(tag)")
        }
        guard container.isAtEnd else { throw CBORError.custom("trailing fields in community record") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .profile(let profile):
            try container.encode(UInt64(0))
            try container.encode(profile)
        case .open(let content):
            try container.encode(UInt64(1))
            try container.encode(content)
        case .sealed(let message):
            try container.encode(UInt64(2))
            try container.encode(message)
        case .commit(let commit):
            try container.encode(UInt64(3))
            try container.encode(commit)
        case .welcome(let welcome, let keyPackages):
            try container.encode(UInt64(4))
            try container.encode(welcome)
            try container.encode(keyPackages)
        }
    }
}
