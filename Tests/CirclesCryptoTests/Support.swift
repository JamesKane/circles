import CirclesCore
import CirclesCrypto

/// Deterministic generator so property-test failures are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &self) }
    }
}

/// A user with an identity key, one author device and a published identity
/// document. A class so it can hold the non-copyable key pairs.
final class TestUser {
    let identity: IdentityKeyPair
    let device: DeviceKeyPair
    let certificate: SignedObject
    let verified: VerifiedIdentity

    static let issued: UInt64 = 1_000_000
    static let validFor: UInt64 = 365 * 24 * 3600 * 1000

    init(capabilities: DeviceCapabilities = .author, revokedAtMillis: UInt64? = nil) throws {
        let identity = IdentityKeyPair()
        let device = DeviceKeyPair()
        let deviceID = device.deviceID
        let certificate = try DeviceCertificate.issue(
            for: device, by: identity, capabilities: capabilities,
            issuedMillis: Self.issued, validForMillis: Self.validFor
        )
        let revocations = revokedAtMillis.map { [DeviceRevocation(device: deviceID, revokedAtMillis: $0)] } ?? []
        let document = try IdentityDocument(
            user: identity.userID, version: 1, certificates: [certificate], revocations: revocations
        ).signed(by: identity)
        verified = try VerifiedIdentity(verifying: document, for: identity.userID)
        self.certificate = certificate
        self.identity = identity
        self.device = device
    }

    var userID: UserID { identity.userID }
}

/// Arrays can't hold non-copyable values, so tests box device keys.
final class DeviceBox {
    let keys = DeviceKeyPair()
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String($0 >> 4, radix: 16) + String($0 & 0xF, radix: 16) }.joined()
}
