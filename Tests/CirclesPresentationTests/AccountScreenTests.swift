import Testing
import Foundation
import Synchronization
import CirclesCore
import CirclesKit
@testable import CirclesPresentation

/// Records what screen models put on the clipboard.
final class RecordingServices: PlatformServices {
    let clipboard = Mutex<String?>(nil)
    func pickImage() async -> PickedImage? { nil }
    func copyToClipboard(_ text: String) async { clipboard.withLock { $0 = text } }
    func notify(title: String, body: String) async {}
}

@Suite("Onboarding, people, settings and network models")
@MainActor
struct AccountScreenTests {
    @Test("onboarding creates the account once a name is entered")
    func onboarding() async throws {
        let home = temporaryHome()
        let model = OnboardingScreenModel(home: home)
        #expect(!model.state.canCreate)
        await model.perform(.editName("  Erin  "))
        #expect(model.state.canCreate)
        await model.perform(.create)
        #expect(model.state.phase == .done)
        #expect(await model.account?.displayName == "Erin")
        #expect(Account.exists(home: home))
    }

    @Test("people exchange invites through the clipboard")
    func invites() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        let services = RecordingServices()
        let alicesPeople = PeopleScreenModel(account: alice, services: services)
        await alicesPeople.perform(.load)
        await alicesPeople.perform(.copyMyInvite)
        let invite = try #require(services.clipboard.withLock { $0 })
        #expect(invite == alicesPeople.state.myInvite && invite.hasPrefix("circles-invite:"))

        let bobsPeople = PeopleScreenModel(account: bob, services: services)
        await bobsPeople.perform(.load)
        await bobsPeople.perform(.editInvite("not an invite"))
        #expect(!bobsPeople.state.canAdd)
        await bobsPeople.perform(.editInvite(invite))
        await bobsPeople.perform(.addContact)
        #expect(bobsPeople.state.people.map(\.name) == ["Alice"])
        #expect(bobsPeople.state.inviteDraft.isEmpty && bobsPeople.state.notice?.contains("Added Alice") == true)

        await bobsPeople.perform(.editInvite("circles-invite:garbage"))
        await bobsPeople.perform(.addContact)
        #expect(bobsPeople.state.phase != .idle)
    }

    @Test("settings add a pod (producing its pairing command) and a relay")
    func settings() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let services = RecordingServices()
        let settings = SettingsScreenModel(account: alice, services: services)
        await settings.perform(.load)
        #expect(settings.state.userID.hasPrefix("circles:") && settings.state.pods.isEmpty)

        let (_, code) = try await PodNode.create(home: temporaryHome(), host: "pod.example.net", port: 7465)
        await settings.perform(.editPodCode(try code.text))
        await settings.perform(.addPod)
        #expect(settings.state.pods == ["pod.example.net:7465"])
        await settings.perform(.copyPodBundle)
        #expect(services.clipboard.withLock { $0 }?.hasPrefix("circles-pod pair circles-pod-bundle:") == true)

        let relay = try RelayIdentity(home: temporaryHome())
        await settings.perform(.editRelay(relay.address(host: "relay.example.net", port: 7466)))
        await settings.perform(.addRelay)
        #expect(settings.state.relays == ["relay.example.net:7466"])
    }

    @Test("the network model goes online, counts new content from incoming syncs, and stops")
    func network() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await alice.addContact(invite: await bob.invite())
        try await bob.addContact(invite: await alice.invite())
        var preferences = NodePreferences()
        preferences.advertiseOnLocalNetwork = false
        preferences.syncIntervalSeconds = 3600
        try await alice.setPreferences(preferences)

        let network = NetworkModel(account: alice)
        await network.perform(.start)
        var port = 0
        for _ in 0..<100 {
            if case .online(let p) = network.state.status { port = p; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(port > 0)
        #expect(network.state.summary().hasPrefix("Online · port \(port)"))

        try await bob.post(RichText(plain: "new from bob"), to: .everyone)
        _ = try await bob.sync(host: "127.0.0.1", port: port)
        for _ in 0..<100 where network.state.newContentCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(network.state.newContentCount == 1)
        #expect(network.state.activity.contains { $0.contains("Synced with Bob (incoming): 1 new") })

        await network.perform(.stop)
        #expect(network.state.status == .offline)
    }
}

@Suite("People: rename and remove")
@MainActor
struct PeopleManagementTests {
    @Test("rename and remove go through the people model")
    func manage() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await alice.addContact(invite: await bob.invite())
        let people = PeopleScreenModel(account: alice, services: RecordingServices())
        await people.perform(.load)
        await people.perform(.rename(bob.user, to: "Robert"))
        #expect(people.state.people.map(\.name) == ["Robert"])
        await people.perform(.remove(bob.user))
        #expect(people.state.people.isEmpty)
        #expect(people.state.notice == "Removed Robert. They can't see anything you post from now on.")
    }
}
