public import CirclesCore

/// What a certified device may do.
public struct DeviceCapabilities: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// May sign content (posts, comments, +1s) and key grants as the user.
    public static let author = DeviceCapabilities(rawValue: 1 << 0)
    /// A pod: may store and serve the user's ciphertext, but not author.
    public static let storeAndForward = DeviceCapabilities(rawValue: 1 << 1)
}

/// The identity key's statement that a device belongs to the user
/// (docs/DESIGN.md §6.1). Signed with `SignatureLabel.deviceCertificate`.
public struct DeviceCertificate: Sendable, Hashable, Codable {
    public var user: UserID
    public var device: DeviceID
    public var agreementKey: AgreementPublicKey
    public var capabilities: DeviceCapabilities
    public var issuedMillis: UInt64
    public var expiresMillis: UInt64

    public init(
        user: UserID, device: DeviceID, agreementKey: AgreementPublicKey,
        capabilities: DeviceCapabilities, issuedMillis: UInt64, expiresMillis: UInt64
    ) {
        self.user = user
        self.device = device
        self.agreementKey = agreementKey
        self.capabilities = capabilities
        self.issuedMillis = issuedMillis
        self.expiresMillis = expiresMillis
    }

    public func isValid(atMillis millis: UInt64) -> Bool {
        issuedMillis <= millis && millis < expiresMillis
    }

    /// Certifies `device` as belonging to `identity`'s user.
    public static func issue(
        for device: borrowing DeviceKeyPair,
        by identity: borrowing IdentityKeyPair,
        capabilities: DeviceCapabilities,
        issuedMillis: UInt64,
        validForMillis: UInt64
    ) throws(CryptoError) -> SignedObject {
        let certificate = DeviceCertificate(
            user: identity.userID,
            device: device.deviceID,
            agreementKey: device.agreementPublicKey,
            capabilities: capabilities,
            issuedMillis: issuedMillis,
            expiresMillis: issuedMillis + validForMillis
        )
        return try SignedObject(signing: try cborEncode(certificate), label: .deviceCertificate, with: identity)
    }
}

public struct DeviceRevocation: Sendable, Hashable, Codable {
    public var device: DeviceID
    /// Objects the device signed at or after this time are rejected.
    public var revokedAtMillis: UInt64

    public init(device: DeviceID, revokedAtMillis: UInt64) {
        self.device = device
        self.revokedAtMillis = revokedAtMillis
    }
}

/// The user's signed list of current devices and revocations, published to
/// contacts and the DHT (docs/DESIGN.md §6.1). A higher `version` replaces a
/// lower one. Pod and relay hints are added with networking (M2–M3).
public struct IdentityDocument: Sendable, Hashable, Codable {
    public var user: UserID
    public var version: UInt64
    /// Signed `DeviceCertificate`s.
    public var certificates: [SignedObject]
    public var revocations: [DeviceRevocation]

    public init(user: UserID, version: UInt64, certificates: [SignedObject], revocations: [DeviceRevocation] = []) {
        self.user = user
        self.version = version
        self.certificates = certificates
        self.revocations = revocations
    }

    public func signed(by identity: borrowing IdentityKeyPair) throws(CryptoError) -> SignedObject {
        guard identity.userID == user else { throw .identityMismatch }
        return try SignedObject(signing: try cborEncode(self), label: .identityDocument, with: identity)
    }
}

/// An identity document whose signature and certificates have all been
/// checked. This is the only way to learn which devices may speak for a user.
public struct VerifiedIdentity: Sendable {
    public let user: UserID
    public let version: UInt64
    public let certificates: [DeviceID: DeviceCertificate]
    public let revocations: [DeviceID: UInt64]

    public init(verifying signed: SignedObject, for user: UserID) throws(CryptoError) {
        let payload = try signed.verifiedPayload(label: .identityDocument, signer: user.publicKey)
        let document = try cborDecode(IdentityDocument.self, from: payload)
        guard document.user == user else { throw .identityMismatch }

        var certificates: [DeviceID: DeviceCertificate] = [:]
        for signedCertificate in document.certificates {
            let bytes = try signedCertificate.verifiedPayload(label: .deviceCertificate, signer: user.publicKey)
            let certificate = try cborDecode(DeviceCertificate.self, from: bytes)
            guard certificate.user == user else { throw .identityMismatch }
            // On renewal both certificates may be listed; the later expiry wins.
            if let existing = certificates[certificate.device], existing.expiresMillis >= certificate.expiresMillis {
                continue
            }
            certificates[certificate.device] = certificate
        }

        self.user = user
        version = document.version
        self.certificates = certificates
        revocations = document.revocations.reduce(into: [:]) { result, revocation in
            result[revocation.device] = min(result[revocation.device] ?? .max, revocation.revokedAtMillis)
        }
    }

    /// The certificate that lets `device` act for this user at `millis`.
    public func certificate(
        for device: DeviceID, atMillis millis: UInt64, requiring capabilities: DeviceCapabilities
    ) throws(CryptoError) -> DeviceCertificate {
        guard let certificate = certificates[device] else { throw .unknownDevice(device) }
        if let revokedAt = revocations[device], millis >= revokedAt { throw .deviceRevoked(device) }
        guard certificate.isValid(atMillis: millis) else { throw .certificateNotValid(device, atMillis: millis) }
        guard certificate.capabilities.isSuperset(of: capabilities) else { throw .missingCapability(device) }
        return certificate
    }

    /// Verifies an object signed by one of this user's devices.
    ///
    /// `millis` is when the object is considered signed: the claimed creation
    /// time for content (old posts stay valid after revocation), and the
    /// receive time for things that must not be backdated, such as key grants.
    public func verify(
        _ object: SignedObject,
        label: SignatureLabel,
        atMillis millis: UInt64,
        requiring capabilities: DeviceCapabilities = .author
    ) throws(CryptoError) -> [UInt8] {
        guard let device = object.signerDevice else { throw .invalidKey }
        _ = try certificate(for: device, atMillis: millis, requiring: capabilities)
        return try object.verifiedPayload(label: label, signer: device.publicKey)
    }
}
