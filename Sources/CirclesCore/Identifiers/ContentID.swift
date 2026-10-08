private import Crypto

/// The address of an immutable object or blob chunk: a SHA-256 multihash of
/// its canonical encoding (docs/DESIGN.md §9.1).
///
/// Text form: multibase base32 (`b`) of the multihash. On the wire it is the
/// multihash as a byte string. The multihash prefix leaves room for a
/// different hash function later without changing the format.
public struct ContentID: Sendable, Hashable {
    public static let sha256Code: UInt64 = 0x12
    public static let digestLength = 32

    /// The raw 32-byte SHA-256 digest.
    public let digest: [UInt8]

    public init(sha256Digest digest: [UInt8]) throws(IdentifierError) {
        guard digest.count == Self.digestLength else {
            throw .invalidLength(expected: Self.digestLength, actual: digest.count)
        }
        self.digest = digest
    }

    /// Hashes `bytes` with SHA-256.
    public init(hashing bytes: [UInt8]) {
        var hasher = SHA256()
        bytes.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        digest = Array(hasher.finalize())
    }

    /// The ID of `value`'s deterministic CBOR encoding.
    public init(of value: some Encodable) throws(CBORError) {
        self.init(hashing: try CBOREncoder().encode(value))
    }

    public init(multihash bytes: [UInt8]) throws(IdentifierError) {
        guard let (code, codeLength) = Varint.decode(bytes) else { throw .invalidEncoding }
        guard code == Self.sha256Code else { throw .unsupportedCode(code) }
        let rest = bytes.dropFirst(codeLength)
        guard let (length, lengthLength) = Varint.decode(rest) else { throw .invalidEncoding }
        let digest = Array(rest.dropFirst(lengthLength))
        guard length == UInt64(digest.count) else {
            throw .invalidLength(expected: Int(clamping: length), actual: digest.count)
        }
        try self.init(sha256Digest: digest)
    }

    public var multihash: [UInt8] {
        Varint.encode(Self.sha256Code) + Varint.encode(UInt64(Self.digestLength)) + digest
    }

    public init(parsing text: String) throws(IdentifierError) {
        guard text.hasPrefix("b") else { throw .invalidPrefix }
        guard let bytes = Base32.decode(text.dropFirst()) else { throw .invalidEncoding }
        try self.init(multihash: bytes)
    }
}

extension ContentID: LosslessStringConvertible {
    public var description: String { "b" + Base32.encode(multihash) }

    public init?(_ description: String) {
        try? self.init(parsing: description)
    }
}

extension ContentID: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(multihash: decoder.singleValueContainer().decode([UInt8].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(multihash)
    }
}
