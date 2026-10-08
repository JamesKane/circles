import Testing
import Foundation
import CirclesCore
import CirclesNet
import CirclesCrypto
import CirclesSync
@testable import CirclesKit

/// Serves `community` from its owner over real TCP.
func servingCommunity<R>(_ owner: Account, _ community: UserID, _ body: (Int) async throws -> R) async throws -> R {
    let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await owner.makeHandshake(role: .responder))
    let engine = try await owner.communityEngine(community)
    let task = Task { try await listener.run { session in _ = try await engine.run(over: session) } }
    defer { task.cancel() }
    return try await body(listener.port)
}

/// One round: the member syncs with the community (twice, so a request
/// admitted mid-session is followed by its result), then both sides process.
func round(_ owner: Account, _ community: UserID, _ members: Account...) async throws {
    try await servingCommunity(owner, community) { port in
        for member in members {
            _ = try await member.sync(host: "127.0.0.1", port: port)
            _ = try await member.sync(host: "127.0.0.1", port: port)
        }
    }
    try await owner.processCommunities()
    for member in members { try await member.processCommunities() }
}

func feed(_ account: Account, _ community: UserID) async throws -> [String] {
    try await account.communityFeed(community).map(\.body.plainText)
}

@Suite("Communities end to end")
struct CommunityTests {
    @Test("open community: join, post through the sequencer, comment and +1; private ones read from join onward",
          arguments: [CommunityVisibility.private, .public])
    func openCommunity(visibility: CommunityVisibility) async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        let community = try await alice.createCommunity(name: "Hikers", visibility: visibility, joinPolicy: .open)
        try await alice.post(RichText(plain: "before anyone"), toCommunity: community)

        let invite = try await alice.communityInvite(community)
        try await bob.joinCommunity(invite: invite)
        #expect(try await bob.communities().first?.role == .pending)
        try await round(alice, community, bob)
        #expect(try await bob.communities().first?.role == .member)
        #expect(Set(try await bob.communityMembers(community).map(\.user)) == [alice.user, bob.user])
        // Private: history from join onward. Public: the whole log is readable.
        #expect(try await feed(bob, community) == (visibility == .private ? [] : ["before anyone"]))

        let postID = try await bob.post(RichText(plain: "Trail report"), toCommunity: community)
        try await round(alice, community, bob)   // the sequencer collects and republishes
        try await round(alice, community, bob)   // bob reads the republished post
        #expect(try await feed(alice, community).first == "Trail report")
        #expect(try await feed(bob, community).first == "Trail report")
        #expect(try await bob.communityFeed(community).first?.authorName == "Bob")

