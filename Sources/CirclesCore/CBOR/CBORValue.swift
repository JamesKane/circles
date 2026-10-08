/// The subset of CBOR (RFC 8949) used by the Circles wire format.
///
/// Signed objects must have exactly one byte representation, so the data
/// model is deliberately narrow: no floating point, no tags, no undefined, no
/// indefinite-length items. See docs/DESIGN.md §7.4.
public indirect enum CBORValue: Sendable, Hashable {
    case unsigned(UInt64)
    /// A negative integer, stored as CBOR stores it: the value is `-1 - n`.
    case negative(UInt64)
    case bytes([UInt8])
    case text(String)
    case array([CBORValue])
    /// Map entries in insertion order. The writer sorts them into
    /// deterministic order.
    case map([CBORMapEntry])
    case bool(Bool)
    case null
}

public struct CBORMapEntry: Sendable, Hashable {
    public var key: CBORValue
    public var value: CBORValue

    public init(key: CBORValue, value: CBORValue) {
        self.key = key
        self.value = value
    }
}

extension CBORValue {
    /// Creates an integer value using the major type CBOR requires for its sign.
    public init(_ int: Int64) {
        // For negative n, CBOR encodes -1 - n, which is the bitwise complement.
        self = int >= 0 ? .unsigned(UInt64(int)) : .negative(UInt64(~int))
    }
}
