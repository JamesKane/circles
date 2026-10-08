import CirclesCore
public import CirclesCrypto
public import NIOCore
import NIOPosix

/// Relayed connections (docs/DESIGN.md §5.1, §7.3), similar to libp2p's
/// circuit relay v2.
///
/// 1. A device that wants to be reachable opens a *control connection* to
///    the relay, completes a Noise handshake with its device key, and sends
///    `reserve`. The relay now knows that device by its static key.
/// 2. A peer opens a *data connection*, completes a handshake, and sends
///    `connect(target key)`. The relay tells the reserved device `incoming(token)`.
/// 3. The reserved device opens its own data connection and sends `accept(token)`.
/// 4. The relay answers `ok` on both data connections, then stops speaking
///    Noise to either side and forwards frames between them unchanged. The
///    two peers run their own Noise XX session through it end to end, so the
///    relay sees only ciphertext and can't impersonate either side.
///
/// The relay authenticates clients only by their static key: anyone may
/// reserve, but only for a key they hold.
enum RelayRequest: Sendable, Equatable {
    case reserve
    case connect(target: AgreementPublicKey)
    case accept(token: [UInt8])
}

enum RelayResponse: Sendable, Equatable {
    case ok
    case error(String)
    case incoming(token: [UInt8], from: AgreementPublicKey)
}

extension RelayRequest: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        switch try container.decode(UInt64.self) {
        case 0: self = .reserve
        case 1: self = .connect(target: try container.decode(AgreementPublicKey.self))
        case 2: self = .accept(token: try container.decode([UInt8].self))
        case let tag: throw CBORError.custom("unknown relay request \(tag)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .reserve:
            try container.encode(UInt64(0))
        case .connect(let target):
            try container.encode(UInt64(1))
            try container.encode(target)
        case .accept(let token):
            try container.encode(UInt64(2))
            try container.encode(token)
        }
    }
}

extension RelayResponse: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        switch try container.decode(UInt64.self) {
        case 0: self = .ok
        case 1: self = .error(try container.decode(String.self))
        case 2: self = .incoming(token: try container.decode([UInt8].self), from: try container.decode(AgreementPublicKey.self))
        case let tag: throw CBORError.custom("unknown relay response \(tag)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .ok:
            try container.encode(UInt64(0))
        case .error(let reason):
            try container.encode(UInt64(1))
            try container.encode(reason)
        case .incoming(let token, let from):
            try container.encode(UInt64(2))
            try container.encode(token)
            try container.encode(from)
        }
    }
}

public enum RelayError: Error, Sendable, Equatable {
    case refused(String)
    case unexpectedRelayKey
    case unexpectedPeerKey
    case protocolViolation
}

// MARK: - Single control messages over a Noise transport

/// Sends one small message encrypted with `cipher` (one frame, same chunk
/// format as `NoiseSession`).
func sendControl(_ value: some Encodable, cipher: inout NoiseCipherState, outbound: FrameWriter) async throws {
    let chunks = MessageReassembler.chunks(try CBOREncoder().encode(value))
    guard chunks.count == 1 else { throw NetError.messageTooLarge }
    try await outbound.write(framed(try cipher.encrypt(Array(chunks[0]))))
}

func receiveControl<T: Decodable>(_ type: T.Type, cipher: inout NoiseCipherState, frames: inout Frames) async throws -> T {
    guard let frame = try await frames.next() else { throw NetError.connectionClosed }
    var reassembler = MessageReassembler()
    guard let message = try reassembler.add(try cipher.decrypt(Array(buffer: frame))) else {
        throw RelayError.protocolViolation
    }
    return try CBORDecoder().decode(type, from: message)
}

// MARK: - Relay server

/// A relay node. Holds no user data, only short-lived reservations and circuits.
public final class RelayServer: Sendable {
    public struct Limits: Sendable {
        public var maxReservations = 1024
        public var circuitDuration: Duration = .seconds(600)
        public var circuitBytes = 64 << 20
        public var acceptTimeout: Duration = .seconds(10)