        try await carol.joinCommunity(invite: invite)
        try await round(alice, community, carol)
        let ref = ObjectRef(author: bob.user, id: postID)
        try await carol.comment(RichText(plain: "Nice!"), on: ref, inCommunity: community)
        try await carol.setPlusOne(true, on: ref, inCommunity: community)
        try await round(alice, community, carol)
        try await round(alice, community, bob, carol)
        let seen = try #require(try await bob.communityFeed(community).first { $0.id == postID })
        #expect(seen.comments.map(\.body.plainText) == ["Nice!"])
        #expect(seen.plusOnes == 1)
    }

    @Test("approval: requests wait for the owner; removal locks a member out of a private community")
    func approvalAndRemoval() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        let community = try await alice.createCommunity(name: "Book club", visibility: .private, joinPolicy: .approval)
        let invite = try await alice.communityInvite(community)
        try await bob.joinCommunity(invite: invite)
        try await carol.joinCommunity(invite: invite)
        try await round(alice, community, bob, carol)
        #expect(try await bob.communities().first?.role == .pending)
        let waiting = try #require(try await alice.communities().first).pendingRequests
        #expect(Set(waiting.map(\.user)) == [bob.user, carol.user])
        #expect(waiting.contains { $0.name == "Bob" })

        try await alice.approveJoin(bob.user, in: community)
        try await alice.approveJoin(carol.user, in: community)
        try await round(alice, community, bob, carol)
        #expect(try await bob.communities().first?.role == .member)
        #expect(try await carol.communities().first?.role == .member)

        try await alice.removeFromCommunity([carol.user], in: community)
        try await alice.post(RichText(plain: "after carol"), toCommunity: community)
        try await round(alice, community, bob, carol)
        #expect(try await carol.communities().first?.role == .removed)
        #expect(try await feed(bob, community) == ["after carol"])
        #expect(try await feed(carol, community).isEmpty)
        #expect(Set(try await bob.communityMembers(community).map(\.user)) == [alice.user, bob.user])
    }

    @Test("invite-only: a request needs a valid token, optionally for one person")
    func inviteOnly() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let mallory = try await Account.create(home: temporaryHome(), displayName: "Mallory")
        let community = try await alice.createCommunity(name: "Secret", visibility: .private, joinPolicy: .inviteOnly)

        try await bob.joinCommunity(invite: try await alice.communityInvite(community, for: bob.user))
        // Mallory reuses Bob's personal invite.
        try await mallory.joinCommunity(invite: try await alice.communityInvite(community, for: bob.user))
        try await round(alice, community, bob, mallory)
        #expect(try await bob.communities().first?.role == .member)
        #expect(try await mallory.communities().first?.role == .pending)

        let expired = try await alice.communityInvite(community, validFor: .zero)
        let eve = try await Account.create(home: temporaryHome(), displayName: "Eve")
        try await eve.joinCommunity(invite: expired)
        try await round(alice, community, eve)
        #expect(try await eve.communities().first?.role == .pending)
    }

    @Test("the owner can remove an item; non-members can't post")
    func moderation() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let community = try await alice.createCommunity(name: "Open", visibility: .public, joinPolicy: .open)
        await #expect(throws: CommunityError.unknownCommunity) {
            try await bob.post(RichText(plain: "hi"), toCommunity: community)
        }
        try await bob.joinCommunity(invite: try await alice.communityInvite(community))
        try await round(alice, community, bob)
        let spam = try await bob.post(RichText(plain: "spam"), toCommunity: community)
        try await round(alice, community, bob)
        try await round(alice, community, bob)
        #expect(try await feed(bob, community) == ["spam"])
        try await alice.removeCommunityItem(spam, from: community)
        try await round(alice, community, bob)
        #expect(try await feed(bob, community).isEmpty)
        #expect(try await feed(alice, community).isEmpty)
    }

    @Test("community state survives reopening the account")
    func persistence() async throws {
        let home = temporaryHome()
        let alice = try await Account.create(home: home, displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let community = try await alice.createCommunity(name: "Durable", visibility: .private, joinPolicy: .open)
        try await bob.joinCommunity(invite: try await alice.communityInvite(community))
        try await round(alice, community, bob)

        let reopened = try await Account.open(home: home)
        try await reopened.post(RichText(plain: "after restart"), toCommunity: community)
        try await round(reopened, community, bob)
        #expect(try await feed(bob, community) == ["after restart"])
    }
}

