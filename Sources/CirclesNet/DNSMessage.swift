/// Just enough of the DNS wire format (RFC 1035) for multicast DNS service
/// discovery (RFC 6762/6763): questions and PTR, SRV, TXT and A records.
/// Names are encoded without compression but decoded with it, since other
/// responders compress.
struct DNSMessage: Equatable {
    var id: UInt16 = 0
    var flags: UInt16 = 0
    var questions: [Question] = []
    var answers: [Record] = []
    var authorities: [Record] = []
    var additionals: [Record] = []

    static let responseFlags: UInt16 = 0x8400 // QR + AA
    var isResponse: Bool { flags & 0x8000 != 0 }

    struct Question: Equatable {
        var name: DNSName
        var type: RecordType
        /// The mDNS "QU" bit: the asker would like a unicast reply.
        var unicastResponse = false
    }

    struct Record: Equatable {
        var name: DNSName
        var cacheFlush = false
        var ttl: UInt32
        var data: RecordData

        var type: RecordType { data.type }
    }
}

struct RecordType: RawRepresentable, Hashable {
    var rawValue: UInt16
    static let a = RecordType(rawValue: 1)
    static let ptr = RecordType(rawValue: 12)
    static let txt = RecordType(rawValue: 16)
    static let srv = RecordType(rawValue: 33)
    static let any = RecordType(rawValue: 255)
}

enum RecordData: Equatable {
    case a([UInt8])
    case ptr(DNSName)
    case srv(priority: UInt16, weight: UInt16, port: UInt16, target: DNSName)
    case txt([String])
    case other(type: UInt16, [UInt8])

    var type: RecordType {
        switch self {
        case .a: .a
        case .ptr: .ptr
        case .srv: .srv
        case .txt: .txt
        case .other(let type, _): RecordType(rawValue: type)
        }
    }
}

/// A domain name as labels. Comparison ignores ASCII case, as DNS requires.
struct DNSName: Hashable, CustomStringConvertible {
    var labels: [String]

    init(_ labels: [String]) {
        self.labels = labels
    }

    init(_ dotted: String) {
        labels = dotted.split(separator: ".").map(String.init)
    }

    var description: String { labels.joined(separator: ".") + "." }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.labels.map { $0.lowercased() } == rhs.labels.map { $0.lowercased() }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(labels.map { $0.lowercased() })
    }

    func prepending(_ label: String) -> DNSName {
        DNSName([label] + labels)
    }
}

enum DNSError: Error {
    case truncated
    case badName
    case labelTooLong
}

// MARK: - Encoding

extension DNSMessage {
    func encoded() throws(DNSError) -> [UInt8] {
        var out: [UInt8] = []
        out.appendUInt16(id)
        out.appendUInt16(flags)
        for count in [questions.count, answers.count, authorities.count, additionals.count] {
            out.appendUInt16(UInt16(count))
        }
        for question in questions {
            try out.appendName(question.name)
            out.appendUInt16(question.type.rawValue)
            out.appendUInt16(1 | (question.unicastResponse ? 0x8000 : 0))
        }
        for record in answers + authorities + additionals {
            try out.appendName(record.name)
            out.appendUInt16(record.type.rawValue)
            out.appendUInt16(1 | (record.cacheFlush ? 0x8000 : 0))
            out.appendUInt32(record.ttl)
            var rdata: [UInt8] = []
            switch record.data {
            case .a(let address):
                rdata = address
            case .ptr(let name):
                try rdata.appendName(name)
            case .srv(let priority, let weight, let port, let target):
                rdata.appendUInt16(priority)
                rdata.appendUInt16(weight)
                rdata.appendUInt16(port)
                try rdata.appendName(target)
            case .txt(let strings):
                for string in strings {
                    let bytes = Array(string.utf8)
                    guard bytes.count <= 255 else { throw .labelTooLong }
                    rdata.append(UInt8(bytes.count))
                    rdata += bytes
                }
                if strings.isEmpty { rdata = [0] }
            case .other(_, let bytes):
                rdata = bytes
            }
            out.appendUInt16(UInt16(rdata.count))
            out += rdata
        }
        return out
    }
}

