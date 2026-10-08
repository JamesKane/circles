public import NIOCore
import NIOPosix
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#endif

/// A TCP port forwarded on the local router (docs/DESIGN.md §7.3).
public struct PortMapping: Sendable, Hashable {
    public enum Method: String, Sendable { case pcp = "PCP", natPMP = "NAT-PMP", upnp = "UPnP-IGD" }

    public var method: Method
    public var gateway: String
    public var internalPort: Int
    public var externalPort: Int
    /// The router's public address, if it reported one.
    public var externalAddress: String?
    /// Seconds the router will keep the mapping; 0 means until removed.
    public var lifetime: UInt32
    /// Where to send UPnP control requests (UPnP only).
    var controlURL: String?
    var serviceType: String?
}

public enum PortMappingError: Error, Sendable, Equatable {
    case noGateway
    case unsupported
    case refused(method: String, code: Int)
    case malformedResponse
}

/// Asks the router to forward a TCP port, trying PCP, then NAT-PMP, then
/// UPnP-IGD. Mappings with a lifetime must be renewed before it runs out
/// (`map` again at about half the lifetime). Remove with `unmap` on shutdown.
public enum PortMapper {
    public static func map(
        tcpPort: Int,
        externalPort: Int? = nil,
        lifetime: UInt32 = 7200,
        gateway: String? = nil,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws -> PortMapping {
        let external = externalPort ?? tcpPort
        var failures: [any Error] = []
        if let gateway = gateway ?? defaultGateway() {
            do {
                return try await PCP.map(tcpPort: tcpPort, externalPort: external, lifetime: lifetime, gateway: gateway, group: group)
            } catch { failures.append(error) }
            do {
                return try await NATPMP.map(tcpPort: tcpPort, externalPort: external, lifetime: lifetime, gateway: gateway, group: group)
            } catch { failures.append(error) }
        }
        do {
            return try await UPnP.map(tcpPort: tcpPort, externalPort: external, lifetime: lifetime, group: group)
        } catch { failures.append(error) }
        throw failures.last ?? PortMappingError.unsupported
    }

    public static func unmap(_ mapping: PortMapping, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async {
        switch mapping.method {
        case .pcp:
            _ = try? await PCP.map(tcpPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: 0,
                                   gateway: mapping.gateway, group: group)
        case .natPMP:
            _ = try? await NATPMP.map(tcpPort: mapping.internalPort, externalPort: 0, lifetime: 0,
                                      gateway: mapping.gateway, group: group)
        case .upnp:
            try? await UPnP.unmap(mapping, group: group)
        }
    }

    /// The IPv4 default gateway. Linux reads /proc/net/route; Apple platforms
    /// dump the routing table with sysctl. Elsewhere this returns nil for
    /// now, and UPnP (which finds the router by multicast) still works.
    public static func defaultGateway() -> String? {
        #if os(Linux)
        guard let table = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else { return nil }
        return parseLinuxRouteTable(table)
        #elseif canImport(Darwin)
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // The table can grow between the two calls; leave some room.
        size += size / 4
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseDarwinRouteDump(Array(buffer.prefix(size)))
        #else
        return nil
        #endif
    }

    static func parseLinuxRouteTable(_ table: String) -> String? {
        for line in table.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count > 2, fields[1] == "00000000", let gateway = UInt32(fields[2], radix: 16), gateway != 0 else { continue }
            // Little-endian hex: the first byte is the lowest-order one.
            return (0..<4).map { String((gateway >> (8 * $0)) & 0xFF) }.joined(separator: ".")
        }
        return nil
    }

    /// Darwin's `struct rt_msghdr` (net/route.h): size and field offsets.
    /// Kept as numbers so the parser builds and is tested on every platform;
    /// a Darwin-only test checks them against the real struct.
    enum DarwinRouteMessage {
        static let headerSize = 92
        static let versionOffset = 2
        static let flagsOffset = 8
        static let addrsOffset = 12
        static let version: UInt8 = 5 // RTM_VERSION
        static let flagUp: UInt32 = 0x1 // RTF_UP
        static let flagGateway: UInt32 = 0x2 // RTF_GATEWAY
        static let flagInterfaceScoped: UInt32 = 0x100_0000 // RTF_IFSCOPE
        static let addressDestination: UInt32 = 0x1 // RTA_DST
        static let addressGateway: UInt32 = 0x2 // RTA_GATEWAY
        static let addressNetmask: UInt32 = 0x4 // RTA_NETMASK
        static let familyInet: UInt8 = 2 // AF_INET
    }

    /// Finds the IPv4 default route in a `sysctl(NET_RT_FLAGS)` dump: a run of
    /// `rt_msghdr`s, each followed by the sockaddrs its `rtm_addrs` bits name,
    /// in bit order and padded to 4 bytes. With several default routes (one
    /// per interface), the unscoped one is the system's primary.
    static func parseDarwinRouteDump(_ dump: [UInt8]) -> String? {
        typealias M = DarwinRouteMessage
        func u16(_ at: Int) -> Int { Int(dump[at]) | Int(dump[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(dump[at + $1]) << (8 * $1) } }

        var scoped: String?
        var offset = 0
        while offset + M.headerSize <= dump.count {
            let length = u16(offset)
            guard length >= M.headerSize, offset + length <= dump.count else { break }
            defer { offset += length }
            let flags = u32(offset + M.flagsOffset), addrs = u32(offset + M.addrsOffset)
            guard dump[offset + M.versionOffset] == M.version,
                  flags & (M.flagUp | M.flagGateway) == M.flagUp | M.flagGateway else { continue }

            // Collect the sockaddrs present, by RTA_* bit.
            var sockaddrs: [UInt32: ArraySlice<UInt8>] = [:]
            var cursor = offset + M.headerSize
            let end = offset + length
            for bit in 0..<8 where addrs & (1 << bit) != 0 {
                guard cursor < end else { break }
                let saLength = Int(dump[cursor])
                let padded = saLength == 0 ? 4 : (saLength + 3) & ~3
                sockaddrs[1 << bit] = dump[cursor..<min(cursor + saLength, end)]
                cursor += padded
            }

            // Default: destination 0.0.0.0 with an absent or all-zero netmask.
            guard let destination = sockaddrs[M.addressDestination], destination.count >= 8,
                  destination[destination.startIndex + 1] == M.familyInet,
                  destination.dropFirst(4).prefix(4).allSatisfy({ $0 == 0 }),
                  (sockaddrs[M.addressNetmask] ?? []).dropFirst(4).allSatisfy({ $0 == 0 }),
                  let gateway = sockaddrs[M.addressGateway], gateway.count >= 8,
                  gateway[gateway.startIndex + 1] == M.familyInet
            else { continue }
            let address = gateway.dropFirst(4).prefix(4).map(String.init).joined(separator: ".")
            if flags & M.flagInterfaceScoped == 0 { return address }
            if scoped == nil { scoped = address }
        }
        return scoped
    }
}

/// Sends a UDP request to `host:port` and returns the first reply from that
/// address, retrying with backoff (RFC 6886 §3.1: 250 ms, doubling).
func udpRequest(
    _ request: [UInt8],
    to host: String,
    port: Int,
    attempts: Int = 4,
    group: any EventLoopGroup,
    localAddress: ((String) -> [UInt8])? = nil
) async throws -> [UInt8] {
    let channel = try await DatagramBootstrap(group: group)
        .connect(host: host, port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(wrappingChannelSynchronously: channel)
            }
        }
    let remote = try SocketAddress(ipAddress: host, port: port)
    var payload = request
    if let localAddress, let local = channel.channel.localAddress?.ipAddress {
        payload = localAddress(local)
    }
    let message = payload
    let underlying = channel.channel
    return try await channel.executeThenClose { inbound, outbound in
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            tasks.addTask {
                var delay = 250
                for _ in 0..<attempts {
                    try await outbound.write(AddressedEnvelope(remoteAddress: remote, data: ByteBuffer(bytes: message)))
                    try await Task.sleep(for: .milliseconds(delay))
                    delay *= 2
                }
                try? await underlying.close()
            }
            defer { tasks.cancelAll() }
            for try await envelope in inbound where envelope.remoteAddress.ipAddress == host {
                return Array(buffer: envelope.data)
            }
            throw PortMappingError.unsupported
        }
    }
}

