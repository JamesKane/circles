import Testing
import Foundation
import CirclesCore
import CirclesCrypto
import CirclesSync
import CirclesNet
import CirclesStorage
@testable import CirclesKit

func temporaryHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("circles-test-\(UUID().uuidString)")
}

/// Serves `account`'s sync engine on a random local port for the duration of `body`.
func serving<R>(_ account: Account, _ body: (Int) async throws -> R) async throws -> R {
    let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await account.makeHandshake(role: .responder))
    let engine = await account.syncEngine()
    let task = Task { try await listener.run { session in _ = try await engine.run(over: session) } }
    defer { task.cancel() }
    return try await body(listener.port)
}

@Suite("Account end to end")
struct AccountTests {
    @Test("circles control who reads what, over real TCP")
    func circlesEndToEnd() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        for (a, b) in [(alice, bob), (bob, alice), (alice, carol), (carol, alice)] {
            try await a.addContact(invite: await b.invite())
        }

        try await alice.createCircle("Friends")
        try await alice.addToCircle("Friends", members: [bob.user])
        try await alice.post(RichText(plain: "Hello, world"), to: .everyone)
        try await alice.post(RichText(plain: "Friends only"), to: .circles(["Friends"]))

        try await serving(alice) { port in
            _ = try await bob.sync(host: "127.0.0.1", port: port)
            _ = try await carol.sync(host: "127.0.0.1", port: port)
        }
        #expect(try await bob.stream().map(\.body.plainText) == ["Friends only", "Hello, world"])
        #expect(try await carol.stream().map(\.body.plainText) == ["Hello, world"])
        #expect(try await bob.stream().first?.audience == .limited)
        #expect(try await bob.stream().first?.authorName == "Alice")

        // Removing Bob rotates the key: he keeps the old post but can't read new ones.
        try await alice.removeFromCircle("Friends", members: [bob.user])
        try await alice.post(RichText(plain: "After Bob left"), to: .circles(["Friends"]))
        try await serving(alice) { port in _ = try await bob.sync(host: "127.0.0.1", port: port) }
        #expect(try await bob.stream().map(\.body.plainText) == ["Friends only", "Hello, world"])
        #expect(try await alice.stream().map(\.body.plainText) == ["After Bob left", "Friends only", "Hello, world"])
    }

    @Test("an account survives being reopened")
    func reopen() async throws {
        let home = temporaryHome()
        let created = try await Account.create(home: home, displayName: "Dana")
        try await created.createCircle("Family")
        try await created.post(RichText(plain: "kept"), to: .circles(["Family"]))
        let reopened = try await Account.open(home: home)
        #expect(reopened.user == created.user)
        #expect(await reopened.circles.map(\.name) == ["Family"])
        #expect(try await reopened.stream().map(\.body.plainText) == ["kept"])
        await #expect(throws: AccountError.alreadyExists) { try await Account.create(home: home, displayName: "Dana") }
    }

    @Test("invites round-trip and reject garbage")
    func invites() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let invite = try Invite(text: await alice.invite())
        #expect(invite.name == "Alice")
        #expect(throws: AccountError.invalidInvite) { try Invite(text: "circles-invite:!!") }
    }

    @Test("a contact can't be confused with a non-contact")
    func strangersAreRefused() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let mallory = try await Account.create(home: temporaryHome(), displayName: "Mallory")
        try await mallory.addContact(invite: await alice.invite()) // one-sided
        try await alice.post(RichText(plain: "not for strangers"), to: .everyone)
        await #expect(throws: (any Error).self) {
            try await serving(alice) { port in _ = try await mallory.sync(host: "127.0.0.1", port: port) }
        }
        #expect(try await mallory.stream().isEmpty)
    }
}

extension SealedKeyGrant {
    static var stub: SealedKeyGrant {
        struct Stub: Codable { var encapsulatedKey: [UInt8] = [1]; var ciphertext: [UInt8] = [2] }
        return try! CBORDecoder().decode(SealedKeyGrant.self, from: CBOREncoder().encode(Stub()))
    }
}
