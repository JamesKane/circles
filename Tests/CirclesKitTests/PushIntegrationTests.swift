import Testing
import Foundation
import CirclesCore
import CirclesCrypto
import CirclesNet
import CirclesPush
@testable import CirclesKit

@Suite("Push through pods")
struct PushIntegrationTests {
    @Test("a pod wakes its owner's phone when a contact's post arrives, not for the owner's own")
    func podWakesOwner() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")

        // A push relay on the test platform.
        let sender = RecordingSender()
        let relayKeys = try RelayIdentity(home: temporaryHome())
        let relay = try PushRelay(senders: [.test: sender], file: nil)
        let relayListener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: relayKeys.makeHandshake())
        let relayTask = Task { try await relay.serve(relayListener) }
        defer { relayTask.cancel() }
        let address = PushClient.address(host: "127.0.0.1", port: relayListener.port, key: relayKeys.agreementKey)

        // Alice's pod.
        let (pod, _) = try await PodNode.create(home: temporaryHome(), host: "127.0.0.1", port: 0)
        let podListener = try await pod.makeListener(host: "127.0.0.1", port: 0)
        try await pod.setAddress(host: "127.0.0.1", port: UInt16(podListener.port))
        _ = try await pod.pair(try await alice.addPod(await pod.pairingCode))
        let podTask = Task { try await podListener.run { session in _ = try await pod.respond(over: session) } }
        defer { podTask.cancel() }
        try await befriend(alice, bob)

        // Alice's phone registers; her next sync tells the pod.
        try await alice.registerPush(relay: address, platform: .test, token: "alice-phone")
        #expect(await relay.registrationCount == 1)
        try await alice.post(RichText(plain: "my own post"), to: .everyone)
        _ = try await alice.sync(host: "127.0.0.1", port: podListener.port)
        #expect(await pod.pushTargets.count == 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(sender.tokens.isEmpty) // her own entries don't wake her

        try await bob.post(RichText(plain: "hi Alice"), to: .everyone)
        _ = try await bob.sync(host: "127.0.0.1", port: podListener.port)
        for _ in 0..<30 where sender.tokens.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(sender.tokens == ["alice-phone"])

        // Unregistering removes it from the relay, and the pod at the next sync.
        try await alice.unregisterPush()
        #expect(await relay.registrationCount == 0)
        _ = try await alice.sync(host: "127.0.0.1", port: podListener.port)
        #expect(await pod.pushTargets.isEmpty)
    }
}
