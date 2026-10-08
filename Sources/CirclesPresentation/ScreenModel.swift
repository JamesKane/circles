public import Observation

/// The contract between the application and every UI (docs/DESIGN.md §11.6).
///
/// A screen model publishes an immutable `state` and changes only in
/// response to `send(_:)`. Backends render the state; imperative toolkits
/// diff old against new. Nothing here imports a UI framework, so this module
/// builds and is tested headless on every platform.
@MainActor
public protocol ScreenModel: AnyObject, Observable {
    associatedtype State: Sendable, Equatable
    associatedtype Intent: Sendable

    var state: State { get }

    /// Performs an intent and returns when its effects are reflected in
    /// `state`. Backends usually call `send`; tests await `perform`.
    func perform(_ intent: Intent) async
}

extension ScreenModel {
    /// Fire-and-forget form for UI event handlers.
    public func send(_ intent: Intent) {
        Task { await perform(intent) }
    }
}

/// What a screen is doing, for spinners and error banners.
public enum Phase: Sendable, Equatable {
    case idle
    case loading
    case syncing
    case failed(String)
}