private extension Array where Element == UInt8 {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(value >> 16))
        appendUInt16(UInt16(value & 0xFFFF))
    }

    mutating func appendName(_ name: DNSName) throws(DNSError) {
        for label in name.labels {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count <= 63 else { throw .labelTooLong }
            append(UInt8(bytes.count))
            self += bytes
        }
        append(0)
    }
}

// MARK: - Decoding

extension DNSMessage {
    init(decoding bytes: [UInt8]) throws(DNSError) {
        var reader = DNSReader(bytes: bytes)
        id = try reader.uint16()
        flags = try reader.uint16()
        let counts = (try reader.uint16(), try reader.uint16(), try reader.uint16(), try reader.uint16())
        for _ in 0..<counts.0 {
            let name = try reader.name()
            let type = try reader.uint16()
            let qclass = try reader.uint16()
            questions.append(Question(name: name, type: RecordType(rawValue: type), unicastResponse: qclass & 0x8000 != 0))
        }
        answers = try (0..<counts.1).map { _ throws(DNSError) in try reader.record() }
        authorities = try (0..<counts.2).map { _ throws(DNSError) in try reader.record() }
        additionals = try (0..<counts.3).map { _ throws(DNSError) in try reader.record() }
    }
}

private struct DNSReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func uint8() throws(DNSError) -> UInt8 {
        guard offset < bytes.count else { throw .truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func uint16() throws(DNSError) -> UInt16 {
        UInt16(try uint8()) << 8 | UInt16(try uint8())
    }

    mutating func uint32() throws(DNSError) -> UInt32 {
        UInt32(try uint16()) << 16 | UInt32(try uint16())
    }

    mutating func take(_ count: Int) throws(DNSError) -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw .truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// Reads a possibly compressed name at the current offset.
    mutating func name() throws(DNSError) -> DNSName {
        var labels: [String] = []
        var position = offset
        var jumped = false
        var jumps = 0
        while true {
            guard position < bytes.count else { throw .truncated }
            let length = bytes[position]
            if length & 0xC0 == 0xC0 {
                guard position + 1 < bytes.count, jumps < 32 else { throw .badName }
                let target = Int(length & 0x3F) << 8 | Int(bytes[position + 1])
                if !jumped { offset = position + 2 }
                jumped = true
                jumps += 1
                position = target
            } else if length & 0xC0 != 0 {
                throw .badName
            } else if length == 0 {
                if !jumped { offset = position + 1 }
                return DNSName(labels)
            } else {
                let end = position + 1 + Int(length)
                guard end <= bytes.count else { throw .truncated }
                labels.append(String(decoding: bytes[(position + 1)..<end], as: UTF8.self))
                guard labels.count <= 128 else { throw .badName }
                position = end
            }
        }
    }

    mutating func record() throws(DNSError) -> DNSMessage.Record {
        let name = try name()
        let type = try uint16()
        let rclass = try uint16()
        let ttl = try uint32()
        let length = Int(try uint16())
        let end = offset + length
        guard end <= bytes.count else { throw .truncated }
        let data: RecordData
        switch RecordType(rawValue: type) {
        case .a where length == 4:
            data = .a(try take(4))
        case .ptr:
            data = .ptr(try self.name())
        case .srv:
            data = .srv(priority: try uint16(), weight: try uint16(), port: try uint16(), target: try self.name())
        case .txt:
            var strings: [String] = []
            while offset < end {
                let count = Int(try uint8())
                let string = try take(count)
                if count > 0 { strings.append(String(decoding: string, as: UTF8.self)) }
            }
            data = .txt(strings)
        default:
            data = .other(type: type, try take(length))
        }
        offset = end
        return DNSMessage.Record(name: name, cacheFlush: rclass & 0x8000 != 0, ttl: ttl, data: data)
    }
}
