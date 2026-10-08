import Testing
import Foundation
import CirclesCore
import CirclesNet
@testable import CirclesKit

/// `a` syncs with `b` over real TCP.
func sync(_ a: Account, with b: Account) async throws {
    try await serving(b) { port in _ = try await a.sync(host: "127.0.0.1", port: port) }
}

func befriend(_ a: Account, _ b: Account) async throws {
    try await a.addContact(invite: await b.invite())
    try await b.addContact(invite: await a.invite())
}

@Suite("Comments, +1s, reshares and media")
struct SocialTests {
    @Test("comments and +1s round-trip through the author, visible to the post's whole audience")
    func commentsAndPlusOnes() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        let dave = try await Account.create(home: temporaryHome(), displayName: "Dave")
        // Bob and Carol don't know each other; Dave is Alice's contact but not in Friends.
        for other in [bob, carol, dave] { try await befriend(alice, other) }
        try await alice.createCircle("Friends")
        try await alice.addToCircle("Friends", members: [bob.user, carol.user])
        let postID = try await alice.post(RichText(plain: "dinner on Friday?"), to: .circles(["Friends"]))
        let post = ObjectRef(author: alice.user, id: postID)

        try await sync(bob, with: alice)
        try await bob.comment(RichText(plain: "I'm in!"), on: post)
        try await bob.setPlusOne(true, on: post)

        // Before Alice republishes, only Bob sees his comment, marked pending.
        let bobsView = try #require(try await bob.stream().first { $0.id == postID })
        #expect(bobsView.comments.map(\.pending) == [true])
        #expect(bobsView.plusOnedByMe && bobsView.plusOnes == 1)

        try await sync(alice, with: bob)        // Alice receives Bob's contributions...
        let alicesView = try #require(try await alice.stream().first { $0.id == postID }) // ...and republishes them
        #expect(alicesView.comments.map(\.body.plainText) == ["I'm in!"])
        #expect(alicesView.plusOnes == 1)

        // Carol isn't Bob's contact, yet sees his comment under his public name.
        try await sync(carol, with: alice)
        let carolsView = try #require(try await carol.stream().first { $0.id == postID })
        #expect(carolsView.comments.map(\.authorName) == ["Bob"])
        #expect(carolsView.comments.first?.pending == false)
        #expect(carolsView.plusOnes == 1 && !carolsView.plusOnedByMe)

        // Dave, outside the circle, sees neither the post nor the thread.
        try await sync(dave, with: alice)
        #expect(try await dave.stream().contains { $0.id == postID } == false)

        // Bob withdraws his +1; once republished, the count drops for everyone.
        try await bob.setPlusOne(false, on: post)
        try await sync(alice, with: bob)
        _ = try await alice.stream()
        try await sync(carol, with: alice)
        #expect(try await carol.stream().first { $0.id == postID }?.plusOnes == 0)

        // Comments on your own post appear immediately.
        try await alice.comment(RichText(plain: "great, see you then"), on: post)
        #expect(try await alice.stream().first { $0.id == postID }?.comments.count == 2)
    }

    @Test("the author can turn comments off")
    func commentsDisabled() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        let id = try await alice.post(RichText(plain: "no comments please"), to: .everyone,
                                      replyPolicy: ReplyPolicy(commentsEnabled: false))
        try await sync(bob, with: alice)
        try await bob.comment(RichText(plain: "but…"), on: ObjectRef(author: alice.user, id: id))
        try await sync(alice, with: bob)
        let item = try #require(try await alice.stream().first { $0.id == id })
        #expect(item.comments.isEmpty && !item.commentsEnabled)
    }

    @Test("attachments are encrypted in chunks, synced with the post, and readable only by its audience")
    func attachments() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await alice.createCircle("Family")
        try await alice.addToCircle("Family", members: [bob.user])
        let photo = (0..<700_000).map { UInt8(truncatingIfNeeded: $0 &* 13) } // three chunks
        let id = try await alice.post(RichText(plain: "the beach"), to: .circles(["Family"]),
                                      attachments: [Attachment(data: photo, mediaType: "image/jpeg", width: 800, height: 600)])
        try await sync(bob, with: alice)
        let item = try #require(try await bob.stream().first { $0.id == id })
        let reference = try #require(item.attachments.first)
        #expect(reference.chunks.count == 3 && reference.mediaType == "image/jpeg")
        #expect(try await bob.attachmentData(reference) == photo)
    }

    @Test("public posts can be reshared with the original embedded; limited posts can't")
    func reshares() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        try await befriend(alice, bob)
        try await befriend(bob, carol) // Carol doesn't know Alice
        let publicID = try await alice.post(RichText(plain: "worth sharing"), to: .everyone)
        try await alice.createCircle("Friends")
        try await alice.addToCircle("Friends", members: [bob.user])
        let limitedID = try await alice.post(RichText(plain: "just us"), to: .circles(["Friends"]))
        try await sync(bob, with: alice)

        try await bob.reshare(ObjectRef(author: alice.user, id: publicID), comment: RichText(plain: "look at this"), to: .everyone)
        await #expect(throws: AccountError.unknownPost) {
            try await bob.reshare(ObjectRef(author: alice.user, id: limitedID), to: .everyone)
        }

        try await sync(carol, with: bob)
        let reshare = try #require(try await carol.stream().first { $0.author == bob.user })
        #expect(reshare.body.plainText == "look at this")
        #expect(reshare.reshared?.body.plainText == "worth sharing")
        #expect(reshare.reshared?.authorName == "Alice")
    }
}
