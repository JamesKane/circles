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

@Suite("Managing contacts")
struct ContactManagementTests {
    @Test("renaming changes only our local name")
    func rename() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await alice.renameContact(bob.user, to: "  Bobby  ")
        #expect(await alice.contacts.map(\.name) == ["Bobby"])
        #expect(await alice.name(of: bob.user) == "Bobby")
        await #expect(throws: AccountError.self) { try await alice.renameContact(bob.user, to: " ") }
    }

    @Test("removing a contact takes them out of circles, so they can't read new posts")
    func remove() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await alice.createCircle("Friends")
        try await alice.addToCircle("Friends", members: [bob.user])
        try await alice.post(RichText(plain: "before"), to: .circles(["Friends"]))
        try await sync(bob, with: alice)

        try await alice.removeContact(bob.user)
        #expect(await alice.contacts.isEmpty)
        #expect(await alice.circles.first?.members.isEmpty == true)

        // Bob keeps the old post but can't read the new one. To deliver the
        // new post's ciphertext to him at all, Alice re-adds him as a contact
        // (not to the circle) and they sync.
        try await alice.post(RichText(plain: "after"), to: .circles(["Friends"]))
        try await alice.addContact(invite: await bob.invite())
        try await sync(bob, with: alice)
        #expect(try await bob.stream().map(\.body.plainText) == ["before"])
    }
}

@Suite("Deleting")
struct DeletionTests {
    @Test("an author's deletion hides the post for readers once they sync")
    func deletePost() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await alice.createCircle("Friends")
        try await alice.addToCircle("Friends", members: [bob.user])
        let id = try await alice.post(RichText(plain: "oops"), to: .circles(["Friends"]))
        try await alice.post(RichText(plain: "keep"), to: .everyone)
        try await sync(bob, with: alice)
        #expect(try await bob.stream().count == 2)

        try await alice.delete(post: id)
        #expect(try await alice.stream().map(\.body.plainText) == ["keep"])
        try await sync(bob, with: alice)
        #expect(try await bob.stream().map(\.body.plainText) == ["keep"])
        await #expect(throws: AccountError.notYours) { try await bob.delete(post: id) }
    }

    @Test("the author can remove a comment from their thread, for everyone including its writer")
    func removeComment() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        try await befriend(alice, bob)
        try await befriend(alice, carol)
        let post = try await alice.post(RichText(plain: "thoughts?"), to: .everyone)
        try await sync(bob, with: alice)
        try await bob.comment(RichText(plain: "something rude"), on: ObjectRef(author: alice.user, id: post))
        try await sync(alice, with: bob)
        let comment = try #require(try await alice.stream().first?.comments.first)

        try await alice.removeComment(comment.id, from: post)
        #expect(try await alice.stream().first?.comments.isEmpty == true)
        try await sync(carol, with: alice)
        #expect(try await carol.stream().first?.comments.isEmpty == true)
        // Bob's own copy doesn't come back as "pending" either.
        try await sync(bob, with: alice)
        #expect(try await bob.stream().first?.comments.isEmpty == true)
    }

    @Test("a deletion from anyone but the post's author is ignored")
    func forgedDeletion() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let mallory = try await Account.create(home: temporaryHome(), displayName: "Mallory")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await befriend(mallory, bob)
        let id = try await alice.post(RichText(plain: "mine"), to: .everyone)
        try await sync(bob, with: alice)
        // Mallory publishes a deletion naming Alice's post, in her own log.
        try await mallory.publishForgedDeletion(of: id)
        try await sync(bob, with: mallory)
        #expect(try await bob.stream().map(\.body.plainText) == ["mine"])
    }
}

extension Account {
    func publishForgedDeletion(of target: ContentID) async throws {
        let deletion = Deletion(author: user, target: target, created: try tick())
        let item = ContentItem(kind: .deletion, object: try signForTesting(deletion, label: .deletion))
        try await appendToLog(.publicContent(item))
    }
}

import CirclesCrypto
import CirclesSync
