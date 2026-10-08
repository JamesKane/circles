import Foundation
import CirclesCore
import CirclesCrypto
import CirclesSync

/// Reads the file-based log store used before M4:
///
///     <root>/logs/<author>/<device>/<sequence, zero-padded>.cbor
///     <root>/identities/<user>.cbor
///
/// Only used to migrate old data into `SQLiteLogStore`.
struct LegacyFileLogReader {
    let root: URL

    private static func user(_ name: String) -> UserID? { Base32.decode(name).flatMap { try? UserID(multicodecBytes: $0) } }
    private static func device(_ name: String) -> DeviceID? { Base32.decode(name).flatMap { try? DeviceID(multicodecBytes: $0) } }

    private var logs: URL { root.appendingPathComponent("logs") }

    func authors() -> [UserID] {
        FileIO.contents(of: logs).compactMap(Self.user)
    }

    func devices(of author: UserID) -> [DeviceID] {
        FileIO.contents(of: logs.appendingPathComponent(Base32.encode(author.multicodecBytes))).compactMap(Self.device)
    }

    func entries(author: UserID, device: DeviceID) -> [SignedObject] {
        let directory = logs.appendingPathComponent(Base32.encode(author.multicodecBytes))
            .appendingPathComponent(Base32.encode(device.multicodecBytes))
        return FileIO.contents(of: directory)
            .filter { $0.hasSuffix(".cbor") }
            .sorted()
            .compactMap { try? FileIO.read(directory.appendingPathComponent($0)) }
            .compactMap { try? CBORDecoder().decode(SignedObject.self, from: $0) }
    }

    func identityDocuments() -> [SignedObject] {
        let directory = root.appendingPathComponent("identities")
        return FileIO.contents(of: directory)
            .compactMap { try? FileIO.read(directory.appendingPathComponent($0)) }
            .compactMap { try? CBORDecoder().decode(SignedObject.self, from: $0) }
    }
}
