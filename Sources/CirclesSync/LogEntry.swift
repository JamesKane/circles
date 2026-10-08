public import CirclesCore
public import CirclesCrypto

/// The kinds of content a log can carry. Numbers are permanent.
public enum ContentKind: UInt64, Sendable, Hashable, Codable {
    case post = 0
    case comment = 1
    case reaction = 2
    /// A comment or reaction, republished by the post's author to the post's
    /// audience (docs/DESIGN.md §9.4).
    case threadItem = 3
    /// The author withdrawing a post, or a comment from their thread.
    case deletion = 4

    /// The signature label a content object of this kind is signed under.
    public var label: SignatureLabel {
        switch self {
        case .post: .post
        case .comment: .comment
        case .reaction: .reaction
        case .threadItem: .threadItem
        case .deletion: .deletion
        }
    }
}

/// A content object together with its kind. This is the plaintext of a
/// sealed log entry, so the kind is hidden from anyone outside the audience.
public struct ContentItem: Sendable, Hashable, Codable {
    public var kind: ContentKind
    public var object: SignedObject
    /// Signed objects carried along so readers can verify the content without
    /// fetching anything else, e.g. the original post and its author's
    /// identity document in a reshare. Absent when empty (added in M4).
    public var embedded: [SignedObject]?

    public init(kind: ContentKind, object: SignedObject, embedded: [SignedObject] = []) {
        self.kind = kind
        self.object = object
        self.embedded = embedded.isEmpty ? nil : embedded
    }
}

/// A comment or reaction as republished by the post's author: the
/// contributor's own signed object, plus their identity document so every
/// reader can verify it, including readers who don't know the contributor.
/// The author signs the whole thing (`SignatureLabel.threadItem`), which is
/// what makes it part of the thread. Unrepublished comments aren't shown to
/// others, so the author moderates their own thread.
public struct ThreadItem: Sendable, Hashable, Codable {
    /// The post this belongs to.
    public var post: ContentID
    public var contribution: ContentItem
    public var contributorIdentity: SignedObject

    public init(post: ContentID, contribution: ContentItem, contributorIdentity: SignedObject) {
        self.post = post
        self.contribution = contribution
        self.contributorIdentity = contributorIdentity
    }
}

/// What a log entry carries.
public enum LogBody: Sendable, Hashable {
    /// Public content: signed but not encrypted.
    case publicContent(ContentItem)
    /// Audience-encrypted content: an `Envelope` whose plaintext is an
    /// encoded `ContentItem`.
    case sealedContent(Envelope)
    /// A circle key for one member device. It carries no recipient hint, so
    /// devices find their own grants by trial decryption.
    case keyGrant(SealedKeyGrant)
}

/// Wire form `[tag, value]`. Tags are permanent.
extension LogBody: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let tag = try container.decode(UInt64.self)
        switch tag {
        case 0: self = .publicContent(try container.decode(ContentItem.self))
        case 1: self = .sealedContent(try container.decode(Envelope.self))
        case 2: self = .keyGrant(try container.decode(SealedKeyGrant.self))
        default: throw CBORError.custom("unknown log body tag \(tag)")
        }
        guard container.isAtEnd else { throw CBORError.custom("trailing fields in log body") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .publicContent(let item):
            try container.encode(UInt64(0))
            try container.encode(item)
        case .sealedContent(let envelope):
            try container.encode(UInt64(1))
            try container.encode(envelope)
        case .keyGrant(let grant):
            try container.encode(UInt64(2))
            try container.encode(grant)
        }
    }
}

/// One entry in a device's append-only log (docs/DESIGN.md §9.2), signed by
/// that device under `SignatureLabel.logEntry`. Entries are hash-linked:
/// `previous` is the ID of the entry before, so a log can't be reordered or
/// have entries dropped from the middle without detection.
public struct LogEntry: Sendable, Hashable, Codable {
    public var author: UserID
    public var device: DeviceID
    /// 1-based, contiguous per device.
    public var sequence: UInt64
    /// The ID of entry `sequence - 1`; nil exactly when `sequence == 1`.
    public var previous: ContentID?
    public var created: HLCTimestamp
    public var body: LogBody
    /// IDs of the encrypted media chunks this entry's content refers to
    /// (docs/DESIGN.md §9.3). Listed outside the encryption, so every node
    /// that stores the entry, pods included, also fetches and keeps the
    /// chunks. It reveals no more than the entry's size already does.
    /// Absent when there are none (added in M4).
    public var blobs: [ContentID]?

