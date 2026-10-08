public import CirclesCore

public enum CryptoError: Error, Sendable, Equatable {
    case invalidKey
    case invalidSignature
    /// The object was signed by a different key than the one required.
    case unexpectedSigner
    case unknownDevice(DeviceID)
    case deviceRevoked(DeviceID)
    case certificateNotValid(DeviceID, atMillis: UInt64)
    case missingCapability(DeviceID)
    /// A document or grant names a different user than expected.
    case identityMismatch
    /// None of the envelope's wrapped keys can be opened with the keys held.
    case notARecipient
    case decryptionFailed
    case malformedPadding
    case unsupportedVersion(UInt64)
    case encoding(CBORError)
}
