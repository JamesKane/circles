import Testing
import Foundation
import CirclesDHT
import CirclesCore
import CirclesKit
import CirclesNet
import CirclesCrypto
import CirclesSync
@testable import CirclesPresentation

func temporaryHome() -> URL {
    // Join-request proof of work at test strength (debug builds hash slowly).
    Account.defaultJoinPostageBits = 8
    DHTPuzzle.bits = 4
    return FileManager.default.temporaryDirectory.appendingPathComponent("circles-ui-\(UUID().uuidString)")
}

/// `a` syncs with `b` over real TCP.
func sync(_ a: Account, with b: Account) async throws {
    let listener = try await b.makeListener(host: "127.0.0.1", port: 0)
    let engine = await b.syncEngine()
    let task = Task { try await listener.run { session in _ = try await engine.run(over: session) } }
    defer { task.cancel() }
    _ = try await a.sync(host: "127.0.0.1", port: listener.port)
}

func friends() async throws -> (Account, Account) {
    let alice = try await Account.create(home: temporaryHome(), displayName: "Alice Liddell")
    let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
    try await alice.addContact(invite: await bob.invite())
    try await bob.addContact(invite: await alice.invite())
    return (alice, bob)
}

struct FakeServices: PlatformServices {
    var image: PickedImage?
    func pickImage() async -> PickedImage? { image }
    func copyToClipboard(_ text: String) async {}
    func notify(title: String, body: String) async {}
}

@Suite("Formatting")
struct FormattingTests {
    @Test("relative times, sizes and initials")
    func formats() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func ago(_ seconds: Double) -> HLCTimestamp { HLCTimestamp(millis: UInt64((1_000_000 - seconds) * 1000)) }
        #expect(Format.relativeTime(ago(10), now: now) == "just now")
        #expect(Format.relativeTime(ago(300), now: now) == "5 min")
        #expect(Format.relativeTime(ago(7200), now: now) == "2 h")
        #expect(Format.relativeTime(ago(90_000), now: now) == "yesterday")
        #expect(Format.byteCount(512) == "512 B" && Format.byteCount(2048) == "2 KB" && Format.byteCount(2_621_440) == "2.5 MB")
        #expect(Format.initials("Alice Liddell") == "AL" && Format.initials("bob") == "B")
        #expect(Format.initials("Bob (CLI)") == "BC" && Format.initials("— ✨ Zoë") == "Z" && Format.initials("") == "")
    }
}

@Suite("Screen models, headless")
@MainActor
struct ScreenModelTests {
    @Test("the composer enforces an audience and content, then posts with attachments")
    func composer() async throws {
        let (alice, bob) = try await friends()
        try await alice.createCircle("Family")
        try await alice.addToCircle("Family", members: [bob.user])
        let photo = PickedImage(data: Array(repeating: 9, count: 5000), mediaType: "image/png", width: 10, height: 10)
        let composer = ComposerScreenModel(account: alice, services: FakeServices(image: photo))
        await composer.perform(.load)
        #expect(composer.state.circles == ["Family"])

        await composer.perform(.editText("first light"))
        #expect(!composer.state.canPost) // no audience yet
        #expect(composer.state.audienceSummary == "Choose who can see this") // never "Public" by default
        await composer.perform(.setShareWithEveryone(true))
        #expect(composer.state.audienceSummary == "Public")
        await composer.perform(.setShareWithEveryone(false))
        await composer.perform(.toggleCircle("Family"))
        #expect(composer.state.canPost && composer.state.audienceSummary == "Shared with Family")
        await composer.perform(.pickImage)
        #expect(composer.state.attachments.map(\.sizeLabel) == ["4 KB"])
        await composer.perform(.setAllowResharing(false))
        await composer.perform(.post)
        #expect(composer.state.status == .posted && composer.state.text.isEmpty)

        try await sync(bob, with: alice)
        let stream = StreamScreenModel(account: bob)
        await stream.perform(.refresh)
        let card = try #require(stream.state.cards.first)
        #expect(card.body.plainText == "first light")
        #expect(card.audienceLabel == "Limited" && card.audienceToken == .audienceLimited)
        #expect(card.authorInitials == "AL" && !card.canReshare)
        #expect(try await MediaLoader(account: bob).data(for: try #require(card.attachments.first)) == photo.data)
    }

    @Test("a comment goes from pending to approved, all through screen models")
    func commentFlow() async throws {
        let (alice, bob) = try await friends()
        let id = try await alice.post(RichText(plain: "anyone up for a walk?"), to: .everyone)
        try await sync(bob, with: alice)

        let bobsPost = PostScreenModel(post: ObjectRef(author: alice.user, id: id), account: bob)
        await bobsPost.perform(.load)
        #expect(!bobsPost.state.canSubmitComment)
        await bobsPost.perform(.editDraft("  me!  "))
        await bobsPost.perform(.submitComment)
        await bobsPost.perform(.togglePlusOne)
        #expect(bobsPost.state.draft.isEmpty)
        #expect(bobsPost.state.card?.comments.map(\.pending) == [true])
        #expect(bobsPost.state.card?.plusOnedByMe == true)

        try await sync(alice, with: bob)
        let alicesStream = StreamScreenModel(account: alice)
        await alicesStream.perform(.refresh) // republishes Bob's contributions
        #expect(alicesStream.state.cards.first?.comments.map(\.body.plainText) == ["me!"])
        #expect(alicesStream.state.cards.first?.plusOnes == 1)

        try await sync(bob, with: alice)
        await bobsPost.perform(.load)
        #expect(bobsPost.state.card?.comments.map(\.pending) == [false])
    }

