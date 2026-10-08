#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Domain separation for signatures. Every signature covers a label plus the
/// payload, so a signature made for one purpose can never be replayed as
/// another (e.g. a signed comment accepted as a device certificate).
public struct SignatureLabel: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.utf8.contains(0), "labels must not contain NUL")
        self.rawValue = rawValue
    }

    public static let deviceCertificate = SignatureLabel(rawValue: "circles/v1/device-certificate")
    public static let identityDocument = SignatureLabel(rawValue: "circles/v1/identity-document")
    public static let keyGrant = SignatureLabel(rawValue: "circles/v1/key-grant")
    public static let logEntry = SignatureLabel(rawValue: "circles/v1/log-entry")
    public static let post = SignatureLabel(rawValue: "circles/v1/post")
    public static let comment = SignatureLabel(rawValue: "circles/v1/comment")
    public static let reaction = SignatureLabel(rawValue: "circles/v1/reaction")

    /// The bytes actually signed: `label || 0x00 || payload`. Labels contain
    /// no NUL, so the split is unambiguous.
    func message(for payload: [UInt8]) -> [UInt8] {
        Array(rawValue.utf8) + [0] + payload
    }
}

/// HPKE `info` strings and AEAD associated-data prefixes.
enum Context {
    static let envelopeBody = Array("circles/v1/envelope-body".utf8) + [0]
    static let cekWrap = Array("circles/v1/cek-wrap".utf8) + [0]
    static let cekWrapInfo = Data("circles/v1/cek-wrap".utf8)
    static let keyGrantInfo = Data("circles/v1/key-grant".utf8)
}
