/// A reference to another author's object, e.g. the post a comment replies to.
public struct ObjectRef: Sendable, Hashable, Codable {
    public var author: UserID
    public var id: ContentID

    public init(author: UserID, id: ContentID) {
        self.author = author
        self.id = id
    }
}

/// A reference to a media blob (docs/DESIGN.md §9.3).
public struct BlobRef: Sendable, Hashable, Codable {
    public var id: ContentID
    public var byteCount: UInt64
    /// An IANA media type, e.g. `image/jpeg`.
    public var mediaType: String
    public var width: UInt32?
    public var height: UInt32?

    public init(id: ContentID, byteCount: UInt64, mediaType: String, width: UInt32? = nil, height: UInt32? = nil) {
        self.id = id
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
