public import CirclesCore
public import CirclesCrypto

/// Messages of the one-shot sync protocol (docs/DESIGN.md §7.4, §9.2).
///
/// Each side sends, in order: `hello`; any `control` messages; `ready`; one
/// `want`; any number of `identity`/`entries` messages answering the peer's
/// `want`; `entriesDone`; one `wantBlobs` (sent once the peer's
/// `entriesDone` arrives, listing media chunks it still needs); `blob`
/// messages answering the peer's `wantBlobs`; then `done`. A side builds its
/// `want` only after the peer's `ready`, so control messages (such as a pod's
/// configuration) can shape what it asks for. The session ends when both
/// sides have sent `done`.
public enum SyncMessage: Sendable, Hashable {
    case hello(Hello)
    case want([Want])
    case identity(SignedObject)
    case entries(author: UserID, entries: [SignedObject])
    case done
    /// A signed instruction whose meaning depends on its label, e.g. a pod
    /// configuration from the pod's owner.
    case control(SignedObject)
    case ready
    case entriesDone
    case wantBlobs([ContentID])
    case blob(ContentID, [UInt8])

    public static let protocolVersion: UInt64 = 1

    public struct Hello: Sendable, Hashable, Codable {
        public var version: UInt64
        /// The sender's signed identity document.
        public var identity: SignedObject
    }

    /// "I have this much of `author`'s logs; send me what's newer."
    public struct Want: Sendable, Hashable, Codable {
        public var author: UserID
        /// The version of the author's identity document the sender holds (0 if none).
        public var identityVersion: UInt64
        public var frontier: Frontier
    }
}

/// Wire form `[tag, fields…]`. Tags are permanent.
extension SyncMessage: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let tag = try container.decode(UInt64.self)
        switch tag {
        case 0: self = .hello(try container.decode(Hello.self))
        case 1: self = .want(try container.decode([Want].self))
        case 2: self = .identity(try container.decode(SignedObject.self))
        case 3: self = .entries(author: try container.decode(UserID.self), entries: try container.decode([SignedObject].self))
        case 4: self = .done
        case 5: self = .control(try container.decode(SignedObject.self))
        case 6: self = .ready
        case 7: self = .entriesDone
        case 8: self = .wantBlobs(try container.decode([ContentID].self))
        case 9: self = .blob(try container.decode(ContentID.self), try container.decode([UInt8].self))
        default: throw CBORError.custom("unknown sync message tag \(tag)")
        }
        guard container.isAtEnd else { throw CBORError.custom("trailing fields in sync message") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .hello(let hello):
            try container.encode(UInt64(0))
            try container.encode(hello)
        case .want(let wants):
            try container.encode(UInt64(1))
            try container.encode(wants)
        case .identity(let document):
            try container.encode(UInt64(2))
            try container.encode(document)
        case .entries(let author, let entries):
            try container.encode(UInt64(3))
            try container.encode(author)
            try container.encode(entries)
        case .done:
            try container.encode(UInt64(4))
        case .control(let object):
            try container.encode(UInt64(5))
            try container.encode(object)
        case .ready:
            try container.encode(UInt64(6))
        case .entriesDone:
            try container.encode(UInt64(7))
        case .wantBlobs(let ids):
            try container.encode(UInt64(8))
            try container.encode(ids)
        case .blob(let id, let bytes):
            try container.encode(UInt64(9))
            try container.encode(id)
            try container.encode(bytes)
        }
    }
}
