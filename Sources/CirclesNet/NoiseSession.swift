public import CirclesCrypto
public import CirclesSync
public import NIOCore
import NIOPosix

/// An established Noise session over TCP, usable as a sync `MessageChannel`.
public final class NoiseSession: MessageChannel {
    public let remoteStaticKey: AgreementPublicKey?
    public let handshakeHash: [UInt8]
    private let sender: Sender
    private let mailbox: Mailbox

    fileprivate init(transport: NoiseTransport, sender: Sender, mailbox: Mailbox) {
        remoteStaticKey = transport.remoteStaticKey
        handshakeHash = transport.handshakeHash
        self.sender = sender
        self.mailbox = mailbox
    }

    public func send(_ message: [UInt8]) async throws {
        try await sender.send(message)
    }

    public func receive() async throws -> [UInt8]? {
        await mailbox.take()
    }
}

/// Connects to a peer, runs the Noise handshake as initiator, and runs
/// `body` with the session. The connection is closed when `body` returns.
public func withNoiseConnection<Result: Sendable>(
    host: String,
    port: Int,
    device: borrowing DeviceKeyPair,
    group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handshakeTimeout: Duration = .seconds(10),
    _ body: @escaping @Sendable (NoiseSession) async throws -> Result
) async throws -> Result {
    try await withNoiseConnection(host: host, port: port, handshake: NoiseHandshake(role: .initiator, device: device),
                                  group: group, handshakeTimeout: handshakeTimeout, body)
}

/// As above, with a prepared initiator handshake, for callers (such as an
/// actor) that can't lend out their device keys across a suspension.
public func withNoiseConnection<Result: Sendable>(
    host: String,
    port: Int,
    handshake: NoiseHandshake,
    group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    handshakeTimeout: Duration = .seconds(10),
    _ body: @escaping @Sendable (NoiseSession) async throws -> Result
) async throws -> Result {
    precondition(handshake.role == .initiator)
    let channel = try await ClientBootstrap(group: group)
        .channelOption(.allowRemoteHalfClosure, value: true)
        .connect(host: host, port: port) { channel in
            channel.eventLoop.makeCompletedFuture { try wrap(channel) }
        }
    return try await runSession(channel, handshake: handshake, timeout: handshakeTimeout, body)
}

/// Listens for peers and runs `handler` for each session, concurrently.
public final class NoiseListener: Sendable {
    private let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    private let template: NoiseHandshake
    private let handshakeTimeout: Duration

    /// The port actually bound (useful when binding port 0).
    public var port: Int { server.channel.localAddress?.port ?? 0 }

    public convenience init(
        host: String = "0.0.0.0",
        port: Int,
        device: borrowing DeviceKeyPair,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        handshakeTimeout: Duration = .seconds(10)
    ) async throws {
        try await self.init(host: host, port: port, handshake: NoiseHandshake(role: .responder, device: device),
                            group: group, handshakeTimeout: handshakeTimeout)
    }

    /// `handshake` is a fresh responder handshake, copied for each connection.
    public init(
        host: String = "0.0.0.0",
        port: Int,
        handshake: NoiseHandshake,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        handshakeTimeout: Duration = .seconds(10)
    ) async throws {
        precondition(handshake.role == .responder)
        template = handshake
        self.handshakeTimeout = handshakeTimeout
        server = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture { try wrap(channel) }
            }
    }

    /// Accepts connections until cancelled. Each session ends when its
    /// handler returns. Errors in one session never affect others.
    public func run(_ handler: @escaping @Sendable (NoiseSession) async throws -> Void) async throws {
        try await server.executeThenClose { connections in
            try await withThrowingDiscardingTaskGroup { group in
                for try await connection in connections {
                    let handshake = template, timeout = handshakeTimeout
                    group.addTask {
                        try? await runSession(connection, handshake: handshake, timeout: timeout, handler)
                    }
                }
            }
        }
    }
}

// MARK: - Internals

/// How long to wait for the peer to close after our side has finished.
private let lingerTime: Duration = .seconds(5)

private func wrap(_ channel: any Channel) throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NoiseFrameDecoder()))
    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
        wrappingChannelSynchronously: channel,
        configuration: .init(isOutboundHalfClosureEnabled: true)
    )
}

private func runSession<Result: Sendable>(
    _ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    handshake: NoiseHandshake,
    timeout: Duration,
    _ body: @escaping @Sendable (NoiseSession) async throws -> Result
) async throws -> Result {
    try await channel.executeThenClose { inbound, outbound in
        var frames = inbound.makeAsyncIterator()
        // A peer that stalls mid-handshake gets disconnected, which ends the
        // read below.
        let underlying = channel.channel
        let timer = Task {
            try await Task.sleep(for: timeout)
            try? await underlying.close()
        }
        var handshake = handshake
        while !handshake.isComplete {
            if handshake.isMyTurn {
                try await outbound.write(framed(try handshake.writeMessage()))
            } else {
                guard let frame = try await frames.next() else {
                    throw timer.isCancelled ? NetError.connectionClosed : NetError.handshakeTimedOut
                }
                _ = try handshake.readMessage(Array(buffer: frame))
            }
        }
        timer.cancel()
        let transport = try handshake.split()

        let mailbox = Mailbox()
        let session = NoiseSession(transport: transport, sender: Sender(cipher: transport.send, writer: outbound), mailbox: mailbox)
        return try await withThrowingTaskGroup(of: Result.self) { group in
            // The session body runs as a child task. When it finishes, our
            // side half-closes (pending writes are flushed first), and the
            // connection is closed outright if the peer doesn't follow
            // within the linger time.
            group.addTask {
                defer {
                    outbound.finish()
                    Task {
                        try await Task.sleep(for: lingerTime)
                        try? await underlying.close()
                    }
                }
                return try await body(session)
            }

            // Decrypt and reassemble incoming messages until the peer closes
            // or misbehaves.
            var cipher = transport.receive
            var reassembler = MessageReassembler()
            do {
                while let frame = try await frames.next() {
                    if let message = try reassembler.add(try cipher.decrypt(Array(buffer: frame))) {
                        await mailbox.put(message)
                    }
                }
            } catch {}
            await mailbox.close()
            return try await group.next()!
        }
    }
}

/// Serializes outgoing messages: chunks, encrypts and writes each in one go,
/// so concurrent sends can't interleave chunks or reorder nonces.
private actor Sender {
    private var cipher: NoiseCipherState
    private let writer: NIOAsyncChannelOutboundWriter<ByteBuffer>

    init(cipher: NoiseCipherState, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        self.cipher = cipher
        self.writer = writer
    }

    func send(_ message: [UInt8]) async throws {
        guard message.count <= MessageReassembler.maxMessageLength else { throw NetError.messageTooLarge }
        var frames: [ByteBuffer] = []
        for chunk in MessageReassembler.chunks(message) {
            frames.append(framed(try cipher.encrypt(Array(chunk))))
        }
        try await writer.write(contentsOf: frames)
    }
}

/// A single-consumer FIFO of received messages.
private actor Mailbox {
    private var buffer: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Never>?
    private var closed = false

    func put(_ message: [UInt8]) {
        guard !closed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            buffer.append(message)
        }
    }

    func close() {
        closed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func take() async -> [UInt8]? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiter = $0 }
    }
}
