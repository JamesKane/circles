#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
public import CirclesCore
import Crypto

/// Who an envelope is for: circle-epoch keys, plus individually named devices.
public struct EnvelopeAudience: Sendable {
    public var audienceKeys: [AudienceKey]
    public var devices: [AgreementPublicKey]

    public init(audienceKeys: [AudienceKey] = [], devices: [AgreementPublicKey] = []) {
        self.audienceKeys = audienceKeys
        self.devices = devices
    }
}

/// Non-public content, encrypted to an audience (docs/DESIGN.md §8.2).
///
/// - The plaintext (normally an encoded `SignedObject`) is padded, then
///   encrypted with a fresh content key (CEK) using ChaCha20-Poly1305. The
///   associated data binds the version and author.
/// - The CEK is wrapped once per circle-epoch key (looked up by opaque
///   `AudienceKeyID`) and once per individually named device using HPKE.
///   Device wraps carry no recipient hint, so a device finds its own by trial
///   decryption: one X25519 operation per device wrap.
/// - Each wrap's associated data includes the body nonce, binding it to
///   this envelope.
/// - Wraps are sorted by their (random) bytes, so their order reveals nothing.
public struct Envelope: Sendable, Hashable, Codable {
    public static let currentVersion: UInt64 = 1

    public let version: UInt64
    public let author: UserID
    public let nonce: [UInt8]
    /// Ciphertext followed by the 16-byte Poly1305 tag.
    public let ciphertext: [UInt8]
    public let audienceWraps: [AudienceWrap]
    public let deviceWraps: [DeviceWrap]

    public struct AudienceWrap: Sendable, Hashable, Codable {
        public let keyID: AudienceKeyID
        /// ChaCha20-Poly1305 combined form: nonce || ciphertext || tag.
        public let sealedKey: [UInt8]
    }

    public struct DeviceWrap: Sendable, Hashable, Codable {
        public let encapsulatedKey: [UInt8]
        public let sealedKey: [UInt8]
    }

    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    // MARK: Sealing

    /// At most this many wraps of each kind. Opening may trial-decrypt every
    /// device wrap (one HPKE operation each), so an unbounded count would let
    /// any author make readers burn CPU. Real audiences are far smaller.
    public static let maxWraps = 256

    public static func seal(_ plaintext: [UInt8], author: UserID, to audience: EnvelopeAudience) throws(CryptoError) -> Envelope {
        guard audience.devices.count <= maxWraps, audience.audienceKeys.count <= maxWraps else { throw .audienceTooLarge }
        let cek = SymmetricKey(size: .bits256)
        let nonce = ChaChaPoly.Nonce()
        let nonceBytes = Array(nonce)
        let cekBytes = cek.withUnsafeBytes { Array($0) }
        let wrapAAD = Context.cekWrap + nonceBytes

        do {
            let body = try ChaChaPoly.seal(
                Padding.pad(plaintext), using: cek, nonce: nonce,
                authenticating: bodyAAD(version: currentVersion, author: author)
            )

            let audienceWraps = try audience.audienceKeys.map { key in
                AudienceWrap(
                    keyID: key.id,
                    sealedKey: Array(try ChaChaPoly.seal(cekBytes, using: key.key, authenticating: wrapAAD).combined)
                )
            }
            let deviceWraps = try audience.devices.map { device in
                var sender = try HPKE.Sender(recipientKey: device.cryptoKey, ciphersuite: ciphersuite, info: Context.cekWrapInfo)
                let sealed = try sender.seal(cekBytes, authenticating: wrapAAD)
                return DeviceWrap(encapsulatedKey: Array(sender.encapsulatedKey), sealedKey: Array(sealed))
            }

            return Envelope(
                version: currentVersion,
                author: author,
                nonceBytes: nonceBytes,
                ciphertext: Array(body.ciphertext) + Array(body.tag),
                audienceWraps: audienceWraps.sorted { $0.keyID.bytes.lexicographicallyPrecedes($1.keyID.bytes) },
                deviceWraps: deviceWraps.sorted { $0.encapsulatedKey.lexicographicallyPrecedes($1.encapsulatedKey) }
            )
        } catch {
            throw .invalidKey
        }
    }

