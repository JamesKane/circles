import NIOCore
import NIOPosix

/// UPnP Internet Gateway Device port mapping (WANIPConnection /
/// WANPPPConnection), which most consumer routers support even when they
/// don't speak NAT-PMP or PCP.
enum UPnP {
    struct Gateway: Sendable, Equatable {
        var controlURL: String
        var serviceType: String
    }

    // MARK: Mapping

    static func map(tcpPort: Int, externalPort: Int, lifetime: UInt32, group: any EventLoopGroup) async throws -> PortMapping {
        let gateway = try await discover(group: group)
        let externalAddress = try? await self.externalAddress(gateway, group: group)
        var lease = lifetime
        while true {
            let local = try await localAddress(towards: gateway.controlURL, group: group)
            let response = try await soap(gateway, action: "AddPortMapping", arguments: [
                ("NewRemoteHost", ""), ("NewExternalPort", String(externalPort)), ("NewProtocol", "TCP"),
                ("NewInternalPort", String(tcpPort)), ("NewInternalClient", local), ("NewEnabled", "1"),
                ("NewPortMappingDescription", "Circles"), ("NewLeaseDuration", String(lease)),
            ], group: group)
            switch response {
            case .success:
                return PortMapping(method: .upnp, gateway: host(of: gateway.controlURL) ?? "", internalPort: tcpPort,
                                   externalPort: externalPort, externalAddress: externalAddress, lifetime: lease,
                                   controlURL: gateway.controlURL, serviceType: gateway.serviceType)
            case .failure(725) where lease != 0:
                lease = 0 // OnlyPermanentLeasesSupported
            case .failure(let code):
                throw PortMappingError.refused(method: "UPnP-IGD", code: code)
            }
        }
    }

