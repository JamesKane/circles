public enum IdentifierError: Error, Sendable, Equatable {
    case invalidPrefix
    case invalidEncoding
    case unsupportedCode(UInt64)
    case invalidLength(expected: Int, actual: Int)
}
