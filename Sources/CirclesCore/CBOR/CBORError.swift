/// Errors from deterministic CBOR encoding and strict decoding.
public enum CBORError: Error, Sendable, Equatable {
    // Encoding
    case floatingPointNotAllowed(path: String)
    case duplicateMapKey(path: String)

    // Strict decoding: input that is malformed, or valid CBOR that isn't in
    // core deterministic form (RFC 8949 §4.2.1).
    case truncated(offset: Int)
    case trailingBytes(offset: Int)
    case nonCanonicalLength(offset: Int)
    case indefiniteLengthNotAllowed(offset: Int)
    case unsortedOrDuplicateMapKey(offset: Int)
    case reservedAdditionalInfo(offset: Int)
    case unsupportedTag(offset: Int)
    case unsupportedSimpleValue(offset: Int)
    case invalidUTF8(offset: Int)
    case lengthExceedsInput(offset: Int)
    case depthLimitExceeded(offset: Int)

    // Mapping to Swift types
    case typeMismatch(expected: String, path: String)
    case keyNotFound(key: String, path: String)
    case valueOutOfRange(path: String)
    case unkeyedContainerAtEnd(path: String)

    /// An error thrown by a type's own `Encodable`/`Decodable` implementation.
    case custom(String)
}

func pathDescription(_ codingPath: [any CodingKey]) -> String {
    codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
}
