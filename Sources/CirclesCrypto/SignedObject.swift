public import CirclesCore

/// A payload plus an Ed25519 signature over `label || 0x00 || payload`.
///
/// The payload is kept as the exact bytes that were signed. Verification
/// always uses these bytes and never a re-encoding, because the decoder
/// ignores unknown fields (docs/DESIGN.md §7.4). The label isn't
/// transmitted: the verifier supplies the label it expects.
public struct SignedObject: Sendable, Hashable, Codable {
    public let payload: [UInt8]
    /// The raw Ed25519 public key that signed: a device key for content and
    /// grants, the identity key for certificates and identity documents.
    public let signer: [UInt8]
    public let signature: [UInt8]

    public init(payload: [UInt8], signer: [UInt8], signature: [UInt8]) {
        self.payload = payload
        self.signer = signer
        self.signature = signature
    }

    public init(signing payload: [UInt8], label: SignatureLabel, with identity: borrowing IdentityKeyPair) throws(CryptoError) {
        self.payload = payload
        signer = identity.userID.publicKey
        signature = try identity.sign(payload, label: label)
    }

    public init(signing payload: [UInt8], label: SignatureLabel, with device: borrowing DeviceKeyPair) throws(CryptoError) {
        self.payload = payload
        signer = device.deviceID.publicKey
        signature = try device.sign(payload, label: label)
    }

    /// Encodes `value` deterministically and signs it with a device key.
    /// Deliberately not an overload of `init(signing:)`: an array literal
    /// would silently pick this one and sign its CBOR encoding.
    public init(encoding value: some Encodable, label: SignatureLabel, with device: borrowing DeviceKeyPair) throws(CryptoError) {
        try self.init(signing: try cborEncode(value), label: label, with: device)
    }

    /// The ID of the signed object is the hash of its payload, so it stays
    /// the same whichever certified device signed it.
    public var contentID: ContentID { ContentID(hashing: payload) }

    public var signerDevice: DeviceID? { try? DeviceID(ed25519PublicKey: signer) }

    /// Returns the payload if it was signed by `expectedSigner` for `label`.
    public func verifiedPayload(label: SignatureLabel, signer expectedSigner: [UInt8]) throws(CryptoError) -> [UInt8] {
        guard signer == expectedSigner else { throw .unexpectedSigner }
        guard ed25519Verify(signature: signature, message: label.message(for: payload), publicKey: signer) else {
            throw .invalidSignature
        }
        return payload
    }
}

func cborEncode(_ value: some Encodable) throws(CryptoError) -> [UInt8] {
    do {
        return try CBOREncoder().encode(value)
    } catch {
        throw .encoding(error)
    }
}

func cborDecode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws(CryptoError) -> T {
    do {
        return try CBORDecoder().decode(type, from: bytes)
    } catch {
        throw .encoding(error)
    }
}
