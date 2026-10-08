import Testing
import CirclesCore
import CirclesCrypto
import NIOCore
@testable import CirclesNet

@Suite("Multicast DNS")
struct MulticastDNSTests {
    static let user = try! UserID(ed25519PublicKey: [UInt8](repeating: 7, count: 32))
    static let device = try! DeviceID(ed25519PublicKey: [UInt8](repeating: 9, count: 32))
    static let advertisement = ServiceAdvertisement(
        instanceName: ServiceAdvertisement.instanceName(for: device), port: 4242, user: user, device: device
    )

    @Test("messages round-trip through the wire format")
    func roundTrip() throws {
        let responder = MulticastDNS.Responder(advertisement: Self.advertisement, addresses: [[192, 168, 1, 20]])
        let message = try DNSMessage(decoding: responder.announcement())
        #expect(message.isResponse)
        #expect(message.answers.map(\.type) == [.ptr, .srv, .txt, .a])
        #expect(try DNSMessage(decoding: message.encoded()) == message)
    }

    @Test("compressed names are decoded")
    func compression() throws {
        // A response with one PTR answer whose data points back at the question name.
        var bytes: [UInt8] = [0, 0, 0x84, 0, 0, 1, 0, 1, 0, 0, 0, 0]
        bytes += [8] + Array("_circles".utf8) + [4] + Array("_tcp".utf8) + [5] + Array("local".utf8) + [0]
        bytes += [0, 12, 0, 1]                        // question: PTR IN
        bytes += [0xC0, 12, 0, 12, 0, 1, 0, 0, 0, 10] // answer name → offset 12
        bytes += [0, 6, 3] + Array("foo".utf8) + [0xC0, 12]
        let message = try DNSMessage(decoding: bytes)
        #expect(message.answers.first?.data == .ptr(DNSName("foo._circles._tcp.local")))
    }

    @Test("pointer loops and truncation are rejected, not followed forever")
    func hostileInput() {
        let loop: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 12, 0, 1]
        #expect(throws: DNSError.self) { try DNSMessage(decoding: loop) }
        #expect(throws: DNSError.self) { try DNSMessage(decoding: [0, 0, 0]) }
    }

    @Test("the responder answers PTR queries, and legacy unicast queries get short TTLs and the echoed ID")
    func responderReplies() throws {
        let responder = MulticastDNS.Responder(advertisement: Self.advertisement, addresses: [[10, 0, 0, 5]])
        let query = DNSMessage(id: 77, questions: [.init(name: MulticastDNS.serviceType, type: .ptr)])

        let fromLegacy = try SocketAddress(ipAddress: "10.0.0.9", port: 50000)
        let legacy = try #require(responder.reply(to: query, from: fromLegacy))
        let parsed = try DNSMessage(decoding: legacy.bytes)
        #expect(legacy.unicast)
        #expect(parsed.id == 77 && parsed.questions == query.questions)
        #expect((parsed.answers + parsed.additionals).allSatisfy { $0.ttl <= 10 && !$0.cacheFlush })

        let fromMDNS = try SocketAddress(ipAddress: "10.0.0.9", port: 5353)
        #expect(try #require(responder.reply(to: query, from: fromMDNS)).unicast == false)

        let unrelated = DNSMessage(questions: [.init(name: DNSName("_printer._tcp.local"), type: .ptr)])
        #expect(responder.reply(to: unrelated, from: fromMDNS) == nil)
    }

    @Test("a browser builds peers from the records it collects")
    func collector() throws {
        let responder = MulticastDNS.Responder(advertisement: Self.advertisement, addresses: [[10, 0, 0, 5]])
        var collector = MulticastDNS.BrowseCollector()
        collector.add(try DNSMessage(decoding: responder.announcement()), from: try SocketAddress(ipAddress: "10.0.0.99", port: 5353))
        #expect(collector.peers == [DiscoveredPeer(
            instanceName: Self.advertisement.instanceName, host: "10.0.0.5", port: 4242, user: Self.user, device: Self.device
        )])
    }

    /// Uses the real network stack. Reported as a known issue where port
    /// 5353 can't be bound or multicast isn't available (some CI sandboxes).
    @Test("advertise and browse find each other on this machine")
    func live() async throws {
        let failure = Mutex<String?>(nil)
        let advertiser = Task {
            do {
                try await MulticastDNS.advertise(Self.advertisement)
            } catch {
                failure.withLock { $0 = "\(error)" }
            }
        }
        defer { advertiser.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        let peers = try await MulticastDNS.browse(timeout: .seconds(2))
        if let failure = failure.withLock({ $0 }) {
            withKnownIssue("mDNS unavailable here: \(failure)") { Issue.record("skipped") }
            return
        }
        #expect(peers.contains { $0.device == Self.device && $0.port == 4242 })
    }
}

import Synchronization

@Suite("Multicast DNS goodbye")
struct MulticastDNSGoodbyeTests {
    @Test("goodbye repeats every record with TTL 0")
    func goodbye() throws {
        let responder = MulticastDNS.Responder(advertisement: MulticastDNSTests.advertisement, addresses: [[10, 0, 0, 5]])
        let message = try DNSMessage(decoding: responder.goodbye())
        #expect(message.answers.map(\.type) == [.ptr, .srv, .txt, .a])
        #expect(message.answers.allSatisfy { $0.ttl == 0 })
    }
}
