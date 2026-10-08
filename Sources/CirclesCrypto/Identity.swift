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

    /// Certifies a device known only by its public keys, such as a pod
    /// paired from a pairing code.
    public static func issue(
        device: DeviceID,
        agreementKey: AgreementPublicKey,
        by identity: borrowing IdentityKeyPair,
        capabilities: DeviceCapabilities,
        issuedMillis: UInt64,
        validForMillis: UInt64
    ) throws(CryptoError) -> SignedObject {
        let certificate = DeviceCertificate(
            user: identity.userID, device: device, agreementKey: agreementKey, capabilities: capabilities,
            issuedMillis: issuedMillis, expiresMillis: issuedMillis + validForMillis
        )
        return try SignedObject(signing: try cborEncode(certificate), label: .deviceCertificate, with: identity)
    }
}

/// Where a user can be reached besides the local network
/// (docs/DESIGN.md §6.1, §7.2).
public struct Endpoints: Sendable, Hashable, Codable {
    /// The user's pods. Each must also have a `.storeAndForward` certificate.
    public var pods: [PodEndpoint] = []
    /// Relays the user's devices keep reservations on.
    public var relays: [RelayEndpoint] = []
    /// Publicly reachable addresses of the user's devices (e.g. from router
    /// port mapping). Opt-in, because it reveals the address to everyone who
    /// gets the identity document.
    public var direct: [DirectEndpoint] = []

    public init(pods: [PodEndpoint] = [], relays: [RelayEndpoint] = [], direct: [DirectEndpoint] = []) {
        self.pods = pods
        self.relays = relays
        self.direct = direct
    }

    public var isEmpty: Bool { pods.isEmpty && relays.isEmpty && direct.isEmpty }

    private enum CodingKeys: String, CodingKey { case pods, relays, direct }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pods = try container.decodeIfPresent([PodEndpoint].self, forKey: .pods) ?? []
        relays = try container.decodeIfPresent([RelayEndpoint].self, forKey: .relays) ?? []
        direct = try container.decodeIfPresent([DirectEndpoint].self, forKey: .direct) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !pods.isEmpty { try container.encode(pods, forKey: .pods) }
        if !relays.isEmpty { try container.encode(relays, forKey: .relays) }
        if !direct.isEmpty { try container.encode(direct, forKey: .direct) }
    }
}

public struct PodEndpoint: Sendable, Hashable, Codable {
    public var device: DeviceID
    public var host: String
    public var port: UInt16

    public init(device: DeviceID, host: String, port: UInt16) {
        self.device = device
        self.host = host
        self.port = port
    }
}

public struct RelayEndpoint: Sendable, Hashable, Codable {
    public var host: String
    public var port: UInt16
    /// The relay's Noise static key, so clients can tell they reached the
    /// real relay.
    public var key: AgreementPublicKey

    public init(host: String, port: UInt16, key: AgreementPublicKey) {
        self.host = host
        self.port = port
        self.key = key
    }
}

public struct DirectEndpoint: Sendable, Hashable, Codable {
    public var device: DeviceID
    public var host: String
    public var port: UInt16

    public init(device: DeviceID, host: String, port: UInt16) {
        self.device = device
        self.host = host
        self.port = port
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
    /// Added in M3; absent in older documents.
    public var endpoints: Endpoints?
    /// The name the user goes by publicly, shown to people who aren't their
    /// contacts (e.g. other commenters on a post). Contacts see their own
    /// petname instead. Added in M4.
    public var displayName: String?

    public init(
        user: UserID, version: UInt64, certificates: [SignedObject],
        revocations: [DeviceRevocation] = [], endpoints: Endpoints? = nil, displayName: String? = nil
    ) {
        self.user = user
        self.version = version
        self.certificates = certificates
        self.revocations = revocations
        self.endpoints = endpoints?.isEmpty == true ? nil : endpoints
        self.displayName = displayName
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
    public let endpoints: Endpoints
    /// The document itself, for publishing a new version.
    public let document: IdentityDocument

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
        endpoints = document.endpoints ?? Endpoints()
        self.document = document
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

    /// The certified device whose Noise static key is `key`, if any is
    /// currently valid (not expired, not revoked).
    public func device(withAgreementKey key: AgreementPublicKey, atMillis millis: UInt64) -> DeviceCertificate? {
        certificates.values.first { certificate in
            certificate.agreementKey == key
                && (try? self.certificate(for: certificate.device, atMillis: millis, requiring: [])) != nil
        }
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
