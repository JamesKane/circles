import NIOCore

/// NAT-PMP (RFC 6886).
enum NATPMP {
    static let port = 5351

    static func mapRequest(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0, 2, 0, 0] // version 0, opcode 2 = map TCP
        bytes.append(contentsOf: be(internalPort))
        bytes.append(contentsOf: be(externalPort))
        bytes.append(contentsOf: be(lifetime))
        return bytes
    }

    struct MapResponse: Equatable {
        var resultCode: UInt16
        var internalPort: UInt16
        var externalPort: UInt16
        var lifetime: UInt32
    }

    static func parseMapResponse(_ bytes: [UInt8]) throws(PortMappingError) -> MapResponse {
        guard bytes.count >= 16, bytes[0] == 0, bytes[1] == 130 else { throw .malformedResponse }
        return MapResponse(resultCode: u16(bytes, 2), internalPort: u16(bytes, 8), externalPort: u16(bytes, 10), lifetime: u32(bytes, 12))
    }

    static func parseExternalAddress(_ bytes: [UInt8]) throws(PortMappingError) -> String {
        guard bytes.count >= 12, bytes[0] == 0, bytes[1] == 128 else { throw .malformedResponse }
        guard u16(bytes, 2) == 0 else { throw .refused(method: "NAT-PMP", code: Int(u16(bytes, 2))) }
        return bytes[8..<12].map(String.init).joined(separator: ".")
    }

    static func map(tcpPort: Int, externalPort: Int, lifetime: UInt32, gateway: String, group: any EventLoopGroup) async throws -> PortMapping {
        let reply = try await udpRequest(
            mapRequest(internalPort: UInt16(tcpPort), externalPort: UInt16(externalPort), lifetime: lifetime),
            to: gateway, port: port, group: group
        )
        let response = try parseMapResponse(reply)
        guard response.resultCode == 0 else { throw PortMappingError.refused(method: "NAT-PMP", code: Int(response.resultCode)) }
        let address = try? parseExternalAddress(try await udpRequest([0, 0], to: gateway, port: port, group: group))
        return PortMapping(method: .natPMP, gateway: gateway, internalPort: tcpPort, externalPort: Int(response.externalPort),
                           externalAddress: address, lifetime: response.lifetime)
    }
}

/// PCP (RFC 6887), MAP opcode for TCP over IPv4.
enum PCP {
    static func mapRequest(clientAddress: [UInt8], nonce: [UInt8], internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [2, 1, 0, 0]                       // version 2, request, opcode MAP
        bytes += be(lifetime)
        bytes += [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + clientAddress // IPv4-mapped IPv6
        bytes += nonce                                          // 12 bytes
        bytes += [6, 0, 0, 0]                                   // protocol TCP, reserved
        bytes += be(internalPort)
        bytes += be(externalPort)
        bytes += [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + [0, 0, 0, 0] // no preferred external address
        return bytes
    }

    struct MapResponse: Equatable {
        var resultCode: UInt8
        var lifetime: UInt32
        var nonce: [UInt8]
        var internalPort: UInt16
        var externalPort: UInt16
        var externalAddress: String
    }

    static func parseMapResponse(_ bytes: [UInt8]) throws(PortMappingError) -> MapResponse {
        // A NAT-PMP-only router answers with version 0 "unsupported version".
        guard bytes.count >= 60, bytes[0] == 2, bytes[1] == 0x81 else { throw .unsupported }
        let address = bytes[56..<60].map(String.init).joined(separator: ".")
        return MapResponse(resultCode: bytes[3], lifetime: u32(bytes, 4), nonce: Array(bytes[24..<36]),
                           internalPort: u16(bytes, 40), externalPort: u16(bytes, 42), externalAddress: address)
    }

    static func map(tcpPort: Int, externalPort: Int, lifetime: UInt32, gateway: String, group: any EventLoopGroup) async throws -> PortMapping {
        let nonce = (0..<12).map { _ in UInt8.random(in: .min ... .max) }
        let reply = try await udpRequest([], to: gateway, port: NATPMP.port, group: group) { local in
            mapRequest(clientAddress: ipv4Bytes(local) ?? [0, 0, 0, 0], nonce: nonce,
                       internalPort: UInt16(tcpPort), externalPort: UInt16(externalPort), lifetime: lifetime)
        }
        let response = try parseMapResponse(reply)
        guard response.nonce == nonce else { throw PortMappingError.malformedResponse }
        guard response.resultCode == 0 else { throw PortMappingError.refused(method: "PCP", code: Int(response.resultCode)) }
        return PortMapping(method: .pcp, gateway: gateway, internalPort: tcpPort, externalPort: Int(response.externalPort),
                           externalAddress: response.externalAddress, lifetime: response.lifetime)
    }
}

func be(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
func be(_ value: UInt32) -> [UInt8] { be(UInt16(value >> 16)) + be(UInt16(value & 0xFFFF)) }
func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { UInt32(u16(bytes, at)) << 16 | UInt32(u16(bytes, at + 2)) }