func ipv4Bytes(_ address: String) -> [UInt8]? {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    return parts.count == 4 ? parts : nil
}

extension PortMapper {
    /// Keeps `tcpPort` mapped until the task is cancelled: maps it, renews at
    /// half the lifetime, and removes the mapping on cancellation (in a
    /// detached task, so cancellation doesn't stop the removal).
    /// `onChange` receives each new mapping, then nil when it's removed.
    public static func keepPortMapped(
        tcpPort: Int,
        externalPort: Int? = nil,
        onChange: @escaping @Sendable (PortMapping?) async -> Void,
        onError: @escaping @Sendable (any Error) async -> Void = { _ in }
    ) async {
        var current: PortMapping?
        while !Task.isCancelled {
            do {
                let mapping = try await map(tcpPort: tcpPort, externalPort: current?.externalPort ?? externalPort)
                if mapping != current { await onChange(mapping) }
                current = mapping
                // Permanent mappings (lifetime 0) are still refreshed hourly.
                let lifetime = mapping.lifetime == 0 ? 7200 : mapping.lifetime
                try await Task.sleep(for: .seconds(max(30, Int(lifetime) / 2)))
            } catch is CancellationError {
                break
            } catch {
                await onError(error)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        if let current {
            await Task.detached {
                await unmap(current)
                await onChange(nil)
            }.value
        }
    }
}
