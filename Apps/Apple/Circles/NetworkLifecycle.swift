import AppKit
import Network
import CirclesPresentation

/// Keeps the node's network service in step with the Mac:
/// - stops it before sleep, so the mDNS goodbye and port-mapping removal go
///   out, and starts it again on wake (which also syncs straight away);
/// - restarts it when the network changes (another Wi-Fi network, a cable, a
///   VPN), since the mDNS responder advertises the addresses it found at
///   start;
/// - holds an activity that keeps App Nap from throttling sync timers and
///   incoming syncs while the window is hidden, still letting the Mac sleep
///   when idle.
final class NetworkLifecycle {
    private let network: NetworkModel
    private var activity: (any NSObjectProtocol)?
    private var observers: [any NSObjectProtocol] = []
    private var monitor: NWPathMonitor?
    private var lastPath: PathSummary?
    private var pendingRestart: Task<Void, Never>?
    private(set) var asleep = false

    init(network: NetworkModel) {
        self.network = network
    }

    func start() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Staying online so your circles can sync with you")
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = PathSummary(path)
            Task { @MainActor in self?.pathChanged(summary) }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        monitor?.cancel()
        monitor = nil
        pendingRestart?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func willSleep() {
        asleep = true
        pendingRestart?.cancel()
        Task { await network.perform(.stop) }
    }

    func didWake() {
        asleep = false
        Task { await network.perform(.start) }
    }

    /// Restarts after the network settles. The first update (on start) is
    /// only a baseline; updates while asleep are left to the wake.
    private func pathChanged(_ path: PathSummary) {
        defer { lastPath = path }
        guard let lastPath, path != lastPath, !asleep else { return }
        restartSoon()
    }

    func restartSoon() {
        pendingRestart?.cancel()
        pendingRestart = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !asleep else { return }
            await network.perform(.stop)
            await network.perform(.start)
        }
    }

    /// What about the path matters to us: whether it's usable, over which
    /// interfaces, and through which gateways (joining another Wi-Fi network
    /// keeps the interface but changes the gateway).
    nonisolated struct PathSummary: Equatable, Sendable {
        var satisfied: Bool
        var interfaces: [String]
        var gateways: [String]

        init(_ path: NWPath) {
            satisfied = path.status == .satisfied
            interfaces = path.availableInterfaces.map(\.name).sorted()
            gateways = path.gateways.map { "\($0)" }.sorted()
        }
    }
}
