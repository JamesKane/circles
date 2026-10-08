import Testing
import NIOCore
import NIOPosix
@testable import CirclesNet

@Suite("Port mapping")
struct PortMappingTests {
    @Test("NAT-PMP requests and responses match RFC 6886")
    func natPMP() throws {
        #expect(NATPMP.mapRequest(internalPort: 7465, externalPort: 7465, lifetime: 7200)
            == [0, 2, 0, 0, 0x1D, 0x29, 0x1D, 0x29, 0, 0, 0x1C, 0x20])
        let response: [UInt8] = [0, 130, 0, 0, 0, 0, 0, 9, 0x1D, 0x29, 0x1D, 0x2A, 0, 0, 0x0E, 0x10]
        #expect(try NATPMP.parseMapResponse(response)
            == .init(resultCode: 0, internalPort: 7465, externalPort: 7466, lifetime: 3600))
        #expect(try NATPMP.parseExternalAddress([0, 128, 0, 0, 0, 0, 0, 1, 203, 0, 113, 7]) == "203.0.113.7")
        #expect(throws: PortMappingError.refused(method: "NAT-PMP", code: 3)) {
            try NATPMP.parseExternalAddress([0, 128, 0, 3, 0, 0, 0, 1, 0, 0, 0, 0])
        }
    }

    @Test("PCP MAP requests are 60 bytes laid out per RFC 6887, and responses parse")
    func pcp() throws {
        let nonce = [UInt8](1...12)
        let request = PCP.mapRequest(clientAddress: [192, 168, 0, 15], nonce: nonce, internalPort: 7465, externalPort: 7465, lifetime: 7200)
        #expect(request.count == 60)
        #expect(Array(request[0..<4]) == [2, 1, 0, 0])
        #expect(Array(request[18..<24]) == [0xFF, 0xFF, 192, 168, 0, 15])
        #expect(Array(request[24..<36]) == nonce)
        #expect(request[36] == 6)

        var response = [UInt8](repeating: 0, count: 60)
        response[0] = 2; response[1] = 0x81
        response.replaceSubrange(4..<8, with: [0, 0, 0x1C, 0x20])
        response.replaceSubrange(24..<36, with: nonce)
        response.replaceSubrange(40..<44, with: [0x1D, 0x29, 0x1D, 0x29])
        response.replaceSubrange(50..<60, with: [0xFF, 0xFF, 0, 0, 0, 0, 203, 0, 113, 9][0...].suffix(10))
        response.replaceSubrange(54..<60, with: [0xFF, 0xFF, 203, 0, 113, 9])
        let parsed = try PCP.parseMapResponse(response)
        #expect(parsed.externalPort == 7465 && parsed.lifetime == 7200 && parsed.externalAddress == "203.0.113.9")

        // A NAT-PMP-only router answers PCP with version 0.
        #expect(throws: PortMappingError.unsupported) { try PCP.parseMapResponse([0, 129, 0, 1] + [UInt8](repeating: 0, count: 56)) }
    }

    @Test("the Linux route table yields the default gateway")
    func linuxRoutes() {
        let table = """
        Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT
        enp77s0\t0000A8C0\t00000000\t0001\t0\t0\t100\t00FFFFFF\t0\t0\t0
        enp77s0\t00000000\t0100A8C0\t0003\t0\t0\t100\t00000000\t0\t0\t0
        """
        #expect(PortMapper.parseLinuxRouteTable(table) == "192.168.0.1")
    }

    /// One `rt_msghdr` plus its sockaddrs, laid out as Darwin's sysctl dump does.
    static func darwinRoute(flags: UInt32, destination: [UInt8], gateway: [UInt8]?, netmask: [UInt8]? = nil) -> [UInt8] {
        func sockaddrIn(_ ip: [UInt8]) -> [UInt8] { [16, 2, 0, 0] + ip + [UInt8](repeating: 0, count: 8) }
        func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        var addrs: UInt32 = 0x1
        var body = sockaddrIn(destination)
        if let gateway {
            addrs |= 0x2
            // An empty gateway stands for a link-layer one (AF_LINK, family 18).
            body += gateway.isEmpty ? [20, 18] + [UInt8](repeating: 0, count: 18) : sockaddrIn(gateway)
        }
        if let netmask {
            addrs |= 0x4
            body += netmask.isEmpty ? [0, 0, 0, 0] : sockaddrIn(netmask)
        }
        var header = [UInt8](repeating: 0, count: 92)
        let length = header.count + body.count
        header[0] = UInt8(length & 0xFF); header[1] = UInt8(length >> 8)
        header[2] = 5
        header.replaceSubrange(8..<12, with: le32(flags))
        header.replaceSubrange(12..<16, with: le32(addrs))
        return header + body
    }

    @Test("a Darwin route dump yields the primary default gateway")
    func darwinRoutes() {
        let up: UInt32 = 0x1, gateway: UInt32 = 0x2, scoped: UInt32 = 0x100_0000
        let subnet = Self.darwinRoute(flags: up | gateway, destination: [10, 8, 0, 0], gateway: [192, 168, 0, 254],
                                      netmask: [255, 255, 0, 0])
        let linkDefault = Self.darwinRoute(flags: up | gateway, destination: [0, 0, 0, 0], gateway: [], netmask: [])
        let scopedDefault = Self.darwinRoute(flags: up | gateway | scoped, destination: [0, 0, 0, 0], gateway: [10, 0, 0, 1], netmask: [])
        let primaryDefault = Self.darwinRoute(flags: up | gateway, destination: [0, 0, 0, 0], gateway: [192, 168, 0, 1], netmask: [])
        let downDefault = Self.darwinRoute(flags: gateway, destination: [0, 0, 0, 0], gateway: [172, 16, 0, 1])

        #expect(PortMapper.parseDarwinRouteDump(subnet + linkDefault + scopedDefault + primaryDefault) == "192.168.0.1")
        #expect(PortMapper.parseDarwinRouteDump(subnet + scopedDefault) == "10.0.0.1")
        #expect(PortMapper.parseDarwinRouteDump(downDefault + subnet + linkDefault) == nil)
        #expect(PortMapper.parseDarwinRouteDump([]) == nil)
        // Truncated input stops cleanly.
        #expect(PortMapper.parseDarwinRouteDump(Array(primaryDefault.prefix(100))) == nil)
    }

    #if canImport(Darwin)
    @Test("the Darwin route-message layout matches net/route.h")
    func darwinLayout() {
        typealias M = PortMapper.DarwinRouteMessage
        #expect(MemoryLayout<rt_msghdr>.size == M.headerSize)
        #expect(MemoryLayout<rt_msghdr>.offset(of: \.rtm_version) == M.versionOffset)
        #expect(MemoryLayout<rt_msghdr>.offset(of: \.rtm_flags) == M.flagsOffset)
        #expect(MemoryLayout<rt_msghdr>.offset(of: \.rtm_addrs) == M.addrsOffset)
        #expect(Int32(M.version) == RTM_VERSION && Int32(M.familyInet) == AF_INET)
        #expect(Int32(M.flagUp) == RTF_UP && Int32(M.flagGateway) == RTF_GATEWAY && Int32(M.flagInterfaceScoped) == RTF_IFSCOPE)
        #expect(Int32(M.addressDestination) == RTA_DST && Int32(M.addressGateway) == RTA_GATEWAY
                && Int32(M.addressNetmask) == RTA_NETMASK)
    }
    #endif

    @Test("a UPnP device description yields the WAN connection's control URL")
    func upnpDescription() {
        let xml = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/l3f</controlURL></service>
        </serviceList><deviceList><device><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <controlURL>/upnp/control/WANIPConn1</controlURL></service></serviceList></device></deviceList></device></root>
        """
        #expect(UPnP.parseDescription(xml, location: "http://192.168.0.1:5431/dyndev/uuid:x")
            == .init(controlURL: "http://192.168.0.1:5431/upnp/control/WANIPConn1",
                     serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1"))
    }

    @Test("SOAP bodies, namespaced values, and chunked HTTP responses")
    func soapAndHTTP() throws {
        let envelope = UPnP.soapEnvelope(action: "AddPortMapping", serviceType: "urn:x:WANIPConnection:1",
                                         arguments: [("NewPortMappingDescription", "a<b&c")])
        #expect(envelope.contains("<u:AddPortMapping xmlns:u=\"urn:x:WANIPConnection:1\">"))
        #expect(envelope.contains("<NewPortMappingDescription>a&lt;b&amp;c</NewPortMappingDescription>"))

        let reply = "<s:Envelope><s:Body><u:GetExternalIPAddressResponse><NewExternalIPAddress> 203.0.113.5 </NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body></s:Envelope>"
        #expect(UPnP.xmlValue("NewExternalIPAddress", in: reply) == "203.0.113.5")
        #expect(UPnP.xmlValue("errorCode", in: "<UPnPError><errorCode>725</errorCode></UPnPError>") == "725")

        let chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        let response = try UPnP.parseHTTPResponse(Array(chunked.utf8))
        #expect(response.status == 200 && response.body == "hello world")
        #expect(UPnP.isComplete(Array(chunked.utf8)))
        let sized = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
        #expect(UPnP.isComplete(Array(sized.utf8)) && !UPnP.isComplete(Array(sized.dropLast().utf8)))
        #expect(UPnP.header("location", in: "HTTP/1.1 200 OK\r\nLocation: http://x/y\r\n\r\n") == "http://x/y")
    }

    /// Read-only: discovers the router and asks for its external address. It
    /// never creates a mapping. Reported as a known issue where no UPnP
    /// gateway answers (CI, networks without UPnP).
    @Test("live, read-only: find the UPnP gateway and its external address",
          .disabled(if: ProcessInfo.processInfo.environment["CI"] != nil, "needs a real router"))
    func liveReadOnly() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        guard let gateway = try? await UPnP.discover(group: group) else {
            withKnownIssue("no UPnP gateway on this network") { Issue.record("skipped") }
            return
        }
        #expect(gateway.serviceType.contains("WAN"))
        let address = try await UPnP.externalAddress(gateway, group: group)
        #expect(ipv4Bytes(address) != nil)
    }

    /// Creates a REAL mapping on the router, so it only runs when
    /// CIRCLES_LIVE_PORT_MAPPING=1. Maps an unused high port for 120 s,
    /// confirms the router lists it, removes it, and confirms it's gone.
    @Test("live, opt-in: map a port on the router, confirm, and remove it",
          .enabled(if: ProcessInfo.processInfo.environment["CIRCLES_LIVE_PORT_MAPPING"] == "1"))
    func liveMapping() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let port = 47999
        let mapping = try await PortMapper.map(tcpPort: port, lifetime: 120)
        // Always remove the mapping, awaited, even if a check below fails. (A
        // detached task in `defer` can be cut off when the process exits.)
        let checks: Result<Void, any Error>
        do {
            try await verify(mapping, port: port, group: group)
            checks = .success(())
        } catch {
            checks = .failure(error)
        }
        await PortMapper.unmap(mapping)
        if mapping.method == .upnp {
            let gateway = UPnP.Gateway(controlURL: try #require(mapping.controlURL), serviceType: try #require(mapping.serviceType))
            #expect(try await UPnP.mappingEntry(externalPort: port, gateway: gateway, group: group) == nil, "mapping was not removed")
        }
        try checks.get()
        print("live port mapping: \(mapping.method.rawValue), lifetime \(mapping.lifetime)s, verified and removed")
    }

    private func verify(_ mapping: PortMapping, port: Int, group: any EventLoopGroup) async throws {
        #expect(mapping.externalPort == port)
        #expect(mapping.externalAddress.flatMap(ipv4Bytes) != nil)
        guard mapping.method == .upnp else { return }
        let gateway = UPnP.Gateway(controlURL: try #require(mapping.controlURL), serviceType: try #require(mapping.serviceType))
        let entry = try #require(try await UPnP.mappingEntry(externalPort: port, gateway: gateway, group: group))
        #expect(entry.port == port)
        #expect(MulticastDNS.localIPv4Addresses().contains(try #require(ipv4Bytes(entry.client))))
    }
}

import Foundation
