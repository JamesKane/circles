public import CirclesCore
public import CirclesCrypto

/// Someone this user has added, with a local name. The name is a petname:
/// it never leaves this device (docs/DESIGN.md §6.1).
public struct Contact: Sendable, Hashable, Codable {
    public var user: UserID
    public var name: String
}

/// A circle as its owner stores it. Name and membership are private
/// (docs/DESIGN.md §8.1).
public struct CircleRecord: Sendable, Codable {
    public var name: String
    public var members: [UserID]
    public var rotateOnAdd: Bool
    var current: StoredKey

    var schedule: CircleKeySchedule {
        get throws {
            CircleKeySchedule(current: try current.audienceKey, members: Set(members), rotateOnAdd: rotateOnAdd)
        }
    }

    init(name: String, schedule: CircleKeySchedule) {
        self.name = name
        members = schedule.members.sorted { $0.publicKey.lexicographicallyPrecedes($1.publicKey) }
        rotateOnAdd = schedule.rotateOnAdd
        current = StoredKey(owner: nil, key: schedule.current)
    }
}

/// An audience key at rest.
struct StoredKey: Codable {
    var owner: UserID?
    var id: AudienceKeyID
    var epoch: UInt64
    var raw: [UInt8]

    init(owner: UserID?, key: AudienceKey) {
        self.owner = owner
        id = key.id
        epoch = key.epoch
        raw = key.exportRawKey()
    }

    var audienceKey: AudienceKey {
        get throws { try AudienceKey(id: id, epoch: epoch, rawKey: raw) }
    }
}

struct StoredKeys: Codable {
    var identity: [UInt8]
    var deviceSigning: [UInt8]
    var deviceAgreement: [UInt8]
}

struct Profile: Codable {
    var displayName: String
    var identityDocument: SignedObject
}

/// What one user hands another to become contacts: their suggested name and
/// signed identity document. Shared as text (and later as a QR code).
public struct Invite: Sendable, Codable {
    public var name: String
    public var identityDocument: SignedObject

    static let prefix = "circles-invite:"

    public var text: String {
        get throws { Self.prefix + Base32.encode(try CBOREncoder().encode(self)) }
    }

    public init(name: String, identityDocument: SignedObject) {
        self.name = name
        self.identityDocument = identityDocument
    }

    public init(text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix), let bytes = Base32.decode(trimmed.dropFirst(Self.prefix.count)) else {
            throw AccountError.invalidInvite
        }
        self = try CBORDecoder().decode(Invite.self, from: bytes)
    }
}

/// A post as the reader sees it, after decryption and verification.
public struct StreamItem: Sendable, Hashable {
    public enum Audience: Sendable, Hashable {
        case everyone
        /// Limited to circles or people chosen by the author.
        case limited
    }

    public var id: ContentID
    public var author: UserID
    public var authorName: String
    public var created: HLCTimestamp
    public var body: RichText
    public var audience: Audience
}

public enum PostAudience: Sendable {
    case everyone
    /// The named circles of the author.
    case circles([String])
}

public enum AccountError: Error, Sendable, Equatable {
    case alreadyExists
    case notFound
    case invalidInvite
    case unknownCircle(String)
    case unknownContact(String)
    case circleExists(String)
    case emptyAudience
}

import Foundation