        public init() {}
    }

    private let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    private let template: NoiseHandshake
    private let limits: Limits
    private let state = RelayState()

    public var port: Int { server.channel.localAddress?.port ?? 0 }

    /// `handshake` is a fresh responder handshake for the relay's own key.
    public init(
        host: String = "0.0.0.0",
        port: Int,
        handshake: NoiseHandshake,
        limits: Limits = Limits(),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) async throws {
        precondition(handshake.role == .responder)
        template = handshake
        self.limits = limits
        server = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture { try wrap(channel) }
            }
    }

    public func run() async throws {
        try await server.executeThenClose { connections in
            try await withThrowingDiscardingTaskGroup { group in
                for try await connection in connections {
                    group.addTask { [self] in
                        try? await handle(connection)
                    }
                }
            }
        }
    }

    private func handle(_ connection: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws {
        try await connection.executeThenClose { inbound, outbound in
            var frames = inbound.makeAsyncIterator()
            let transport = try await performHandshake(template, frames: &frames, outbound: outbound,
                                                       underlying: connection.channel, timeout: .seconds(10))
            var send = transport.send, receive = transport.receive
            let client = transport.remoteStaticKey

            switch try await receiveControl(RelayRequest.self, cipher: &receive, frames: &frames) {
            case .reserve:
                let link = ControlLink(cipher: send, outbound: outbound)
                guard await state.reserve(client, link: link, limit: limits.maxReservations) else {
                    try await sendControl(RelayResponse.error("relay full"), cipher: &send, outbound: outbound)
                    return
                }
                await link.send(.ok)
                // Hold the reservation until the client disconnects.
                while (try? await frames.next()) != nil {}
                await state.release(client, link: link)
                await link.close()

            case .connect(let target):
                guard let reservation = await state.reservation(for: target) else {
                    try await sendControl(RelayResponse.error("no reservation for target"), cipher: &send, outbound: outbound)
                    return
                }
                let token = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
                let circuit = await state.openCircuit(token: token, target: target, initiatorOutbound: outbound)
                await reservation.send(.incoming(token: token, from: client))
                guard let targetOutbound = await circuit.waitForTarget(timeout: limits.acceptTimeout) else {
                    await state.closeCircuit(token)
                    try await sendControl(RelayResponse.error("target did not accept"), cipher: &send, outbound: outbound)
                    return
                }
                try await sendControl(RelayResponse.ok, cipher: &send, outbound: outbound)
                try await forward(&frames, to: targetOutbound, underlying: connection.channel)

            case .accept(let token):
                guard let circuit = await state.takeCircuit(token), circuit.target == client else {
                    try await sendControl(RelayResponse.error("unknown circuit"), cipher: &send, outbound: outbound)
                    return
                }
                // Our ok goes out before the initiator can learn our outbound
                // writer, so it always precedes forwarded frames.
                try await sendControl(RelayResponse.ok, cipher: &send, outbound: outbound)
                let initiatorOutbound = await circuit.connect(targetOutbound: outbound)
                try await forward(&frames, to: initiatorOutbound, underlying: connection.channel)
            }
        }
    }

    /// Forwards frames unchanged until either side ends or a limit is hit.
    private func forward(_ frames: inout Frames, to other: FrameWriter, underlying: any Channel) async throws {
        let deadline = Task {
            try await Task.sleep(for: limits.circuitDuration)
            try? await underlying.close()
        }
        defer {
            deadline.cancel()
            other.finish()
        }
        var total = 0
        while let frame = try await frames.next() {
            total += frame.readableBytes + 2
            guard total <= limits.circuitBytes else { return }
            try await other.write(framed(Array(buffer: frame)))
        }
    }
}