@Suite("Communities through the node")
struct CommunityNodeTests {
    @Test("one listener answers as the owner and as the community; members find it from its identity document")
    func oneListener() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await alice.makeHandshake(role: .responder))
        let task = Task { try await listener.run { session in _ = try await alice.respond(over: session) } }
        defer { task.cancel() }

        let community = try await alice.createCommunity(name: "Hikers", visibility: .private, joinPolicy: .open)
        // Publishing our address re-signs the community's document too.
        try await alice.setDirectEndpoint(host: "127.0.0.1", port: listener.port)
        try await bob.joinCommunity(invite: try await alice.communityInvite(community))

        _ = await bob.syncAll(discoveryTimeout: .milliseconds(10))   // join request; admitted
        _ = await bob.syncAll(discoveryTimeout: .milliseconds(10))   // reads the Welcome
        #expect(try await bob.communities().first?.role == .member)

        try await bob.post(RichText(plain: "hello hikers"), toCommunity: community)
        _ = await bob.syncAll(discoveryTimeout: .milliseconds(10))   // alice collects and republishes on receipt
        _ = await bob.syncAll(discoveryTimeout: .milliseconds(10))
        #expect(try await feed(alice, community) == ["hello hikers"])
        #expect(try await feed(bob, community) == ["hello hikers"])

        // The same listener still answers as Alice herself.
        try await bob.addContact(invite: await alice.invite())
        try await alice.addContact(invite: await bob.invite())
        try await alice.post(RichText(plain: "personal"), to: .everyone)
        let report = try await bob.sync(host: "127.0.0.1", port: listener.port)
        #expect(report.peer == alice.user)
        #expect(try await bob.stream().map(\.body.plainText).contains("personal"))
    }

    @Test("asking a device for a community it doesn't serve fails")
    func unknownTarget() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await alice.makeHandshake(role: .responder))
        let task = Task { try await listener.run { session in _ = try await alice.respond(over: session) } }
        defer { task.cancel() }
        await #expect(throws: (any Error).self) {
            try await bob.sync(host: "127.0.0.1", port: listener.port, target: bob.user)
        }
    }
}

@Suite("Communities through pods")
struct CommunityPodTests {
    @Test("the owner's pod carries a private community while the owner is offline")
    func podServesCommunity() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        let (pod, _) = try await PodNode.create(home: temporaryHome(), host: "127.0.0.1", port: 0)
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await pod.makeHandshake(role: .responder))
        try await pod.setAddress(host: "127.0.0.1", port: UInt16(listener.port))
        _ = try await pod.pair(try await alice.addPod(await pod.pairingCode))
        let podTask = Task { try await listener.run { session in _ = try await pod.respond(over: session) } }
        defer { podTask.cancel() }

        let community = try await alice.createCommunity(name: "Night owls", visibility: .private, joinPolicy: .open)
        let invite = try await alice.communityInvite(community)
        try await bob.joinCommunity(invite: invite)
        try await carol.joinCommunity(invite: invite)
        try await round(alice, community, bob, carol)   // joining needs the owner
        #expect(try await bob.communities().first?.role == .member)

        // Alice configures her pod, then goes offline.
        _ = await alice.syncAll(discoveryTimeout: .milliseconds(10))
        #expect(await pod.config?.communities?.first?.members.count == 3)

        // Bob posts; only the pod is reachable, and it keeps his submission.
        try await bob.post(RichText(plain: "up late"), toCommunity: community)
        let attempts = await bob.syncAll(discoveryTimeout: .milliseconds(10))
        #expect(attempts.contains { $0.route.contains("Night owls on its pod") && (try? $0.result.get()) != nil })

        // Alice comes back: collects from her pod, republishes, and the pod carries it to Carol.
        _ = await alice.syncAll(discoveryTimeout: .milliseconds(10))
        #expect(try await feed(alice, community) == ["up late"])
        _ = await alice.syncAll(discoveryTimeout: .milliseconds(10))
        _ = await carol.syncAll(discoveryTimeout: .milliseconds(10))
        #expect(try await feed(carol, community) == ["up late"])
    }

    @Test("a pod serves a community only to its members")
    func podRefusesOutsiders() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let mallory = try await Account.create(home: temporaryHome(), displayName: "Mallory")
        let (pod, _) = try await PodNode.create(home: temporaryHome(), host: "127.0.0.1", port: 0)
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await pod.makeHandshake(role: .responder))
        try await pod.setAddress(host: "127.0.0.1", port: UInt16(listener.port))
        _ = try await pod.pair(try await alice.addPod(await pod.pairingCode))
        let podTask = Task { try await listener.run { session in _ = try await pod.respond(over: session) } }
        defer { podTask.cancel() }
        let community = try await alice.createCommunity(name: "Members only", visibility: .public, joinPolicy: .approval)
        _ = await alice.syncAll(discoveryTimeout: .milliseconds(10))
        #expect(await pod.config?.communities?.count == 1)
        await #expect(throws: (any Error).self) {
            try await mallory.sync(host: "127.0.0.1", port: listener.port, target: community)
        }
    }
}
