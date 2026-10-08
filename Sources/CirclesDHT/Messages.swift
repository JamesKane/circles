public import CirclesCore
public import CirclesCrypto
import Crypto

/// A position in the DHT's 256-bit keyspace (docs/DESIGN.md §7.2).
public struct NodeID: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32)
        self.bytes = bytes
    }

    /// A node's ID: the hash of its Noise static key, so every contact's ID
    /// is checked by the handshake that reaches it.
    public init(node key: AgreementPublicKey) {
        bytes = Array(SHA256.hash(data: Array("circles/v1/dht-node".utf8) + key.rawRepresentation))
    }

    /// Where a user's identity document lives.
    public init(user: UserID) {
        bytes = Array(SHA256.hash(data: Array("circles/v1/dht-user".utf8) + user.multicodecBytes))
    }

    public static func random() -> NodeID {
        var generator = SystemRandomNumberGenerator()
        return NodeID(bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// XOR distance, as a big-endian 256-bit number.
    public func distance(to other: NodeID) -> [UInt8] {
        zip(bytes, other.bytes).map { $0 ^ $1 }
    }

    /// `contacts` ordered by XOR distance to `self`, nearest first. Each
    /// distance is computed once.
    public func sortByDistance(_ contacts: some Sequence<DHTContact>) -> [DHTContact] {
        contacts.map { (distance: $0.id.distance(to: self), contact: $0) }
            .sorted { $0.distance.lexicographicallyPrecedes($1.distance) }
            .map(\.contact)
    }

    /// The number of leading bits shared with `other` (256 when equal).
    public func sharedPrefixLength(with other: NodeID) -> Int {
        for (index, byte) in distance(to: other).enumerated() where byte != 0 {
            return index * 8 + byte.leadingZeroBitCount
        }
        return 256
    }

    public static func < (lhs: NodeID, rhs: NodeID) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }

    public var description: String { Base32.encode(Array(bytes.prefix(6))) }
}

/// How to reach a DHT node: its key (checked by the Noise handshake) and the
/// address it was seen at.
public struct DHTContact: Sendable, Hashable, Codable {
    public let key: AgreementPublicKey
    public var host: String
    public var port: UInt16
    /// Derived from `key`; computed once, since lookups sort by it constantly.
    public let id: NodeID

    public init(key: AgreementPublicKey, host: String, port: UInt16) {
        self.key = key
        self.host = host
        self.port = port
        id = NodeID(node: key)
    }

    private enum CodingKeys: String, CodingKey { case key, host, port }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(AgreementPublicKey.self, forKey: .key),
                  host: try container.decode(String.self, forKey: .host),
                  port: try container.decode(UInt16.self, forKey: .port))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
    }
}

/// DHT requests and responses. They share a connection's first frame with
/// sync messages, so their tags start at 64, well clear of the sync
/// protocol's (`DHTMessage.isDHT`). Tags are permanent.
public enum DHTMessage: Sendable, Hashable {
    /// "Which nodes do you know closest to `target`?" `listenPort` is where
    /// the sender accepts connections (nil for nodes that don't), at the
    /// address the responder sees it connect from.
    case findNode(target: NodeID, listenPort: UInt16?)
    /// As findNode, but answered with the record if the responder holds it.
    case findValue(key: NodeID, listenPort: UInt16?)
    /// "Keep this record": a signed identity document.
    case store(SignedObject, listenPort: UInt16?)
    /// The closest nodes the responder knows, and the address it saw the
    /// requester at (so nodes learn their public address).
    case nodes([DHTContact], observed: String?)
    case value(SignedObject, nodes: [DHTContact])
    case stored(Bool)

    static let firstTag: UInt64 = 64

    /// Whether a connection's first frame is a DHT message rather than sync.
    public static func isDHT(_ frame: [UInt8]) -> Bool {
        guard let peek = try? CBORDecoder().decode(TagPeek.self, from: frame) else { return false }
        return peek.tag >= firstTag
    }

    private struct TagPeek: Decodable {
        var tag: UInt64
        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            tag = try container.decode(UInt64.self)
            while !container.isAtEnd { _ = try container.decode(Skip.self) }
        }
    }

    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

extension NodeID: Codable {
    public init(from decoder: any Decoder) throws {
        let bytes = try decoder.singleValueContainer().decode([UInt8].self)
        guard bytes.count == 32 else { throw CBORError.custom("node ID must be 32 bytes") }
        self.init(bytes: bytes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

extension DHTMessage: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        switch try container.decode(UInt64.self) {
        case 64: self = .findNode(target: try container.decode(NodeID.self), listenPort: try container.decode(UInt16?.self))
        case 65: self = .findValue(key: try container.decode(NodeID.self), listenPort: try container.decode(UInt16?.self))
        case 66: self = .store(try container.decode(SignedObject.self), listenPort: try container.decode(UInt16?.self))
        case 67: self = .nodes(try container.decode([DHTContact].self), observed: try container.decode(String?.self))
        case 68: self = .value(try container.decode(SignedObject.self), nodes: try container.decode([DHTContact].self))
        case 69: self = .stored(try container.decode(Bool.self))
        case let tag: throw CBORError.custom("unknown DHT message tag \(tag)")
        }
        guard container.isAtEnd else { throw CBORError.custom("trailing fields in DHT message") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .findNode(let target, let port):
            try container.encode(UInt64(64)); try container.encode(target); try container.encode(port)
        case .findValue(let key, let port):
            try container.encode(UInt64(65)); try container.encode(key); try container.encode(port)
        case .store(let record, let port):
            try container.encode(UInt64(66)); try container.encode(record); try container.encode(port)
        case .nodes(let nodes, let observed):
            try container.encode(UInt64(67)); try container.encode(nodes); try container.encode(observed)
        case .value(let record, let nodes):
            try container.encode(UInt64(68)); try container.encode(record); try container.encode(nodes)
        case .stored(let ok):
            try container.encode(UInt64(69)); try container.encode(ok)
        }
    }
}