/// Sends `incoming` notifications on a reservation's control connection.
/// Frames are encrypted in order and written by a single task in that same
/// order, since the client decrypts with a counter nonce.
private actor ControlLink {
    private var cipher: NoiseCipherState
    private let queue: AsyncStream<ByteBuffer>.Continuation

    init(cipher: NoiseCipherState, outbound: FrameWriter) {
        self.cipher = cipher
        let (frames, queue) = AsyncStream.makeStream(of: ByteBuffer.self)
        self.queue = queue
        Task {
            for await frame in frames {
                try? await outbound.write(frame)
            }
        }
    }

    func send(_ response: RelayResponse) {
        guard let message = try? CBOREncoder().encode(response),
              let encrypted = try? cipher.encrypt(Array(MessageReassembler.chunks(message)[0]))
        else { return }
        queue.yield(framed(encrypted))
    }

    func close() {
        queue.finish()
    }
}

/// A pending or established circuit: a rendezvous between the initiator's
/// and the target's data connections.
private actor Circuit {
    let target: AgreementPublicKey
    private let initiatorOutbound: FrameWriter
    private var targetOutbound: FrameWriter?
    private var waiter: CheckedContinuation<FrameWriter?, Never>?

    init(target: AgreementPublicKey, initiatorOutbound: FrameWriter) {
        self.target = target
        self.initiatorOutbound = initiatorOutbound
    }

    func connect(targetOutbound: FrameWriter) -> FrameWriter {
        self.targetOutbound = targetOutbound
        waiter?.resume(returning: targetOutbound)
        waiter = nil
        return initiatorOutbound
    }

    func waitForTarget(timeout: Duration) async -> FrameWriter? {
        if let targetOutbound { return targetOutbound }
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.expire()
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func expire() {
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

private actor RelayState {
    private var reservations: [AgreementPublicKey: ControlLink] = [:]
    private var circuits: [[UInt8]: Circuit] = [:]

    func reserve(_ key: AgreementPublicKey, link: ControlLink, limit: Int) -> Bool {
        guard reservations[key] != nil || reservations.count < limit else { return false }
        reservations[key] = link // a newer reservation replaces an older one
        return true
    }

    func release(_ key: AgreementPublicKey, link: ControlLink) {
        if reservations[key] === link { reservations[key] = nil }
    }

    func reservation(for key: AgreementPublicKey) -> ControlLink? { reservations[key] }

    func openCircuit(token: [UInt8], target: AgreementPublicKey, initiatorOutbound: FrameWriter) -> Circuit {
        let circuit = Circuit(target: target, initiatorOutbound: initiatorOutbound)
        circuits[token] = circuit
        return circuit
    }

    func takeCircuit(_ token: [UInt8]) -> Circuit? {
        circuits.removeValue(forKey: token)
    }

    func closeCircuit(_ token: [UInt8]) {
        circuits[token] = nil
    }
}

// MARK: - Relay clients

/// How to reach a relay. If `key` is set, the relay must prove it holds it.
public struct RelayAddress: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var key: AgreementPublicKey?

    public init(host: String, port: Int, key: AgreementPublicKey? = nil) {
        self.host = host
        self.port = port
        self.key = key
    }
}

/// Connects to `target` through a relay and runs `body` over the end-to-end
/// session. `outer` authenticates us to the relay; `inner` is the end-to-end
/// handshake. Both must be initiator handshakes for this device.
public func withRelayedConnection<Result: Sendable>(
    via relay: RelayAddress,
    to target: AgreementPublicKey,
    outer: NoiseHandshake,
    inner: NoiseHandshake,
    group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    timeout: Duration = .seconds(15),
    _ body: @escaping @Sendable (NoiseSession) async throws -> Result
) async throws -> Result {
    precondition(outer.role == .initiator && inner.role == .initiator)
    let channel = try await connectTCP(relay, group: group)
    return try await channel.executeThenClose { inbound, outbound in
        var frames = inbound.makeAsyncIterator()
        var transport = try await performHandshake(outer, frames: &frames, outbound: outbound,
                                                   underlying: channel.channel, timeout: timeout)
        try check(transport, relay)
        try await sendControl(RelayRequest.connect(target: target), cipher: &transport.send, outbound: outbound)
        try await expectOK(cipher: &transport.receive, frames: &frames)

        let session = try await performHandshake(inner, frames: &frames, outbound: outbound,
                                                 underlying: channel.channel, timeout: timeout)
        guard session.remoteStaticKey == target else { throw RelayError.unexpectedPeerKey }
        return try await runEstablished(session, frames: &frames, outbound: outbound, underlying: channel.channel, body)
    }
}

/// Keeps a reservation on a relay and runs `handler` for each peer that
/// connects through it, until cancelled or the relay drops the reservation.
/// `outer` is an initiator handshake for this device; `inner` a responder
/// handshake (copied per circuit).
public func serveViaRelay(
    _ relay: RelayAddress,
    outer: NoiseHandshake,
    inner: NoiseHandshake,
    group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    onReserved: @escaping @Sendable () -> Void = {},
    _ handler: @escaping @Sendable (NoiseSession) async throws -> Void
) async throws {
    precondition(outer.role == .initiator && inner.role == .responder)
    let channel = try await connectTCP(relay, group: group)
    try await channel.executeThenClose { inbound, outbound in
        var frames = inbound.makeAsyncIterator()
        var transport = try await performHandshake(outer, frames: &frames, outbound: outbound,
                                                   underlying: channel.channel, timeout: .seconds(15))
        try check(transport, relay)
        try await sendControl(RelayRequest.reserve, cipher: &transport.send, outbound: outbound)
        try await expectOK(cipher: &transport.receive, frames: &frames)
        onReserved()

        try await withThrowingDiscardingTaskGroup { circuits in
            while true {
                let response = try await receiveControl(RelayResponse.self, cipher: &transport.receive, frames: &frames)
                guard case .incoming(let token, _) = response else { throw RelayError.protocolViolation }
                circuits.addTask {
                    try? await acceptCircuit(relay, token: token, outer: outer, inner: inner, group: group, handler)
                }
            }
        }
    }
}

private func acceptCircuit(
    _ relay: RelayAddress,
    token: [UInt8],
    outer: NoiseHandshake,
    inner: NoiseHandshake,
    group: any EventLoopGroup,
    _ handler: @escaping @Sendable (NoiseSession) async throws -> Void
) async throws {
    let channel = try await connectTCP(relay, group: group)
    try await channel.executeThenClose { inbound, outbound in
        var frames = inbound.makeAsyncIterator()
        var transport = try await performHandshake(outer, frames: &frames, outbound: outbound,
                                                   underlying: channel.channel, timeout: .seconds(15))
        try check(transport, relay)
        try await sendControl(RelayRequest.accept(token: token), cipher: &transport.send, outbound: outbound)
        try await expectOK(cipher: &transport.receive, frames: &frames)
        let session = try await performHandshake(inner, frames: &frames, outbound: outbound,
                                                 underlying: channel.channel, timeout: .seconds(15))
        try await runEstablished(session, frames: &frames, outbound: outbound, underlying: channel.channel, handler)
    }
}

private func connectTCP(_ relay: RelayAddress, group: any EventLoopGroup) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
    try await ClientBootstrap(group: group)
        .channelOption(.allowRemoteHalfClosure, value: true)
        .connectTimeout(.seconds(5))
        .connect(host: relay.host, port: relay.port) { channel in
            channel.eventLoop.makeCompletedFuture { try wrap(channel) }
        }
}

private func check(_ transport: NoiseTransport, _ relay: RelayAddress) throws {
    if let key = relay.key, transport.remoteStaticKey != key { throw RelayError.unexpectedRelayKey }
}

private func expectOK(cipher: inout NoiseCipherState, frames: inout Frames) async throws {
    switch try await receiveControl(RelayResponse.self, cipher: &cipher, frames: &frames) {
    case .ok: return
    case .error(let reason): throw RelayError.refused(reason)
    case .incoming: throw RelayError.protocolViolation
    }
}
