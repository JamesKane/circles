public import CirclesCrypto

/// A reliable, ordered, authenticated channel of discrete messages, such as
/// a Noise session over TCP (`CirclesNet`) or an in-memory pair for tests.
///
/// `send` and `receive` may be called concurrently from different tasks,
/// but each only from one task at a time.
public protocol MessageChannel: Sendable {
    /// The X25519 static key the peer proved possession of during the
    /// handshake, if the transport authenticates peers.
    var remoteStaticKey: AgreementPublicKey? { get }
    func send(_ message: [UInt8]) async throws
    /// The next message, or nil once the peer has closed the channel.
    func receive() async throws -> [UInt8]?
}

/// One end of an in-memory `MessageChannel` pair.
public final class MemoryChannel: MessageChannel {
    public let remoteStaticKey: AgreementPublicKey?
    private let outbound: Mailbox
    private let inbound: Mailbox

    /// Two connected ends. Each reports the *other* side's static key.
    public static func pair(
        staticKeys: (AgreementPublicKey?, AgreementPublicKey?) = (nil, nil)
    ) -> (MemoryChannel, MemoryChannel) {
        let aToB = Mailbox(), bToA = Mailbox()
        return (
            MemoryChannel(remote: staticKeys.1, outbound: aToB, inbound: bToA),
            MemoryChannel(remote: staticKeys.0, outbound: bToA, inbound: aToB)
        )
    }

    private init(remote: AgreementPublicKey?, outbound: Mailbox, inbound: Mailbox) {
        remoteStaticKey = remote
        self.outbound = outbound
        self.inbound = inbound
    }

    public func send(_ message: [UInt8]) async throws {
        await outbound.put(message)
    }

    public func receive() async throws -> [UInt8]? {
        await inbound.take()
    }

    public func close() async {
        await outbound.close()
    }
}

/// A single-consumer FIFO of messages.
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