    /// Signs `value` with `device`, then seals the signed object.
    public static func seal(
        _ value: some Encodable, label: SignatureLabel, signedBy device: borrowing DeviceKeyPair,
        author: UserID, to audience: EnvelopeAudience
    ) throws(CryptoError) -> Envelope {
        let signed = try SignedObject(encoding: value, label: label, with: device)
        return try seal(try cborEncode(signed), author: author, to: audience)
    }

    init(
        version: UInt64, author: UserID, nonceBytes: [UInt8], ciphertext: [UInt8],
        audienceWraps: [AudienceWrap], deviceWraps: [DeviceWrap]
    ) {
        self.version = version
        self.author = author
        nonce = nonceBytes
        self.ciphertext = ciphertext
        self.audienceWraps = audienceWraps
        self.deviceWraps = deviceWraps
    }

    // MARK: Opening

    /// Opens with circle keys from `keyring` only.
    public func open(keyring: AudienceKeyring) throws(CryptoError) -> [UInt8] {
        try openBody(cek: try unwrapWithKeyring(keyring))
    }

    /// Opens with circle keys from `keyring`, falling back to trial decryption
    /// of the device wraps with `device`.
    public func open(keyring: AudienceKeyring, device: borrowing DeviceKeyPair) throws(CryptoError) -> [UInt8] {
        if let cek = try? unwrapWithKeyring(keyring) {
            return try openBody(cek: cek)
        }
        return try openBody(cek: try unwrapWithDevice(device))
    }

    /// Opens, then decodes the plaintext as a `SignedObject`. The caller
    /// still has to verify it against the author's `VerifiedIdentity`.
    public func openSignedObject(keyring: AudienceKeyring, device: borrowing DeviceKeyPair) throws(CryptoError) -> SignedObject {
        try cborDecode(SignedObject.self, from: try open(keyring: keyring, device: device))
    }

    private var wrapAAD: [UInt8] { Context.cekWrap + nonce }

    private func unwrapWithKeyring(_ keyring: AudienceKeyring) throws(CryptoError) -> SymmetricKey {
        try checkVersion()
        for wrap in audienceWraps {
            guard let key = keyring.key(owner: author, id: wrap.keyID) else { continue }
            guard let box = try? ChaChaPoly.SealedBox(combined: wrap.sealedKey),
                  let cek = try? ChaChaPoly.open(box, using: key.key, authenticating: wrapAAD)
            else { throw .decryptionFailed }
            return SymmetricKey(data: cek)
        }
        throw .notARecipient
    }

    private func unwrapWithDevice(_ device: borrowing DeviceKeyPair) throws(CryptoError) -> SymmetricKey {
        try checkVersion()
        for wrap in deviceWraps {
            guard var receiver = try? HPKE.Recipient(
                privateKey: device.agreementKey, ciphersuite: Self.ciphersuite,
                info: Context.cekWrapInfo, encapsulatedKey: Data(wrap.encapsulatedKey)
            ) else { continue }
            if let cek = try? receiver.open(wrap.sealedKey, authenticating: wrapAAD) {
                return SymmetricKey(data: cek)
            }
        }
        throw .notARecipient
    }

    private func openBody(cek: SymmetricKey) throws(CryptoError) -> [UInt8] {
        guard ciphertext.count >= 16,
              let nonce = try? ChaChaPoly.Nonce(data: nonce),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16)),
              let padded = try? ChaChaPoly.open(box, using: cek, authenticating: Self.bodyAAD(version: version, author: author))
        else { throw .decryptionFailed }
        return try Padding.unpad(Array(padded))
    }

    private func checkVersion() throws(CryptoError) {
        guard version == Self.currentVersion else { throw .unsupportedVersion(version) }
        guard deviceWraps.count <= Self.maxWraps, audienceWraps.count <= Self.maxWraps else { throw .audienceTooLarge }
    }

    private static func bodyAAD(version: UInt64, author: UserID) -> [UInt8] {
        Context.envelopeBody + Varint.encode(version) + author.multicodecBytes
    }
}
