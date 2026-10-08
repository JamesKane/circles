public import CirclesCore
public import NIOCore
import NIOPosix

/// What a node advertises on the local network.
public struct ServiceAdvertisement: Sendable {
    public var instanceName: String
    public var port: Int
    public var user: UserID
    public var device: DeviceID

    public init(instanceName: String, port: Int, user: UserID, device: DeviceID) {
        self.instanceName = instanceName
        self.port = port
        self.user = user
        self.device = device
    }

    /// A stable, unique instance label for a device.
    public static func instanceName(for device: DeviceID) -> String {
        "circles-" + device.description.dropFirst().prefix(16)
    }
}

/// A Circles node found on the local network.
public struct DiscoveredPeer: Sendable, Hashable {
    public var instanceName: String
    public var host: String
    public var port: Int
    public var user: UserID?
    public var device: DeviceID?
}

/// Minimal multicast DNS service discovery (RFC 6762/6763) for
/// `_circles._tcp.local` (docs/DESIGN.md §7.2).
///
/// - `advertise` binds port 5353 alongside any system responder (address
///   and port reuse), joins 224.0.0.251, announces itself, and answers queries.
/// - `browse` sends queries from an ephemeral port. RFC 6762 §6.7 requires
///   responders to reply directly to such a port, so browsing works even
///   where port 5353 can't be bound.
///
/// IPv4 only for now.
public enum MulticastDNS {
    static let groupAddress = "224.0.0.251"
    static let port = 5353
    static let serviceType = DNSName("_circles._tcp.local")

    // MARK: Advertising

    /// Announces and answers queries until the task is cancelled.
    public static func advertise(
        _ advertisement: ServiceAdvertisement,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws {
        var bootstrap = DatagramBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
        #if !os(Windows)
        bootstrap = bootstrap.channelOption(.socketOption(.so_reuseport), value: 1)
        #endif
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(wrappingChannelSynchronously: channel)
            }
        }
        try await joinGroup(channel.channel)

