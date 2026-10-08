import Foundation
import CirclesCrypto
public import Observation
public import CirclesKit
import CirclesCore
import CirclesDHT

public struct NetworkState: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case offline
        case starting
        case online(port: Int)
        case failed(String)
    }

    public var status: Status = .offline
    public var preferences = NodePreferences()
    /// Relay address → whether we currently hold a reservation there.
    public var relays: [String: Bool] = [:]
    public var portMapping: String?
    public var syncing = false
    public var lastSync: Date?
    /// Newest first, at most 50 lines.
    public var activity: [String] = []
    /// Goes up whenever a sync brought new content. UIs refresh their
    /// Stream when it changes.
    public var newContentCount = 0
    /// DHT nodes known at the last refresh; nil before one.
    public var dhtNodes: Int?
    public var bootstrapDraft = ""
    /// Why the last bootstrap node couldn't be added.
    public var bootstrapError: String?

    /// A configured DHT bootstrap node: its `circles-dht-node:…` text and
    /// where it is.
    public struct BootstrapNode: Sendable, Equatable, Identifiable {
        public var text: String
        public var address: String
        public var id: String { text }
    }

    public var bootstrapNodes: [BootstrapNode] {
        preferences.dhtBootstrap.compactMap { text in
            (try? DHTNodeText.contact(from: text)).map { BootstrapNode(text: text, address: "\($0.host):\($0.port)") }
        }
    }

    /// One line for a status bar, e.g. "Online · port 41234 · 1 relay".
    public func summary(now: Date = Date()) -> String {
        switch status {
        case .offline: return "Offline"
        case .starting: return "Connecting…"
        case .failed(let reason): return "Offline: \(reason)"
        case .online(let port):
            var parts = ["Online", "port \(port)"]
            let reachable = relays.values.filter { $0 }.count
            if reachable > 0 { parts.append("\(reachable) relay\(reachable == 1 ? "" : "s")") }
            if let portMapping { parts.append("public \(portMapping)") }
            if let dhtNodes, dhtNodes > 0 { parts.append("DHT \(dhtNodes)") }
            if syncing {
                parts.append("syncing…")
            } else if let lastSync {
                let millis = UInt64(max(0, lastSync.timeIntervalSince1970) * 1000)
                parts.append("synced " + Format.relativeTime(HLCTimestamp(millis: millis), now: now))
            }
            return parts.joined(separator: " · ")
        }
    }
}

public enum NetworkIntent: Sendable {
    case start
    case stop
    case syncNow
    case setPreferences(NodePreferences)
    case editBootstrapNode(String)
    /// Adds the drafted `circles-dht-node:…` as a DHT bootstrap node.
    case addBootstrapNode
    case removeBootstrapNode(NetworkState.BootstrapNode)
}

/// Keeps the device online while the app runs (`NodeService`) and reports
/// what's happening.
@MainActor
@Observable
public final class NetworkModel: ScreenModel {
    public private(set) var state = NetworkState()
    private let account: Account
    private var service: Task<Void, Never>?

    public init(account: Account) {
        self.account = account
    }

    public func perform(_ intent: NetworkIntent) async {
        switch intent {
        case .start:
            await start()
        case .stop:
            await stop()
        case .syncNow:
            state.syncing = true
            await NodeService.syncRound(account: account) { event in
                await MainActor.run { self.apply(event) }
            }
        case .setPreferences(let preferences):
            await save(preferences)
        case .editBootstrapNode(let text):
            state.bootstrapDraft = text
            state.bootstrapError = nil
        case .addBootstrapNode:
            let text = state.bootstrapDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let contact = try? DHTNodeText.contact(from: text) else {
                state.bootstrapError = "That isn't a DHT node address (circles-dht-node:…)."
                return
            }
            var preferences = await savedPreferences()
            preferences.dhtBootstrap.removeAll { (try? DHTNodeText.contact(from: $0))?.key == contact.key }
            preferences.dhtBootstrap.append(text)
            state.bootstrapDraft = ""
            state.bootstrapError = nil
            await save(preferences)
        case .removeBootstrapNode(let node):
            var preferences = await savedPreferences()
            preferences.dhtBootstrap.removeAll { $0 == node.text }
            await save(preferences)
        }
    }

    /// The account's preferences; ours are only loaded once started.
    private func savedPreferences() async -> NodePreferences {
        (try? await account.preferences()) ?? state.preferences
    }

    /// Saves preferences and restarts the service, if running, to apply them.
    private func save(_ preferences: NodePreferences) async {
        do {
            try await account.setPreferences(preferences)
            state.preferences = preferences
            if service != nil {
                await stop()
                await start()
            }
        } catch {
            log("Couldn't save settings: \(error)")
        }
    }

    private func start() async {
        guard service == nil else { return }
        state.preferences = (try? await account.preferences()) ?? NodePreferences()
        state.status = .starting
        state.relays = Dictionary(uniqueKeysWithValues: await account.endpoints.relays.map { ("\($0.host):\($0.port)", false) })
        let preferences = state.preferences
        let account = self.account
        service = Task { [weak self] in
            do {
                try await NodeService(account: account).run(preferences) { event in
                    await MainActor.run { self?.apply(event) }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.state.status = .failed(String(describing: error)) }
            }
        }
    }

    /// Stops and waits, so goodbyes (mDNS, port mapping) go out first.
    private func stop() async {
        guard let service else { return }
        self.service = nil
        service.cancel()
        await service.value
        state.status = .offline
        state.portMapping = nil
        for key in state.relays.keys { state.relays[key] = false }
    }

    private func apply(_ event: NodeEvent) {
        switch event {
        case .listening(let port):
            state.status = .online(port: port)
            log("Listening on port \(port)")
        case .advertising:
            break
        case .advertisingUnavailable(let reason):
            log("Local network discovery unavailable: \(reason)")
        case .reachableViaRelay(let relay):
            state.relays[relay] = true
            log("Reachable through relay \(relay)")
        case .relayUnavailable(let relay, let reason):
            state.relays[relay] = false
            log("Relay \(relay) unavailable: \(reason)")
        case .portMapped(let external):
            state.portMapping = external
            log("Router forwards \(external)")
        case .portMappingRemoved:
            state.portMapping = nil
        case .portMappingUnavailable(let reason):
            log("Router port mapping unavailable: \(reason)")
        case .synced(let peer, let direction, let received, let sent):
            if received > 0 { state.newContentCount += 1 }
            state.lastSync = Date()
            log("Synced with \(peer) (\(direction.rawValue)): \(received) new, \(sent) sent")
        case .syncFailed(let route, let reason):
            log("Couldn't reach \(route): \(reason)")
        case .syncRoundFinished:
            state.syncing = false
        case .dhtRefreshed(let nodes, let stored):
            state.dhtNodes = nodes
            log("DHT: \(nodes) nodes known, identity stored on \(stored)")
        }
    }

    private func log(_ line: String) {
        state.activity.insert(line, at: 0)
        if state.activity.count > 50 { state.activity.removeLast(state.activity.count - 50) }
    }
}
