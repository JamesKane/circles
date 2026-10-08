public import Foundation
public import CirclesCrypto
import CirclesCore
import CirclesStorage

/// A relay's persistent Noise key. Relays have no user identity; peers pin
/// this key so they know they reached the real relay.
public final class RelayIdentity: Sendable {
    private let device: DeviceKeyPair
    public let agreementKey: AgreementPublicKey

    private struct Stored: Codable {
        var signing: [UInt8]
        var agreement: [UInt8]
    }

    /// Loads the key from `home`, creating it on first use.
    public init(home: URL) throws {
        let url = home.appendingPathComponent("relay").appendingPathComponent("key.cbor")
        if let bytes = try FileIO.read(url) {
            let stored = try CBORDecoder().decode(Stored.self, from: bytes)
            device = try DeviceKeyPair(signingKey: stored.signing, agreementKey: stored.agreement)
        } else {
            let device = DeviceKeyPair()
            let raw = device.exportRawRepresentation()
            try FileIO.write(try CBOREncoder().encode(Stored(signing: raw.signingKey, agreement: raw.agreementKey)),
                             to: url, private: true)
            self.device = device
        }
        agreementKey = device.agreementPublicKey
    }

    public func makeHandshake() -> NoiseHandshake {
        NoiseHandshake(role: .responder, device: device)
    }

    /// `host:port#key`, the string users paste into `circles relay add`.
    public func address(host: String, port: Int) -> String {
        "\(host):\(port)#\(Base32.encode(agreementKey.rawRepresentation))"
    }

    public static func parse(address text: String) throws -> RelayEndpoint {
        let parts = text.split(separator: "#", maxSplits: 1)
        guard parts.count == 2, let colon = parts[0].lastIndex(of: ":"),
              let port = UInt16(parts[0][parts[0].index(after: colon)...]),
              let keyBytes = Base32.decode(parts[1])
        else { throw AccountError.invalidInvite }
        return RelayEndpoint(host: String(parts[0][..<colon]), port: port,
                             key: try AgreementPublicKey(rawRepresentation: keyBytes))
    }
}