    @Test("the stream filters by circle, and +1 updates the card")
    func streamFilter() async throws {
        let (alice, bob) = try await friends()
        let carol = try await Account.create(home: temporaryHome(), displayName: "Carol")
        try await alice.addContact(invite: await carol.invite())
        try await carol.addContact(invite: await alice.invite())
        try await alice.createCircle("Close")
        try await alice.addToCircle("Close", members: [bob.user])
        try await bob.post(RichText(plain: "from bob"), to: .everyone)
        try await carol.post(RichText(plain: "from carol"), to: .everyone)
        try await sync(alice, with: bob)
        try await sync(alice, with: carol)

        let stream = StreamScreenModel(account: alice)
        await stream.perform(.refresh)
        #expect(stream.state.cards.count == 2)
        #expect(stream.state.availableFilters == [.everything, .circle("Close")])
        await stream.perform(.selectFilter(.circle("Close")))
        #expect(stream.state.cards.map(\.body.plainText) == ["from bob"])
        await stream.perform(.setPlusOne(try #require(stream.state.cards.first).reference, true))
        #expect(stream.state.cards.first?.plusOnedByMe == true)
    }

    @Test("the circles screen shows who's in which circle")
    func circles() async throws {
        let (alice, bob) = try await friends()
        let screen = CirclesScreenModel(account: alice)
        await screen.perform(.load)
        #expect(screen.state.circles.isEmpty && screen.state.contacts.map(\.name) == ["Bob"])
        await screen.perform(.createCircle("Hiking"))
        await screen.perform(.add(bob.user, toCircle: "Hiking"))
        #expect(screen.state.circles == [.init(name: "Hiking", memberNames: ["Bob"])])
        #expect(screen.state.contacts.first?.circles == ["Hiking"])
        await screen.perform(.remove(bob.user, fromCircle: "Hiking"))
        #expect(screen.state.circles.first?.memberNames.isEmpty == true)
        await screen.perform(.createCircle("Hiking"))
        #expect(screen.state.phase != .idle) // duplicate name reported
    }

    @Test("navigation is plain data")
    func navigation() {
        let navigation = NavigationModel()
        #expect(navigation.current == .stream)
        navigation.push(.composer)
        navigation.push(.circles)
        #expect(navigation.path == [.composer, .circles])
        navigation.pop()
        #expect(navigation.current == .composer)
        navigation.popToRoot()
        #expect(navigation.current == .stream)
    }
}

@Suite("Deleting through screen models")
@MainActor
struct DeletingScreenTests {
    @Test("only the author can delete, and removing a comment updates the thread")
    func deleting() async throws {
        let (alice, bob) = try await friends()
        let id = try await alice.post(RichText(plain: "draft thought"), to: .everyone)
        try await sync(bob, with: alice)
        let bobsView = PostScreenModel(post: ObjectRef(author: alice.user, id: id), account: bob)
        await bobsView.perform(.load)
        #expect(bobsView.state.card?.canDelete == false)
        await bobsView.perform(.editDraft("hmm"))
        await bobsView.perform(.submitComment)
        try await sync(alice, with: bob)

        let alicesView = PostScreenModel(post: ObjectRef(author: alice.user, id: id), account: alice)
        await alicesView.perform(.load)
        let comment = try #require(alicesView.state.card?.comments.first)
        #expect(alicesView.state.card?.canDelete == true && comment.canRemove)
        await alicesView.perform(.removeComment(comment.id))
        #expect(alicesView.state.card?.comments.isEmpty == true)

        await alicesView.perform(.delete)
        #expect(alicesView.state.deleted && alicesView.state.card == nil)
        let stream = StreamScreenModel(account: alice)
        await stream.perform(.refresh)
        #expect(stream.state.cards.isEmpty)
    }
}

@Suite("Arrivals for notifications")
@MainActor
struct ArrivalTests {
    @Test("new posts from others and comments on our posts become arrivals; our own activity and the first load don't")
    func arrivals() async throws {
        let (alice, bob) = try await friends()
        let id = try await alice.post(RichText(plain: "Dinner Friday?"), to: .everyone)
        let stream = StreamScreenModel(account: alice)
        await stream.perform(.refresh)
        #expect(stream.state.arrivals.isEmpty && stream.state.arrivalGeneration == 0) // first load

        try await alice.post(RichText(plain: "my own news"), to: .everyone)
        await stream.perform(.refresh)
        #expect(stream.state.arrivals.isEmpty) // our own post isn't news

        try await sync(bob, with: alice)
        try await bob.post(RichText(plain: String(repeating: "long ", count: 40)), to: .everyone)
        try await bob.comment(RichText(plain: "I'm in"), on: ObjectRef(author: alice.user, id: id))
        try await sync(alice, with: bob)
        await stream.perform(.refresh)
        #expect(stream.state.arrivalGeneration == 1)
        #expect(stream.state.arrivals.map(\.title).sorted() == ["Bob posted", "Bob commented on your post"].sorted())
        #expect(stream.state.arrivals.first { $0.kind == .post }?.body.count == 120)

        await stream.perform(.refresh)
        #expect(stream.state.arrivals.isEmpty && stream.state.arrivalGeneration == 1) // nothing new
    }
}
