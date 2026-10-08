public import Foundation
import CirclesCore
public import CirclesCrypto
import CirclesSync
public import CirclesNet
import CirclesStorage

/// The push relay server (docs/DESIGN.md §7.6, `circles-push`).
///
/// Registrations are bound to the registering device's Noise key: only that
/// device can update or remove its handle. Anyone holding a handle may ping
/// it, so handles go only to the owner's own pods. Pings are coalesced: a
/// handle is woken at most once per `minimumInterval`.
public actor PushRelay {
    struct Registration: Codable, Sendable {
        var device: AgreementPublicKey
        var platform: PushPlatform
        var token: String
        var topic: String?
    }

    public static let maxHandlesPerPing = 64
    public static let maxRegistrations = 100_000

    private var registrations: [PushHandle: Registration] = [:]
    private var lastWoken: [PushHandle: ContinuousClock.Instant] = [:]
    private let senders: [PushPlatform: any PushSender]
    private let minimumInterval: Duration
    private let file: URL?
    private let log: @Sendable (String) -> Void

    /// `file` keeps registrations across restarts (0600).
    public init(senders: [PushPlatform: any PushSender], file: URL?, minimumInterval: Duration = .seconds(30),
                log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.senders = senders
        self.file = file
        self.minimumInterval = minimumInterval
        self.log = log
        if let file, let bytes = try FileIO.read(file) {
            registrations = Dictionary(uniqueKeysWithValues: try CBORDecoder().decode([Stored].self, from: bytes).map { ($0.handle, $0.registration) })
        }
    }

    private struct Stored: Codable {
        var handle: PushHandle
        var registration: Registration
    }

    private func save() throws {
        guard let file else { return }
        let stored = registrations.map { Stored(handle: $0.key, registration: $0.value) }.sorted { $0.handle.bytes.lexicographicallyPrecedes($1.handle.bytes) }
        try FileIO.write(try CBOREncoder().encode(stored), to: file, private: true)
    }

    public var registrationCount: Int { registrations.count }

    /// Answers one request from the peer that proved `peer` in the handshake.
    public func handle(_ request: PushMessage, from peer: AgreementPublicKey?) async -> PushMessage {
        switch request {
        case .register(let platform, let token, let topic):
            guard let peer else { return .refused("unauthenticated") }
            guard senders[platform] != nil else { return .refused("this relay doesn't deliver to \(platform)") }
            guard !token.isEmpty, token.utf8.count <= 4096 else { return .refused("bad token") }
            let registration = Registration(device: peer, platform: platform, token: token, topic: topic)
            // One handle per device: re-registering keeps it.
            let handle = registrations.first { $0.value.device == peer }?.key ?? PushHandle.random()
            guard registrations[handle] != nil || registrations.count < Self.maxRegistrations else { return .refused("relay full") }
            registrations[handle] = registration
            do { try save() } catch { return .refused("couldn't save") }
            return .registered(handle)
        case .unregister(let handle):
            guard let registration = registrations[handle], registration.device == peer else { return .refused("not yours") }
            registrations[handle] = nil
            lastWoken[handle] = nil
            do { try save() } catch { return .refused("couldn't save") }
            return .ok
        case .ping(let handles):
            guard handles.count <= Self.maxHandlesPerPing else { return .refused("too many handles") }
            let now = ContinuousClock.now
            for handle in Set(handles) {
                guard let registration = registrations[handle], let sender = senders[registration.platform] else { continue }
                if let last = lastWoken[handle], now - last < minimumInterval { continue }
                lastWoken[handle] = now
                do {
                    try await sender.wake(token: registration.token, topic: registration.topic)
                } catch {
                    log("Couldn't wake a \(registration.platform) device: \(error)")
                }
            }
            // The same answer whether or not the handles exist, so pings
            // can't be used to probe for registrations.
            return .ok
        case .registered, .ok, .refused:
            return .refused("not a request")
        }
    }

    /// Serves requests on `listener` until cancelled.
    public func serve(_ listener: NoiseListener) async throws {
        try await listener.run { session in
            guard let frame = try await session.receive() else { return }
            let request = try CBORDecoder().decode(PushMessage.self, from: frame)
            let response = await self.handle(request, from: session.remoteStaticKey)
            try await session.send(try CBOREncoder().encode(response))
        }
    }
}

/// Talks to a push relay: one request, one response, over Noise with the
/// relay's key pinned.
public enum PushClient {
    public static func request(_ message: PushMessage, host: String, port: Int, key: AgreementPublicKey,
                               handshake: NoiseHandshake) async throws -> PushMessage {
        try await withNoiseConnection(host: host, port: port, handshake: handshake) { session in
            guard session.remoteStaticKey == key else { throw PushError.refused("wrong relay key") }
            try await session.send(try CBOREncoder().encode(message))
            guard let reply = try await session.receive() else { throw PushError.unexpectedResponse }
            return try CBORDecoder().decode(PushMessage.self, from: reply)
        }
    }

    /// Text for a push relay, `circles-push:` + host, port and key.
    public static func address(host: String, port: Int, key: AgreementPublicKey) -> String {
        "\(host):\(port)#\(Base32.encode(key.rawRepresentation))"
    }

    public static func parse(address text: String) throws -> (host: String, port: UInt16, key: AgreementPublicKey) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "#", maxSplits: 1)
        guard parts.count == 2, let colon = parts[0].lastIndex(of: ":"),
              let port = UInt16(parts[0][parts[0].index(after: colon)...]), let keyBytes = Base32.decode(parts[1])
        else { throw PushError.refused("not a push relay address (host:port#key)") }
        return (String(parts[0][..<colon]), port, try AgreementPublicKey(rawRepresentation: keyBytes))
    }
}
