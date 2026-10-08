#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import CirclesCore
import Crypto

/// A user's long-term identity key (docs/DESIGN.md §6.1). Its public key is
/// the `UserID`. It's used only to certify devices and sign the identity
/// document, ideally from an offline or secure-enclave device.
///
/// `~Copyable` so secret key material can't be accidentally duplicated.
public struct IdentityKeyPair: ~Copyable, Sendable {
    private let signingKey: Curve25519.Signing.PrivateKey

    public init() {
        signingKey = Curve25519.Signing.PrivateKey()
    }

    public init(rawRepresentation: [UInt8]) throws(CryptoError) {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation) else {
            throw .invalidKey
        }
        signingKey = key
    }

    /// The 32-byte private key, for the key store and encrypted backup only.
    public func exportRawRepresentation() -> [UInt8] {
        Array(signingKey.rawRepresentation)
    }

    public var userID: UserID {
        try! UserID(ed25519PublicKey: Array(signingKey.publicKey.rawRepresentation))
    }

    func sign(_ payload: [UInt8], label: SignatureLabel) throws(CryptoError) -> [UInt8] {
        try ed25519Sign(signingKey, label.message(for: payload))
    }
}

/// A device or pod's keys: Ed25519 for signing, X25519 for receiving
/// encrypted keys. Certified by the identity key (`DeviceCertificate`).
public struct DeviceKeyPair: ~Copyable, Sendable {
    private let signingKey: Curve25519.Signing.PrivateKey
    let agreementKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        signingKey = Curve25519.Signing.PrivateKey()
        agreementKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public init(signingKey signingRaw: [UInt8], agreementKey agreementRaw: [UInt8]) throws(CryptoError) {
        guard let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingRaw),
              let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementRaw)
        else { throw .invalidKey }
        signingKey = signing
        agreementKey = agreement
    }

    /// The private keys, for the key store only.
    public func exportRawRepresentation() -> (signingKey: [UInt8], agreementKey: [UInt8]) {
        (Array(signingKey.rawRepresentation), Array(agreementKey.rawRepresentation))
    }

    public var deviceID: DeviceID {
        try! DeviceID(ed25519PublicKey: Array(signingKey.publicKey.rawRepresentation))
    }

    public var agreementPublicKey: AgreementPublicKey {
        AgreementPublicKey(agreementKey.publicKey)
    }

    func sign(_ payload: [UInt8], label: SignatureLabel) throws(CryptoError) -> [UInt8] {
        try ed25519Sign(signingKey, label.message(for: payload))
    }
}

/// A device's X25519 public key, published in its certificate.
public struct AgreementPublicKey: Sendable, Hashable {
    public let rawRepresentation: [UInt8]

    public init(rawRepresentation: [UInt8]) throws(CryptoError) {
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation)) != nil else {
            throw .invalidKey
        }
        self.rawRepresentation = rawRepresentation
    }

    init(_ key: Curve25519.KeyAgreement.PublicKey) {
        rawRepresentation = Array(key.rawRepresentation)
    }

    var cryptoKey: Curve25519.KeyAgreement.PublicKey {
        try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation)
    }
}

extension AgreementPublicKey: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(rawRepresentation: decoder.singleValueContainer().decode([UInt8].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawRepresentation)
    }
}

private func ed25519Sign(_ key: Curve25519.Signing.PrivateKey, _ message: [UInt8]) throws(CryptoError) -> [UInt8] {
    do {
        return Array(try key.signature(for: message))
    } catch {
        throw .invalidKey
    }
}

func ed25519Verify(signature: [UInt8], message: [UInt8], publicKey: [UInt8]) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
    return key.isValidSignature(signature, for: message)
}
