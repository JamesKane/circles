import Testing
import Foundation
import Synchronization
import CirclesCore
import CirclesCrypto
import CirclesKit
import CirclesNet
import CirclesSync
@testable import CirclesPresentation

@Suite("Community screen models")
@MainActor
struct CommunityScreenTests {
    @Test("creating and joining through the list; approving, posting and moderating on the community screen")
    func lifecycle() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let listener = try await NoiseListener(host: "127.0.0.1", port: 0, handshake: await alice.makeHandshake(role: .responder))
        let task = Task { try await listener.run { session in _ = try await alice.respond(over: session) } }
        defer { task.cancel() }
        try await alice.setDirectEndpoint(host: "127.0.0.1", port: listener.port)

        let aliceList = CommunitiesScreenModel(account: alice)
        await aliceList.perform(.create(name: "  ", description: "", visibility: .private, joinPolicy: .approval))
        #expect(aliceList.state.phase == .failed("Give the community a name."))
        await aliceList.perform(.create(name: "Hikers", description: "Trails", visibility: .private, joinPolicy: .approval))
        let community = try #require(aliceList.state.opened)
        #expect(aliceList.state.communities.map(\.name) == ["Hikers"])
        #expect(aliceList.state.communities.first?.detail == "Private · Approval needed")
        #expect(aliceList.state.communities.first?.roleLabel == "Owner")

        let services = RecordingServices()
        let aliceScreen = CommunityScreenModel(account: alice, community: community, services: services)
        await aliceScreen.perform(.makeInvite)
        let invite = try #require(aliceScreen.state.invite)
        #expect(services.clipboard.withLock { $0 } == invite)
        #expect(aliceScreen.state.isOwner && aliceScreen.state.canPost)

        let bobList = CommunitiesScreenModel(account: bob)
        await bobList.perform(.join(invite: "not an invite"))
        #expect(bobList.state.phase == .failed("That isn't a community invite."))
        await bobList.perform(.join(invite: invite))
        #expect(bobList.state.communities.first?.roleLabel == "Waiting to be let in")
        let bobScreen = CommunityScreenModel(account: bob, community: community)
        await bobScreen.perform(.refresh)
        #expect(!bobScreen.state.canPost)
        #expect(bobScreen.state.notice == CommunityStrings.pendingNotice)

        await bobScreen.perform(.sync)
        await aliceScreen.perform(.refresh)
        #expect(aliceScreen.state.requests.map(\.name) == ["Bob"])
        await aliceScreen.perform(.approve(bob.user))
        #expect(aliceScreen.state.requests.isEmpty)
        await bobScreen.perform(.sync)
        #expect(bobScreen.state.canPost)
        #expect(bobScreen.state.members.map(\.name) == ["Alice", "Bob"])
        #expect(bobScreen.state.members.first?.isOwner == true)

        await bobScreen.perform(.post("  Trail report  "))
        await bobScreen.perform(.sync)   // Alice republishes on receipt
        await bobScreen.perform(.sync)
        let card = try #require(bobScreen.state.cards.first)
        #expect(card.body.plainText == "Trail report")
        #expect(card.audienceLabel == "Hikers")
        #expect(!card.canDelete && !card.canReshare)

        await aliceScreen.perform(.refresh)
        #expect(aliceScreen.state.cards.first?.canDelete == true)
        await aliceScreen.perform(.removeItem(card.id))
        #expect(aliceScreen.state.cards.isEmpty)
        await aliceScreen.perform(.removeMember(bob.user))
        #expect(aliceScreen.state.members.map(\.name) == ["Alice"])
        await bobScreen.perform(.sync)
        #expect(bobScreen.state.notice == CommunityStrings.removedNotice)
        #expect(!bobScreen.state.canPost)
    }
}
