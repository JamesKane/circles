public import NIOCore
import NIOPosix
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
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

    /// The IPv4 default gateway. Linux reads /proc/net/route; elsewhere this
    /// returns nil for now, and UPnP (which finds the router by multicast)
    /// still works.
    public static func defaultGateway() -> String? {
        #if os(Linux)
        guard let table = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else { return nil }
        return parseLinuxRouteTable(table)
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