        let responder = Responder(advertisement: advertisement, addresses: localIPv4Addresses())
        let multicast = try SocketAddress(ipAddress: groupAddress, port: port)

        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                // Unsolicited announcements, as RFC 6762 §8.3 recommends.
                tasks.addTask {
                    for delay in [0, 1, 2] {
                        try await Task.sleep(for: .seconds(delay))
                        try await outbound.write(AddressedEnvelope(remoteAddress: multicast, data: ByteBuffer(bytes: responder.announcement())))
                    }
                }
                do {
                    for try await envelope in inbound {
                        guard let query = try? DNSMessage(decoding: Array(buffer: envelope.data)), !query.isResponse,
                              let reply = responder.reply(to: query, from: envelope.remoteAddress)
                        else { continue }
                        try await outbound.write(AddressedEnvelope(
                            remoteAddress: reply.unicast ? envelope.remoteAddress : multicast,
                            data: ByteBuffer(bytes: reply.bytes)
                        ))
                    }
                } catch {}
                tasks.cancelAll()
                // Goodbye (RFC 6762 §10.1): the same records with TTL 0, so
                // caches drop us now rather than when the TTLs run out. Sent
                // from a detached task so our cancellation doesn't stop it,
                // then given a moment to leave before the socket closes.
                let goodbye = AddressedEnvelope(remoteAddress: multicast, data: ByteBuffer(bytes: try responder.goodbye()))
                _ = await Task.detached {
                    try? await outbound.write(goodbye)
                    try? await Task.sleep(for: .milliseconds(100))
                }.value
            }
        }
    }

    struct Responder: Sendable {
        let advertisement: ServiceAdvertisement
        let addresses: [[UInt8]]

        var instance: DNSName { serviceType.prepending(advertisement.instanceName) }
        var host: DNSName { DNSName([advertisement.instanceName, "local"]) }

        var ptr: DNSMessage.Record { .init(name: serviceType, ttl: 4500, data: .ptr(instance)) }
        var srv: DNSMessage.Record {
            .init(name: instance, cacheFlush: true, ttl: 120,
                  data: .srv(priority: 0, weight: 0, port: UInt16(advertisement.port), target: host))
        }
        var txt: DNSMessage.Record {
            .init(name: instance, cacheFlush: true, ttl: 4500, data: .txt([
                "v=1", "u=\(advertisement.user)", "d=\(advertisement.device)",
            ]))
        }
        var aRecords: [DNSMessage.Record] {
            addresses.map { .init(name: host, cacheFlush: true, ttl: 120, data: .a($0)) }
        }

        func announcement() throws -> [UInt8] {
            try DNSMessage(flags: DNSMessage.responseFlags, answers: [ptr, srv, txt] + aRecords).encoded()
        }

        func goodbye() throws -> [UInt8] {
            let records = ([ptr, srv, txt] + aRecords).map { record in
                var record = record
                record.ttl = 0
                return record
            }
            return try DNSMessage(flags: DNSMessage.responseFlags, answers: records).encoded()
        }

        func reply(to query: DNSMessage, from source: SocketAddress) -> (bytes: [UInt8], unicast: Bool)? {
            var answers: [DNSMessage.Record] = []
            var additionals: [DNSMessage.Record] = []
            for question in query.questions {
                let type = question.type
                if question.name == serviceType, type == .ptr || type == .any {
                    answers.append(ptr)
                    additionals += [srv, txt] + aRecords
                } else if question.name == instance {
                    if type == .srv || type == .any { answers.append(srv) }
                    if type == .txt || type == .any { answers.append(txt) }
                    additionals += aRecords
                } else if question.name == host, type == .a || type == .any {
                    answers += aRecords
                }
            }
            guard !answers.isEmpty else { return nil }

            // A query from a port other than 5353 is a "legacy unicast" query
            // (RFC 6762 §6.7): reply directly, echo the ID and questions,
            // keep TTLs short, and don't set cache-flush bits.
            let legacy = source.port != port
            var message = DNSMessage(
                id: legacy ? query.id : 0,
                flags: DNSMessage.responseFlags,
                questions: legacy ? query.questions : [],
                answers: answers,
                additionals: additionals.filter { !answers.contains($0) }
            )
            if legacy {
                for i in message.answers.indices {
                    message.answers[i].ttl = min(message.answers[i].ttl, 10)
                    message.answers[i].cacheFlush = false
                }
                for i in message.additionals.indices {
                    message.additionals[i].ttl = min(message.additionals[i].ttl, 10)
                    message.additionals[i].cacheFlush = false
                }
            }
            guard let bytes = try? message.encoded() else { return nil }
            return (bytes, legacy || query.questions.contains(where: \.unicastResponse))
        }
    }

    // MARK: Browsing

    /// Queries for Circles nodes and collects answers for `timeout`.
    public static func browse(
        timeout: Duration = .seconds(2),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> [DiscoveredPeer] {
        let channel = try await DatagramBootstrap(group: group)
            .bind(host: "0.0.0.0", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(wrappingChannelSynchronously: channel)
                }
            }
        let multicast = try SocketAddress(ipAddress: groupAddress, port: port)
        let query = try DNSMessage(
            id: UInt16.random(in: 1 ... .max),
            questions: [.init(name: serviceType, type: .ptr)]
        ).encoded()

        var collector = BrowseCollector()
        let underlying = channel.channel
        try await channel.executeThenClose { inbound, outbound in
            await withThrowingTaskGroup(of: Void.self) { tasks in
                // Query a few times in case of packet loss, then stop
                // listening when the time is up.
                tasks.addTask {
                    for delay in [0, 250, 750] {
                        try await Task.sleep(for: .milliseconds(delay))
                        try await outbound.write(AddressedEnvelope(remoteAddress: multicast, data: ByteBuffer(bytes: query)))
                    }
                }
                tasks.addTask {
                    try await Task.sleep(for: timeout)
                    try? await underlying.close()
                }
                do {
                    for try await envelope in inbound {
                        guard let message = try? DNSMessage(decoding: Array(buffer: envelope.data)), message.isResponse else { continue }
                        collector.add(message, from: envelope.remoteAddress)
                    }
                } catch {}
                tasks.cancelAll()
            }
        }
        return collector.peers
    }

    struct BrowseCollector {
        private var instances: Set<DNSName> = []
        private var services: [DNSName: (port: Int, target: DNSName, source: String?)] = [:]
        private var texts: [DNSName: [String]] = [:]
        private var addresses: [DNSName: String] = [:]

        mutating func add(_ message: DNSMessage, from source: SocketAddress?) {
            for record in message.answers + message.additionals {
                switch record.data {
                case .ptr(let instance) where record.name == serviceType:
                    instances.insert(instance)
                case .srv(_, _, let port, let target):
                    services[record.name] = (Int(port), target, source?.ipAddress)
                case .txt(let strings):
                    texts[record.name] = strings
                case .a(let bytes) where bytes.count == 4:
                    addresses[record.name] = bytes.map(String.init).joined(separator: ".")
                default:
                    break
                }
            }
        }

        var peers: [DiscoveredPeer] {
            instances.compactMap { instance in
                guard let service = services[instance],
                      let host = addresses[service.target] ?? service.source
                else { return nil }
                let txt = Dictionary(
                    (texts[instance] ?? []).compactMap { entry -> (String, String)? in
                        guard let eq = entry.firstIndex(of: "=") else { return nil }
                        return (String(entry[..<eq]), String(entry[entry.index(after: eq)...]))
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                return DiscoveredPeer(
                    instanceName: instance.labels.first ?? "",
                    host: host,
                    port: service.port,
                    user: txt["u"].flatMap(UserID.init),
                    device: txt["d"].flatMap(DeviceID.init)
                )
            }
        }
    }

    // MARK: Interfaces

    private static func joinGroup(_ channel: any Channel) async throws {
        guard let multicastChannel = channel as? any MulticastChannel else { return }
        let group = try SocketAddress(ipAddress: groupAddress, port: port)
        let devices = (try? System.enumerateDevices()) ?? []
        let candidates = devices.filter { device in
            guard case .v4 = device.address, let ip = device.address?.ipAddress else { return false }
            return !ip.hasPrefix("127.")
        }
        var joined = false
        for device in candidates {
            if (try? await multicastChannel.joinGroup(group, device: device).get()) != nil { joined = true }
        }
        if !joined {
            try await multicastChannel.joinGroup(group, device: nil).get()
        }
    }

    static func localIPv4Addresses() -> [[UInt8]] {
        let devices = (try? System.enumerateDevices()) ?? []
        var seen: Set<[UInt8]> = []
        return devices.compactMap { device in
            guard case .v4 = device.address, let ip = device.address?.ipAddress, !ip.hasPrefix("127.") else { return nil }
            let bytes = ip.split(separator: ".").compactMap { UInt8($0) }
            guard bytes.count == 4, seen.insert(bytes).inserted else { return nil }
            return bytes
        }
    }
}
