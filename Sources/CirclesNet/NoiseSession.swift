public import CirclesCrypto
public import CirclesSync
public import NIOCore
import NIOPosix

/// An established Noise session over TCP, usable as a sync `MessageChannel`.
public final class NoiseSession: MessageChannel {
    public let remoteStaticKey: AgreementPublicKey?
    public let handshakeHash: [UInt8]
    /// The peer's IP address as this connection saw it; nil for relayed
    /// sessions, where the connection's other end is the relay.
    public let remoteHost: String?
    private let sender: Sender
    private let mailbox: Mailbox

    fileprivate init(transport: NoiseTransport, sender: Sender, mailbox: Mailbox, remoteHost: String?) {
        self.remoteHost = remoteHost
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
    purpose: UInt8? = nil,
    _ body: @escaping @Sendable (NoiseSession) async throws -> Result
) async throws -> Result {
    precondition(handshake.role == .initiator)
    let channel = try await ClientBootstrap(group: group)
        .channelOption(.allowRemoteHalfClosure, value: true)
        .connectTimeout(.seconds(5))
        .connect(host: host, port: port) { channel in
            channel.eventLoop.makeCompletedFuture { try wrap(channel) }
        }
    return try await runSession(channel, handshake: handshake, timeout: handshakeTimeout, firstPayload: purpose.map { [$0] } ?? [], body)
}

/// Listens for peers and runs `handler` for each session, concurrently.
public final class NoiseListener: Sendable {
    private let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    private let template: NoiseHandshake
    private let handshakeTimeout: Duration
    private let limiter: ConnectionLimiter
    private let alternates: [UInt8: NoiseHandshake]

    /// The port actually bound (useful when binding port 0).
    public var port: Int { server.channel.localAddress?.port ?? 0 }

    public convenience init(
        host: String = "0.0.0.0",
        port: Int,
        device: borrowing DeviceKeyPair,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        handshakeTimeout: Duration = .seconds(10),
        limits: ConnectionLimits = .default
    ) async throws {
        try await self.init(host: host, port: port, handshake: NoiseHandshake(role: .responder, device: device),
                            group: group, handshakeTimeout: handshakeTimeout, limits: limits)
    }

    /// `handshake` is a fresh responder handshake, copied for each connection.
    public init(
        host: String = "0.0.0.0",
        port: Int,
        handshake: NoiseHandshake,
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        handshakeTimeout: Duration = .seconds(10),
        limits: ConnectionLimits = .default,
        alternates: [UInt8: NoiseHandshake] = [:]
    ) async throws {
        precondition(handshake.role == .responder)
        template = handshake
        self.alternates = alternates
        self.handshakeTimeout = handshakeTimeout
        limiter = ConnectionLimiter(limits)
        server = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture { try wrap(channel) }
            }
    }

    /// Connections currently open.
    public var activeConnections: Int { limiter.active }

    /// Accepts connections until cancelled, within the listener's limits.
    /// Each session ends when its handler returns. Errors in one session
    /// never affect others.
    public func run(_ handler: @escaping @Sendable (NoiseSession) async throws -> Void) async throws {
        try await server.executeThenClose { connections in
            try await withThrowingDiscardingTaskGroup { group in
                for try await connection in connections {
                    let ip = connection.channel.remoteAddress?.ipAddress ?? "?"
                    guard limiter.admit(ip) else {
                        try? await connection.channel.close()
                        continue
                    }
                    let handshake = template, timeout = handshakeTimeout, limiter = limiter, alternates = alternates
                    group.addTask {
                        defer { limiter.release(ip) }
                        try? await runSession(connection, handshake: handshake, timeout: timeout,
                                              idleTimeout: limiter.limits.idleTimeout, alternates: alternates, handler)
                    }
                }
            }
        }
    }
}

// MARK: - Internals

/// How long to wait for the peer to close after our side has finished.
let lingerTime: Duration = .seconds(5)

func wrap(_ channel: any Channel) throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(NoiseFrameDecoder()))
    return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
        wrappingChannelSynchronously: channel,
        configuration: .init(isOutboundHalfClosureEnabled: true)
    )
}

