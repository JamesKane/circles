#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import CirclesCore
import Crypto

/// Delivers one circle-epoch key to one member (docs/DESIGN.md §8.1).
///
/// The grant is signed by one of the owner's devices, then sealed with HPKE
/// to each of the member's devices. The signature is inside the encryption,
/// so outsiders can't see who granted keys to whom.
struct KeyGrant: Codable {
    var owner: UserID
    var recipient: UserID
    var keyID: AudienceKeyID
    var epoch: UInt64
    var key: [UInt8]
}

/// A key grant encrypted to one device (HPKE base mode, DHKEM(X25519)/
/// HKDF-SHA256/ChaCha20-Poly1305).
public struct SealedKeyGrant: Sendable, Hashable, Codable {
    public let encapsulatedKey: [UInt8]
    public let ciphertext: [UInt8]

    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    /// Grants `key` to `recipient`, encrypted to one of their devices.
    public static func seal(
        _ key: AudienceKey,
        owner: UserID,
        recipient: UserID,
        to device: AgreementPublicKey,
        signedBy signer: borrowing DeviceKeyPair
    ) throws(CryptoError) -> SealedKeyGrant {
        let grant = KeyGrant(
            owner: owner, recipient: recipient, keyID: key.id, epoch: key.epoch,
            key: key.key.withUnsafeBytes { Array($0) }
        )
        let signed = try SignedObject(encoding: grant, label: .keyGrant, with: signer)
        let plaintext = try cborEncode(signed)
        do {
            var sender = try HPKE.Sender(recipientKey: device.cryptoKey, ciphersuite: ciphersuite, info: Context.keyGrantInfo)
            let ciphertext = try sender.seal(plaintext)
            return SealedKeyGrant(encapsulatedKey: Array(sender.encapsulatedKey), ciphertext: Array(ciphertext))
        } catch {
            throw .invalidKey
        }
    }

    init(encapsulatedKey: [UInt8], ciphertext: [UInt8]) {
        self.encapsulatedKey = encapsulatedKey
        self.ciphertext = ciphertext
    }

    /// Opens a grant addressed to `recipient` on this device, checking it was
    /// signed by an `.author` device of the key's owner at `receivedAtMillis`.
    /// Uses receive time, not a claimed time, so a revoked device can't
    /// backdate new grants.
    public func open(
        with device: borrowing DeviceKeyPair,
        recipient: UserID,
        owner: VerifiedIdentity,
        receivedAtMillis: UInt64
    ) throws(CryptoError) -> AudienceKey {
        let plaintext: [UInt8]
        do {
            var receiver = try HPKE.Recipient(
                privateKey: device.agreementKey, ciphersuite: Self.ciphersuite,
                info: Context.keyGrantInfo, encapsulatedKey: .init(encapsulatedKey)
            )
            plaintext = Array(try receiver.open(ciphertext))
        } catch {
            throw .decryptionFailed
        }
        let signed = try cborDecode(SignedObject.self, from: plaintext)
        let payload = try owner.verify(signed, label: .keyGrant, atMillis: receivedAtMillis)
        let grant = try cborDecode(KeyGrant.self, from: payload)
        guard grant.owner == owner.user, grant.recipient == recipient else { throw .identityMismatch }
        guard grant.key.count == 32 else { throw .invalidKey }
        return AudienceKey(id: grant.keyID, epoch: grant.epoch, key: SymmetricKey(data: grant.key))
    }
}