    public init(
        author: UserID, device: DeviceID, sequence: UInt64, previous: ContentID?,
        created: HLCTimestamp, body: LogBody, blobs: [ContentID]? = nil
    ) {
        self.author = author
        self.device = device
        self.sequence = sequence
        self.previous = previous
        self.created = created
        self.body = body
        self.blobs = blobs?.isEmpty == true ? nil : blobs
    }
}

/// A log entry whose signature, certificate and chain position have been
/// checked. The store only ever accepts these.
public struct VerifiedLogEntry: Sendable, Hashable {
    public let signed: SignedObject
    public let entry: LogEntry

    /// The entry's ID: the hash of its signed payload.
    public var id: ContentID { signed.contentID }

    /// Signs and wraps a new entry created on this device. The caller is
    /// responsible for choosing the right sequence and previous ID.
    public init(signing entry: LogEntry, with device: borrowing DeviceKeyPair) throws(CryptoError) {
        precondition(entry.device == device.deviceID, "entry must name the signing device")
        signed = try SignedObject(encoding: entry, label: .logEntry, with: device)
        self.entry = entry
    }

    /// Wraps an entry this node verified before, e.g. when migrating storage.
    /// The store still enforces the hash chain on append.
    public init(previouslyVerified signed: SignedObject, entry: LogEntry) {
        self.signed = signed
        self.entry = entry
    }

    /// Verifies a received entry against the author's identity and the
    /// current head of that device's log (`nil` for an empty log).
    public init(
        verifying signed: SignedObject,
        author: VerifiedIdentity,
        after head: LogHead?
    ) throws(SyncError) {
        let claimed: LogEntry
        do {
            claimed = try CBORDecoder().decode(LogEntry.self, from: signed.payload)
        } catch {
            throw .malformedEntry(error)
        }
        do {
            _ = try author.verify(signed, label: .logEntry, atMillis: claimed.created.millis)
        } catch {
            throw .verificationFailed(error)
        }
        guard claimed.author == author.user, claimed.device == signed.signerDevice else {
            throw .wrongAuthorOrDevice
        }
        let expected = (head?.sequence ?? 0) + 1
        guard claimed.sequence == expected, claimed.previous == head?.id else {
            throw .outOfSequence(device: claimed.device, expected: expected, got: claimed.sequence)
        }
        self.signed = signed
        entry = claimed
    }
}

/// The last entry in one device's log.
public struct LogHead: Sendable, Hashable {
    public var sequence: UInt64
    public var id: ContentID

    public init(sequence: UInt64, id: ContentID) {
        self.sequence = sequence
        self.id = id
    }
}

/// How far a peer has each of an author's device logs.
///
/// Encoded as an array of `[device, sequence]` pairs sorted by device, never
/// as a map, so the encoding doesn't depend on dictionary order.
public struct Frontier: Sendable, Hashable {
    public var sequences: [DeviceID: UInt64]

    public init(_ sequences: [DeviceID: UInt64] = [:]) {
        self.sequences = sequences
    }

    public subscript(device: DeviceID) -> UInt64 {
        sequences[device] ?? 0
    }
}

extension Frontier: Codable {
    private struct Pair: Codable {
        var device: DeviceID
        var sequence: UInt64

        init(device: DeviceID, sequence: UInt64) {
            self.device = device
            self.sequence = sequence
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            device = try container.decode(DeviceID.self)
            sequence = try container.decode(UInt64.self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(device)
            try container.encode(sequence)
        }
    }

    public init(from decoder: any Decoder) throws {
        let pairs = try decoder.singleValueContainer().decode([Pair].self)
        sequences = Dictionary(pairs.map { ($0.device, $0.sequence) }, uniquingKeysWith: max)
    }

    public func encode(to encoder: any Encoder) throws {
        let pairs = sequences
            .map { Pair(device: $0.key, sequence: $0.value) }
            .sorted { $0.device.publicKey.lexicographicallyPrecedes($1.device.publicKey) }
        var container = encoder.singleValueContainer()
        try container.encode(pairs)
    }
}
