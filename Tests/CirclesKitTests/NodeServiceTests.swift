import Testing
import Foundation
import Synchronization
import CirclesCore
@testable import CirclesKit

@Suite("Node service")
struct NodeServiceTests {
    @Test("accepts incoming syncs and reports them")
    func incomingSync() async throws {
        let alice = try await Account.create(home: temporaryHome(), displayName: "Alice")
        let bob = try await Account.create(home: temporaryHome(), displayName: "Bob")
        try await befriend(alice, bob)
        try await bob.post(RichText(plain: "hello from bob"), to: .everyone)

        let events = Mutex<[NodeEvent]>([])
        let (port, portContinuation) = AsyncStream.makeStream(of: Int.self)
        var preferences = NodePreferences()
        preferences.advertiseOnLocalNetwork = false
        preferences.syncIntervalSeconds = 3600
        let options = preferences
        let service = Task {
            try await NodeService(account: alice).run(options) { event in
                events.withLock { $0.append(event) }
                if case .listening(let port) = event { portContinuation.yield(port) }
            }
        }
        defer { service.cancel() }

        var listeningPort = 0
        for await value in port { listeningPort = value; break }
        _ = try await bob.sync(host: "127.0.0.1", port: listeningPort)

        // Give the service a moment to report the incoming session.
        for _ in 0..<50 where !events.withLock({ $0.contains { if case .synced(_, .incoming, let received, _) = $0 { received > 0 } else { false } } }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(events.withLock { $0.contains(.synced(peer: "Bob", direction: .incoming, received: 1, sent: 0)) })
        #expect(try await alice.stream().map(\.body.plainText) == ["hello from bob"])
    }

    @Test("preferences are saved with the account")
    func preferences() async throws {
        let account = try await Account.create(home: temporaryHome(), displayName: "Dana")
        #expect(try await account.preferences() == NodePreferences())
        var changed = NodePreferences()
        changed.mapRouterPort = true
        changed.port = 7465
        try await account.setPreferences(changed)
        #expect(try await account.preferences() == changed)
    }
}
