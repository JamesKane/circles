/// A user's identity: their Ed25519 identity public key (docs/DESIGN.md §6.1).
///
/// Text form: `circles:` + multibase base32 (`b`) of the multicodec-tagged
/// key (`ed25519-pub`, 0xed). On the wire it is the tagged key as a byte string.
public struct UserID: Sendable, Hashable {
    public static let ed25519PublicKeyCode: UInt64 = 0xED
    public static let scheme = "circles:"

    /// The raw 32-byte Ed25519 public key.
    public let publicKey: [UInt8]

    public init(ed25519PublicKey key: [UInt8]) throws(IdentifierError) {
        guard key.count == 32 else { throw .invalidLength(expected: 32, actual: key.count) }
        publicKey = key
    }

    public init(multicodecBytes bytes: [UInt8]) throws(IdentifierError) {
        guard let (code, length) = Varint.decode(bytes) else { throw .invalidEncoding }
        guard code == Self.ed25519PublicKeyCode else { throw .unsupportedCode(code) }
        try self.init(ed25519PublicKey: Array(bytes.dropFirst(length)))
    }

    public var multicodecBytes: [UInt8] {
        Varint.encode(Self.ed25519PublicKeyCode) + publicKey
    }

    public init(parsing text: String) throws(IdentifierError) {
        guard text.hasPrefix(Self.scheme + "b") else { throw .invalidPrefix }
        guard let bytes = Base32.decode(text.dropFirst(Self.scheme.count + 1)) else {
            throw .invalidEncoding
        }
        try self.init(multicodecBytes: bytes)
    }
}

extension UserID: LosslessStringConvertible {
    public var description: String {
        Self.scheme + "b" + Base32.encode(multicodecBytes)
    }

    public init?(_ description: String) {
        try? self.init(parsing: description)
    }
}

extension UserID: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(multicodecBytes: decoder.singleValueContainer().decode([UInt8].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(multicodecBytes)
    }
}
