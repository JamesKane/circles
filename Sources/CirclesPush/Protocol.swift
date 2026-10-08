import CirclesCore
public import CirclesCrypto

// The push relay (docs/DESIGN.md §7.6). Phones register their platform push
// token and get back an opaque handle, which they give to their own pods.
// A pod pings the handle when something arrives for its owner; the relay
// sends a content-free wake-up through APNs or FCM, and the phone syncs.
// The relay learns that a ping happened, never what it was about.

public enum PushPlatform: UInt64, Sendable, Hashable, Codable, CaseIterable {
    /// Apple Push Notification service.
    case apns = 0
    /// Firebase Cloud Messaging (Android).
    case fcm = 1
    /// Delivered to the relay's log only, for testing without credentials.
    case test = 2

    public init?(name: String) {
        switch name.lowercased() {
        case "apns", "ios", "apple": self = .apns
        case "fcm", "android": self = .fcm
        case "test": self = .test
        default: return nil
        }
    }
}

/// An opaque, unguessable name for one registration. Whoever holds it can
/// ask for a wake-up, so it's shared only with the owner's own pods.
public struct PushHandle: Sendable, Hashable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }

    public static func random() -> PushHandle {
        var generator = SystemRandomNumberGenerator()
        return PushHandle(bytes: (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public var description: String { Base32.encode(bytes) }

    public init(from decoder: any Decoder) throws {
        bytes = try decoder.singleValueContainer().decode([UInt8].self)
        guard bytes.count == 16 else { throw CBORError.custom("push handle must be 16 bytes") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

/// Where a pod sends pings for one of its owner's devices: the relay (with
/// its pinned key) and the handle.
public struct PushTarget: Sendable, Hashable, Codable {
    public var host: String
    public var port: UInt16
    public var key: AgreementPublicKey
    public var handle: PushHandle

    public init(host: String, port: UInt16, key: AgreementPublicKey, handle: PushHandle) {
        self.host = host
        self.port = port
        self.key = key
        self.handle = handle
    }
}

/// One request and one response per connection. Tags are permanent.
public enum PushMessage: Sendable, Hashable {
    /// From a device: register (or update) its push token. A device keeps
    /// one handle: registering again with a new token keeps the handle, so
    /// its pods needn't be told. `topic` is the app's bundle ID (APNs).
    case register(platform: PushPlatform, token: String, topic: String?)
    case registered(PushHandle)
    /// From the device that registered it.
    case unregister(PushHandle)
    /// From a pod: wake these devices.
    case ping([PushHandle])
    case ok
    case refused(String)
}

extension PushMessage: Codable {
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        switch try container.decode(UInt64.self) {
        case 0: self = .register(platform: try container.decode(PushPlatform.self), token: try container.decode(String.self),
                                 topic: try container.decode(String?.self))
        case 1: self = .registered(try container.decode(PushHandle.self))
        case 2: self = .unregister(try container.decode(PushHandle.self))
        case 3: self = .ping(try container.decode([PushHandle].self))
        case 4: self = .ok
        case 5: self = .refused(try container.decode(String.self))
        case let tag: throw CBORError.custom("unknown push message tag \(tag)")
        }
        guard container.isAtEnd else { throw CBORError.custom("trailing fields in push message") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .register(let platform, let token, let topic):
            try container.encode(UInt64(0)); try container.encode(platform); try container.encode(token); try container.encode(topic)
        case .registered(let handle):
            try container.encode(UInt64(1)); try container.encode(handle)
        case .unregister(let handle):
            try container.encode(UInt64(2)); try container.encode(handle)
        case .ping(let handles):
            try container.encode(UInt64(3)); try container.encode(handles)
        case .ok:
            try container.encode(UInt64(4))
        case .refused(let reason):
            try container.encode(UInt64(5)); try container.encode(reason)
        }
    }
}

public enum PushError: Error, Sendable, Equatable {
    case refused(String)
    case unexpectedResponse
    case notConfigured(PushPlatform)
    case delivery(status: Int, body: String)
    case invalidCredentials(String)
}
