public import Foundation
public import CirclesCrypto
public import CirclesPush

// Mobile push (docs/DESIGN.md §7.6): this device registers with a push relay;
// its pods learn the handle through their signed config and ping it when
// something arrives, so the device wakes and syncs.

extension Account {
    /// The push relays this device is registered with.
    public func pushTargets() -> [PushTarget] {
        ((try? files.load([PushTarget].self, from: files.push)) ?? nil) ?? []
    }

    /// Registers this device's platform push token with a push relay
    /// (`host:port#key`). Replaces any registration with the same relay; the
    /// handle reaches our pods on the next sync with them.
    @discardableResult
    public func registerPush(relay address: String, platform: PushPlatform, token: String, topic: String? = nil) async throws -> PushTarget {
        let relay = try PushClient.parse(address: address)
        let reply = try await PushClient.request(.register(platform: platform, token: token, topic: topic), host: relay.host,
                                                 port: Int(relay.port), key: relay.key, handshake: makeHandshake(role: .initiator))
        guard case .registered(let handle) = reply else {
            if case .refused(let reason) = reply { throw PushError.refused(reason) }
            throw PushError.unexpectedResponse
        }
        let target = PushTarget(host: relay.host, port: relay.port, key: relay.key, handle: handle)
        var targets = pushTargets().filter { $0.key != relay.key }
        targets.append(target)
        try files.save(targets, to: files.push, private: true)
        return target
    }

    /// Removes this device's registration with every push relay.
    public func unregisterPush() async throws {
        for target in pushTargets() {
            _ = try? await PushClient.request(.unregister(target.handle), host: target.host, port: Int(target.port),
                                              key: target.key, handshake: makeHandshake(role: .initiator))
        }
        try files.save([PushTarget](), to: files.push, private: true)
    }
}
