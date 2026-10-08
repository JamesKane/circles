import Observation

/// Runs `render` now, and again (on the main actor) whenever any observable
/// property it read changes. This is how a GTK backend follows a screen
/// model's `state` (docs/DESIGN.md §11.6). It stops once `isAlive` is false,
/// e.g. after the view is closed.
@MainActor
public func observe(while isAlive: @escaping @MainActor () -> Bool = { true }, _ render: @escaping @MainActor () -> Void) {
    guard isAlive() else { return }
    withObservationTracking {
        render()
    } onChange: {
        // Called before the change lands, possibly off the main actor:
        // re-render on the next main-actor turn, after it has.
        Task { @MainActor in observe(while: isAlive, render) }
    }
}
