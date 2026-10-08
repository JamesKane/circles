public import CirclesCore
public import CirclesCrypto
import CirclesStorage
import CirclesSync

/// One of this user's devices, as the identity document lists it.
public struct DeviceSummary: Sendable, Hashable {
    public var device: DeviceID
    public var capabilities: DeviceCapabilities
    public var isThisDevice: Bool
    public var revoked: Bool
}

extension Account {
    /// The devices our identity document certifies.
    public func devices() throws -> [DeviceSummary] {
        let identity = try VerifiedIdentity(verifying: identityDocument, for: user)
        return identity.certificates.values.map { certificate in
            DeviceSummary(device: certificate.device, capabilities: certificate.capabilities,
                          isThisDevice: certificate.device == deviceID, revoked: identity.revocations[certificate.device] != nil)
        }.sorted { $0.device.description < $1.device.description }
    }

    /// Revokes one of our other devices, e.g. a lost phone or pod: its
    /// signatures from now on are rejected, and so is anything its log holds
    /// past the last entry we've seen, whatever time it claims. Its
    /// certificate stays, so what it signed before still verifies. A revoked
    /// pod's address is removed.
    public func revokeDevice(_ device: DeviceID) async throws {
        guard device != deviceID else { throw AccountError.cannotRevokeThisDevice }
        let identity = try VerifiedIdentity(verifying: identityDocument, for: user)
        guard identity.certificates[device] != nil else { throw AccountError.unknownDevice }
        let last = try await store.head(author: user, device: device)?.sequence ?? 0
        let revocation = DeviceRevocation(device: device, revokedAtMillis: wallClockMillis(), lastSequence: last)
        try await republish { document in
            document.revocations.removeAll { $0.device == device }
            document.revocations.append(revocation)
            if var endpoints = document.endpoints {
                endpoints.pods.removeAll { $0.device == device }
                endpoints.direct.removeAll { $0.device == device }
                document.endpoints = endpoints
            }
        }
    }
}
