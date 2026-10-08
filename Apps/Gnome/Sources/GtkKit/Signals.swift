import CGtk

/// Holds a Swift closure for the lifetime of a GObject signal connection.
/// `@unchecked Sendable` because GTK emits signals only on the main thread,
/// so the closure is only ever called there (and asserted to be, below).
private final class SignalHandler: @unchecked Sendable {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
}

/// Connects `signal` on `instance` to a closure. For signals whose C handler
/// takes only the instance and user data, e.g. "clicked", "activate", "notify".
/// GTK emits signals on the main thread, so the closure runs on the main actor.
@discardableResult
public func connect(_ instance: some GPointerConvertible, _ signal: String, _ action: @escaping @MainActor () -> Void) -> UInt {
    // "notify::x" handlers take (object, GParamSpec*, user_data); using this
    // two-argument form would read the GParamSpec as user data and crash.
    precondition(!signal.hasPrefix("notify"), "use onNotify(_:property:_:) for \(signal)")
    let handler = Unmanaged.passRetained(SignalHandler(action)).toOpaque()
    let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
        let handler = Unmanaged<SignalHandler>.fromOpaque(data!).takeUnretainedValue()
        MainActor.assumeIsolated { handler.action() }
    }
    return g_signal_connect_data(
        instance.gpointer, signal, unsafeBitCast(trampoline, to: GCallback.self), handler,
        { data, _ in Unmanaged<SignalHandler>.fromOpaque(data!).release() }, GConnectFlags(rawValue: 0)
    )
}

/// Anything that is a GObject pointer of some type.
public protocol GPointerConvertible {
    var gpointer: UnsafeMutableRawPointer { get }
}

extension UnsafeMutablePointer: GPointerConvertible {
    public var gpointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

extension OpaquePointer: GPointerConvertible {
    public var gpointer: UnsafeMutableRawPointer { UnsafeMutableRawPointer(self) }
}

/// Casts between GObject pointer types, standing in for C macros such as
/// `GTK_WIDGET(x)` that Swift can't import. Only for pointers that really are
/// instances of the target type (or a subclass).
@inlinable
public func cast<T>(_ pointer: some GPointerConvertible, to: T.Type = T.self) -> UnsafeMutablePointer<T> {
    pointer.gpointer.assumingMemoryBound(to: T.self)
}

/// Holds a closure taking the signal's first argument.
private final class SignalHandler1: @unchecked Sendable {
    let action: @MainActor (UnsafeMutableRawPointer?) -> Void
    init(_ action: @escaping @MainActor (UnsafeMutableRawPointer?) -> Void) { self.action = action }
}

/// Connects a signal whose C handler is `(instance, argument, user_data)`,
/// e.g. GtkListBox "row-activated" or GtkFileDialog callbacks' cousins.
@discardableResult
public func connect(_ instance: some GPointerConvertible, _ signal: String, _ action: @escaping @MainActor (UnsafeMutableRawPointer?) -> Void) -> UInt {
    let handler = Unmanaged.passRetained(SignalHandler1(action)).toOpaque()
    let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, argument, data in
        let handler = Unmanaged<SignalHandler1>.fromOpaque(data!).takeUnretainedValue()
        nonisolated(unsafe) let argument = argument // a GObject pointer, only used on the main thread
        MainActor.assumeIsolated { handler.action(argument) }
    }
    return g_signal_connect_data(
        instance.gpointer, signal, unsafeBitCast(trampoline, to: GCallback.self), handler,
        { data, _ in Unmanaged<SignalHandler1>.fromOpaque(data!).release() }, GConnectFlags(rawValue: 0)
    )
}

// MARK: - Passing GObject pointers to C

/// Converts a GObject pointer to whatever pointer type the C function at the
/// call site expects, inferred from context: a typed pointer for types Swift
/// knows the layout of, `OpaquePointer` for types GTK 4 keeps opaque, or a
/// raw `gpointer`. Stands in for C cast macros like `GTK_LABEL(x)`; only
/// valid when the object really is (a subclass of) the expected type.
@inlinable
public func g<T>(_ pointer: some GPointerConvertible) -> UnsafeMutablePointer<T> {
    pointer.gpointer.assumingMemoryBound(to: T.self)
}

@inlinable
public func g(_ pointer: some GPointerConvertible) -> OpaquePointer {
    OpaquePointer(pointer.gpointer)
}

@inlinable
public func g(_ pointer: some GPointerConvertible) -> UnsafeMutableRawPointer {
    pointer.gpointer
}

/// Runs `action` whenever a GObject property changes ("notify::property").
@discardableResult
public func onNotify(_ instance: some GPointerConvertible, property: String, _ action: @escaping @MainActor () -> Void) -> UInt {
    connect(instance, "notify::" + property) { (_: UnsafeMutableRawPointer?) in action() }
}
