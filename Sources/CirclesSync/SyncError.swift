public import CirclesCore
public import CirclesCrypto

public enum SyncError: Error, Sendable {
    case malformedEntry(CBORError)
    case malformedMessage(CBORError)
    case verificationFailed(CryptoError)
    case wrongAuthorOrDevice
    case outOfSequence(device: DeviceID, expected: UInt64, got: UInt64)
    case unknownAuthor(UserID)
    /// The peer's identity document doesn't certify the key it connected with.
    case peerNotAuthenticated
    case peerNotAllowed(UserID)
    case protocolViolation(String)
    case unsupportedProtocolVersion(UInt64)
    case connectionClosed
}