func runSession<Result: Sendable>(
    _ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
    handshake: NoiseHandshake,
    timeout: Duration,
    idleTimeout: Duration = ConnectionLimits.default.idleTimeout,
    firstPayload: [UInt8] = [],
    alternates: [UInt8: NoiseHandshake] = [:],
    _ body: @escaping @Sendable (NoiseSession) async throws -> Result
) async throws -> Result {
    try await channel.executeThenClose { inbound, outbound in
        var frames = inbound.makeAsyncIterator()
        let transport = try await performHandshake(handshake, frames: &frames, outbound: outbound,
                                                   underlying: channel.channel, timeout: timeout,
                                                   firstPayload: firstPayload, alternates: alternates)
        return try await runEstablished(transport, frames: &frames, outbound: outbound,
                                        underlying: channel.channel, remoteHost: channel.channel.remoteAddress?.ipAddress,
                                        idleTimeout: idleTimeout, body)
    }
}

typealias Frames = NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
typealias FrameWriter = NIOAsyncChannelOutboundWriter<ByteBuffer>

/// Runs a Noise handshake over frames. A peer that stalls is disconnected
/// after `timeout`, which ends the read.
func performHandshake(
    _ handshake: NoiseHandshake,
    frames: inout Frames,
    outbound: FrameWriter,
    underlying: any Channel,
    timeout: Duration,
    firstPayload: [UInt8] = [],
    alternates: [UInt8: NoiseHandshake] = [:]
) async throws -> NoiseTransport {
    let timer = Task {
        try await Task.sleep(for: timeout)
        try? await underlying.close()
    }
    defer { timer.cancel() }
    var handshake = handshake
    var first = true
    while !handshake.isComplete {
        if handshake.isMyTurn {
            try await outbound.write(framed(try handshake.writeMessage(payload: first ? firstPayload : [])))
        } else {
            guard let frame = try await frames.next() else {
                throw timer.isCancelled ? NetError.connectionClosed : NetError.handshakeTimedOut
            }
            let payload = try handshake.readMessage(Array(buffer: frame))
            // The initiator's first message may name a purpose that this
            // responder answers with a different static key (the DHT's).
            if first, handshake.role == .responder, let purpose = payload.first, var alternate = alternates[purpose] {
                _ = try alternate.readMessage(Array(buffer: frame))
                handshake = alternate
            }
        }
        first = false
    }
    return try handshake.split()
}

/// Runs `body` over an established session. The body runs as a child task;
/// the read loop stays in this task, which owns the frame iterator. When the
/// body finishes, our side half-closes (pending writes are flushed first),
/// and the connection is closed outright if the peer doesn't follow within
/// the linger time.
func runEstablished<Result: Sendable>(
    _ transport: NoiseTransport,
    frames: inout Frames,
    outbound: FrameWriter,
    underlying: any Channel,
    remoteHost: String? = nil,
    idleTimeout: Duration = ConnectionLimits.default.idleTimeout,
    _ body: @escaping @Sendable (NoiseSession) async throws -> Result
) async throws -> Result {
    let mailbox = Mailbox()
    let activity = Activity()
    let session = NoiseSession(transport: transport, sender: Sender(cipher: transport.send, writer: outbound, activity: activity),
                               mailbox: mailbox, remoteHost: remoteHost)
    // Close a session where nothing moves either way for `idleTimeout`, so
    // a peer can't hold a connection open by going quiet after the handshake.
    let watchdog = Task {
        while !Task.isCancelled {
            try await Task.sleep(for: idleTimeout / 4)
            if activity.idle > idleTimeout {
                try? await underlying.close()
                return
            }
        }
    }
    defer { watchdog.cancel() }
    return try await withThrowingTaskGroup(of: Result.self) { group in
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

        var cipher = transport.receive
        var reassembler = MessageReassembler()
        do {
            while let frame = try await frames.next() {
                activity.touch()
                if let message = try reassembler.add(try cipher.decrypt(Array(buffer: frame))) {
                    await mailbox.put(message)
                }
            }
        } catch {}
        await mailbox.close()
        return try await group.next()!
    }
}

/// Serializes outgoing messages: chunks, encrypts and writes each in one go,
/// so concurrent sends can't interleave chunks or reorder nonces.
private actor Sender {
    private var cipher: NoiseCipherState
    private let writer: NIOAsyncChannelOutboundWriter<ByteBuffer>
    private let activity: Activity?

    init(cipher: NoiseCipherState, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>, activity: Activity? = nil) {
        self.cipher = cipher
        self.writer = writer
        self.activity = activity
    }

    func send(_ message: [UInt8]) async throws {
        guard message.count <= MessageReassembler.maxMessageLength else { throw NetError.messageTooLarge }
        var frames: [ByteBuffer] = []
        for chunk in MessageReassembler.chunks(message) {
            frames.append(framed(try cipher.encrypt(Array(chunk))))
        }
        try await writer.write(contentsOf: frames)
        activity?.touch()
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