    static func unmap(_ mapping: PortMapping, group: any EventLoopGroup) async throws {
        guard let controlURL = mapping.controlURL, let serviceType = mapping.serviceType else { return }
        _ = try await soap(Gateway(controlURL: controlURL, serviceType: serviceType), action: "DeletePortMapping", arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", String(mapping.externalPort)), ("NewProtocol", "TCP"),
        ], group: group)
    }

    /// The router's entry for an external TCP port: (internal client,
    /// internal port), or nil if there is no such mapping (error 714).
    /// Some routers store a wildcard remote host as "0.0.0.0" and only find
    /// the entry when asked that way, so both forms are tried.
    static func mappingEntry(externalPort: Int, gateway: Gateway, group: any EventLoopGroup) async throws -> (client: String, port: Int)? {
        for remoteHost in ["", "0.0.0.0"] {
            switch try await soap(gateway, action: "GetSpecificPortMappingEntry", arguments: [
                ("NewRemoteHost", remoteHost), ("NewExternalPort", String(externalPort)), ("NewProtocol", "TCP"),
            ], group: group) {
            case .success(let body):
                guard let client = xmlValue("NewInternalClient", in: body),
                      let port = xmlValue("NewInternalPort", in: body).flatMap({ Int($0) })
                else { throw PortMappingError.malformedResponse }
                return (client, port)
            case .failure(714):
                continue
            case .failure(let code):
                throw PortMappingError.refused(method: "UPnP-IGD", code: code)
            }
        }
        return nil
    }

    static func externalAddress(_ gateway: Gateway, group: any EventLoopGroup) async throws -> String {
        guard case .success(let body) = try await soap(gateway, action: "GetExternalIPAddress", arguments: [], group: group),
              let address = xmlValue("NewExternalIPAddress", in: body)
        else { throw PortMappingError.malformedResponse }
        return address
    }

    // MARK: Discovery

    /// Finds the router's WAN connection service: SSDP search, then the
    /// device description.
    static func discover(timeout: Duration = .seconds(2), group: any EventLoopGroup) async throws -> Gateway {
        for location in try await ssdpSearch(timeout: timeout, group: group) {
            guard let description = try? await http("GET", location, group: group), description.status == 200,
                  let gateway = parseDescription(description.body, location: location)
            else { continue }
            return gateway
        }
        throw PortMappingError.unsupported
    }

    static func ssdpSearch(timeout: Duration, group: any EventLoopGroup) async throws -> [String] {
        let targets = ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2"]
        let channel = try await DatagramBootstrap(group: group)
            .bind(host: "0.0.0.0", port: 0) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel<AddressedEnvelope<ByteBuffer>, AddressedEnvelope<ByteBuffer>>(wrappingChannelSynchronously: channel)
                }
            }
        let multicast = try SocketAddress(ipAddress: "239.255.255.250", port: 1900)
        let underlying = channel.channel
        var locations: [String] = []
        try await channel.executeThenClose { inbound, outbound in
            await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask {
                    for target in targets {
                        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n"
                        try await outbound.write(AddressedEnvelope(remoteAddress: multicast, data: ByteBuffer(string: search)))
                    }
                    try await Task.sleep(for: timeout)
                    try? await underlying.close()
                }
                do {
                    for try await envelope in inbound {
                        if let location = header("LOCATION", in: String(buffer: envelope.data)), !locations.contains(location) {
                            locations.append(location)
                            break // the first gateway is enough
                        }
                    }
                } catch {}
                tasks.cancelAll()
            }
        }
        return locations
    }

    /// Finds the first WANIPConnection or WANPPPConnection service and
    /// resolves its control URL.
    static func parseDescription(_ xml: String, location: String) -> Gateway? {
        let base = xmlValue("URLBase", in: xml) ?? origin(of: location)
        var rest = Substring(xml)
        while let start = rest.firstRange(of: "<service>"), let end = rest[start.upperBound...].firstRange(of: "</service>") {
            let block = String(rest[start.upperBound..<end.lowerBound])
            rest = rest[end.upperBound...]
            guard let type = xmlValue("serviceType", in: block), let control = xmlValue("controlURL", in: block),
                  type.contains("WANIPConnection") || type.contains("WANPPPConnection")
            else { continue }
            return Gateway(controlURL: resolve(control, against: base), serviceType: type)
        }
        return nil
    }

    // MARK: SOAP

    enum SOAPResult: Equatable {
        case success(String)
        case failure(Int)
    }

    static func soapEnvelope(action: String, serviceType: String, arguments: [(String, String)]) -> String {
        let args = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(serviceType)\">\(args)</u:\(action)></s:Body></s:Envelope>"
    }

    static func soap(_ gateway: Gateway, action: String, arguments: [(String, String)], group: any EventLoopGroup) async throws -> SOAPResult {
        let response = try await http(
            "POST", gateway.controlURL,
            headers: [("Content-Type", "text/xml; charset=\"utf-8\""), ("SOAPAction", "\"\(gateway.serviceType)#\(action)\"")],
            body: soapEnvelope(action: action, serviceType: gateway.serviceType, arguments: arguments),
            group: group
        )
        if response.status == 200 { return .success(response.body) }
        return .failure(xmlValue("errorCode", in: response.body).flatMap { Int($0) } ?? response.status)
    }

    // MARK: Minimal HTTP/1.1 client

    struct HTTPResponse {
        var status: Int
        var body: String
    }

    static func http(
        _ method: String, _ url: String, headers: [(String, String)] = [], body: String = "", group: any EventLoopGroup
    ) async throws -> HTTPResponse {
        guard let (host, port, path) = split(url) else { throw PortMappingError.malformedResponse }
        let channel = try await ClientBootstrap(group: group)
            .connect(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel) }
            }
        let bodyBytes = Array(body.utf8)
        var request = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\nContent-Length: \(bodyBytes.count)\r\n"
        for (name, value) in headers { request += "\(name): \(value)\r\n" }
        request += "\r\n"
        let underlying = channel.channel
        let raw: [UInt8] = try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(bytes: Array(request.utf8) + bodyBytes))
            let timer = Task {
                try await Task.sleep(for: .seconds(5))
                try? await underlying.close()
            }
            defer { timer.cancel() }
            var received: [UInt8] = []
            for try await chunk in inbound {
                received += Array(buffer: chunk)
                guard received.count < 1 << 20, !isComplete(received) else { break }
            }
            return received
        }
        return try parseHTTPResponse(raw)
    }

    /// Parsed as bytes: HTTP is a byte protocol, and in Swift `"\r\n"` is a
    /// single `Character`, which makes character-based parsing error-prone.
    static func parseHTTPResponse(_ raw: [UInt8]) throws(PortMappingError) -> HTTPResponse {
        guard let split = find(crlfcrlf, in: raw) else { throw .malformedResponse }
        let head = String(decoding: raw[..<split], as: UTF8.self)
        let statusLine = head.split(separator: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw .malformedResponse }
        var body = Array(raw[(split + 4)...])
        if header("Transfer-Encoding", in: head)?.lowercased() == "chunked" {
            body = dechunk(body)
        } else if let length = header("Content-Length", in: head).flatMap({ Int($0) }), length < body.count {
            body = Array(body.prefix(length))
        }
        return HTTPResponse(status: status, body: String(decoding: body, as: UTF8.self))
    }

    static func dechunk(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var index = 0
        while let lineEnd = find(crlf, in: bytes, from: index) {
            let sizeField = String(decoding: bytes[index..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeField.trimmingSpaces, radix: 16), size > 0 else { break }
            let start = lineEnd + 2
            let end = min(start + size, bytes.count)
            result += bytes[start..<end]
            index = end + 2
        }
        return result
    }

    /// Whether a response is complete without waiting for the server to
    /// close (some routers ignore `Connection: close`).
    static func isComplete(_ raw: [UInt8]) -> Bool {
        guard let split = find(crlfcrlf, in: raw) else { return false }
        let head = String(decoding: raw[..<split], as: UTF8.self)
        let bodyCount = raw.count - split - 4
        if let length = header("Content-Length", in: head).flatMap({ Int($0) }) { return bodyCount >= length }
        if header("Transfer-Encoding", in: head)?.lowercased() == "chunked" {
            return raw.suffix(5) == [0x30, 13, 10, 13, 10][...]
        }
        return false
    }

    private static let crlf: [UInt8] = [13, 10]
    private static let crlfcrlf: [UInt8] = [13, 10, 13, 10]

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var i = start
        while i + needle.count <= haystack.count {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    private static func localAddress(towards url: String, group: any EventLoopGroup) async throws -> String {
        guard let (host, port, _) = split(url) else { throw PortMappingError.malformedResponse }
        let channel = try await ClientBootstrap(group: group).connect(host: host, port: port).get()
        defer { channel.close(promise: nil) }
        guard let local = channel.localAddress?.ipAddress else { throw PortMappingError.malformedResponse }
        return local
    }

    // MARK: Text helpers

    static func header(_ name: String, in message: String) -> String? {
        for line in message.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == name.lowercased() else { continue }
            return line[line.index(after: colon)...].trimmingSpaces
        }
        return nil
    }

    /// The text of the first `<name>` element (any namespace prefix).
    static func xmlValue(_ name: String, in xml: String) -> String? {
        var rest = Substring(xml)
        while let open = rest.firstRange(of: "<") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.firstIndex(of: ">") else { return nil }
            let tag = afterOpen[..<close]
            let local = tag.split(separator: ":").last ?? ""
            if local == name, !tag.hasPrefix("/") {
                let contentStart = afterOpen.index(after: close)
                guard let end = afterOpen[contentStart...].firstRange(of: "</") else { return nil }
                return String(afterOpen[contentStart..<end.lowerBound]).trimmingSpaces
            }
            rest = afterOpen[close...]
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }

    static func split(_ url: String) -> (host: String, port: Int, path: String)? {
        guard url.hasPrefix("http://") else { return nil }
        let rest = url.dropFirst(7)
        let authority = rest.prefix { $0 != "/" }
        let path = rest.dropFirst(authority.count)
        let parts = authority.split(separator: ":")
        guard let host = parts.first else { return nil }
        let port = parts.count > 1 ? Int(parts[1]) ?? 80 : 80
        return (String(host), port, path.isEmpty ? "/" : String(path))
    }

    static func origin(of url: String) -> String {
        guard let (host, port, _) = split(url) else { return url }
        return "http://\(host):\(port)"
    }

    static func host(of url: String) -> String? { split(url)?.host }

    static func resolve(_ path: String, against base: String) -> String {
        if path.hasPrefix("http://") { return path }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmedBase + (path.hasPrefix("/") ? path : "/" + path)
    }
}

private extension StringProtocol {
    var trimmingSpaces: String {
        String(drop { $0 == " " || $0 == "\t" }.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
    }
}
