/// A reference to another author's object, e.g. the post a comment replies to.
public struct ObjectRef: Sendable, Hashable, Codable {
    public var author: UserID
    public var id: ContentID

    public init(author: UserID, id: ContentID) {
        self.author = author
        self.id = id
    }
}

/// A media attachment (docs/DESIGN.md §9.3): encrypted chunks, plus the key
/// to decrypt them. The reference lives inside the (encrypted) post, so only
/// the post's audience learns the key.
public struct BlobRef: Sendable, Hashable, Codable {
    /// IDs of the encrypted chunks, in order.
    public var chunks: [ContentID]
    /// The 32-byte media key the chunks are encrypted under.
    public var key: [UInt8]
    /// SHA-256 of the plaintext, checked after decryption.
    public var digest: ContentID
    public var byteCount: UInt64
    /// An IANA media type, e.g. `image/jpeg`.
    public var mediaType: String
    public var width: UInt32?
    public var height: UInt32?

    public init(
        chunks: [ContentID], key: [UInt8], digest: ContentID, byteCount: UInt64,
        mediaType: String, width: UInt32? = nil, height: UInt32? = nil
    ) {
        self.chunks = chunks
        self.key = key
        self.digest = digest
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }
}

/// Identifies one of an author's Collections: 16 random bytes chosen at creation.
public struct CollectionID: Sendable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws(IdentifierError) {
        guard bytes.count == 16 else { throw .invalidLength(expected: 16, actual: bytes.count) }
        self.bytes = bytes
    }

    public static func random() -> CollectionID {
        var generator = SystemRandomNumberGenerator()
        return try! CollectionID(bytes: (0..<16).map { _ in generator.next() })
    }
}

extension CollectionID: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(bytes: decoder.singleValueContainer().decode([UInt8].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}
