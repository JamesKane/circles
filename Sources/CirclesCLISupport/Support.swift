public import Foundation
import CirclesCore
public import CirclesSync
public import CirclesKit

/// Writes a line immediately, even when stdout is redirected to a file, so
/// a long-running daemon's log is never lost in a buffer.
public func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Runs `work` until it finishes or the process gets SIGINT/SIGTERM, which
/// cancel it so cleanup (mDNS goodbye, removing port mappings) still runs.
public func runUntilInterrupted(_ work: @escaping @Sendable () async throws -> Void) async throws {
    let task = Task { try await work() }
    #if !os(Windows)
    let signals = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { task.cancel() }
        source.resume()
        return source
    }
    defer { signals.forEach { $0.cancel() } }
    #endif
    if case .failure(let error) = await task.result, !(error is CancellationError) {
        throw error
    }
    say("Stopped.")
}

/// Expands `~` and makes a file URL.
public func directoryURL(_ path: String?, environment: String, default name: String) -> URL {
    if let path { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
    if let env = ProcessInfo.processInfo.environment[environment] { return URL(fileURLWithPath: env) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
}

public func describe(_ report: SyncReport, peerName: String, direction: String) -> String {
    let received = report.received.values.reduce(0, +)
    return "Synced with \(peerName) (\(direction)): received \(received), sent \(report.sent)"
        + (report.rejected.isEmpty ? "" : ", rejected \(report.rejected.count)")
}

public func printAttempts(_ attempts: [Account.SyncAttempt], account: Account) async {
    if attempts.isEmpty { say("No peers, pods or relays to sync with.") }
    for attempt in attempts {
        switch attempt.result {
        case .success(let report):
            let name = report.peer.map { _ in attempt.route } ?? attempt.route
            say(describe(report, peerName: name, direction: "outgoing"))
        case .failure(let error):
            say("Could not sync with \(attempt.route): \(error)")
        }
    }
}
