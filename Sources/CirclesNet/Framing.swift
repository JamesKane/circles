import NIOCore

/// Splits the TCP byte stream into Noise messages, each prefixed with a
/// 2-byte big-endian length (the Noise spec's recommended framing).
struct NoiseFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
              buffer.readableBytes >= 2 + Int(length)
        else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 2)
        context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: Int(length))!))
        return .continue
    }
}

func framed(_ message: [UInt8]) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.reserveCapacity(message.count + 2)
    buffer.writeInteger(UInt16(message.count))
    buffer.writeBytes(message)
    return buffer
}

/// Application messages can exceed one Noise message (65535 bytes), so each
/// is sent as `UInt32 length || bytes` split across as many Noise messages as
/// needed. A Noise message never carries parts of two application messages.
struct MessageReassembler {
    static let maxMessageLength = 16 << 20
    static let maxChunk = 65535 - 16

    private var expected: Int?
    private var buffer: [UInt8] = []

    static func chunks(_ message: [UInt8]) -> [ArraySlice<UInt8>] {
        let length = UInt32(message.count)
        let stream = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) } + message
        return stride(from: 0, to: stream.count, by: maxChunk).map { stream[$0..<min($0 + maxChunk, stream.count)] }
    }

    mutating func add(_ chunk: [UInt8]) throws(NetError) -> [UInt8]? {
        if expected == nil {
            guard chunk.count >= 4 else { throw .malformedFrame }
            let length = chunk.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxMessageLength else { throw .messageTooLarge }
            expected = length
            buffer = Array(chunk.dropFirst(4))
        } else {
            buffer += chunk
        }
        guard let expected, buffer.count >= expected else { return nil }
        guard buffer.count == expected else { throw .malformedFrame }
        defer {
            self.expected = nil
            buffer = []
        }
        return buffer
    }
}

public enum NetError: Error, Sendable {
    case malformedFrame
    case messageTooLarge
    case connectionClosed
    case handshakeTimedOut
}
