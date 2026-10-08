import CGtk
import Dispatch // links libdispatch, whose hooks are declared below
#if canImport(Glibc)
import Glibc
#endif

// libdispatch's hooks for driving the main queue from another event loop;
// CoreFoundation's run loop uses them the same way on Linux.
@_silgen_name("_dispatch_get_main_queue_handle_4CF")
private func dispatchMainQueueHandle() -> Int32

@_silgen_name("_dispatch_main_queue_callback_4CF")
private func dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)

/// Joins Swift's main actor to GTK's main loop (docs/DESIGN.md §11.6,
/// "Main-thread integration").
///
/// On Linux, `@MainActor` work is queued on libdispatch's main queue, which
/// nothing drains while `g_application_run` owns the main thread. This adds a
/// GLib source that wakes when the main queue has work (libdispatch signals
/// an eventfd) and drains it, on the main thread, between GTK events.
public enum MainLoop {
    private nonisolated(unsafe) static var installed = false
    private nonisolated(unsafe) static var mainThread = pthread_self()

    /// Call once, on the main thread, before running the application.
    public static func integrateSwiftMainActor() {
        guard !installed else { return }
        installed = true
        mainThread = pthread_self()
        let fd = dispatchMainQueueHandle()
        _ = g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
            // Reset the eventfd (it's non-blocking) so the source doesn't
            // fire again until new work arrives, then run what's queued.
            var counter: UInt64 = 0
            _ = read(fd, &counter, MemoryLayout<UInt64>.size)
            dispatchMainQueueCallback(nil)
            return gboolean(1) // G_SOURCE_CONTINUE
        }, nil)
    }

    /// Whether the caller is on the thread that called
    /// `integrateSwiftMainActor`, i.e. the main thread, where GTK lives.
    public static var isMainThread: Bool {
        pthread_equal(pthread_self(), mainThread) != 0
    }
}
