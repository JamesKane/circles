import CGtk
import GtkKit

/// The main-actor integration spike (docs/DESIGN.md §11.6): a @MainActor task
/// updates a GTK label ten times while GTK's main loop owns the main thread,
/// checking each update runs on the main thread. Exits 0 on success.
@main
enum Spike {
    static func main() {
        MainLoop.integrateSwiftMainActor()
        let app = adw_application_new("dev.circles.MainActorSpike", GApplicationFlags(rawValue: 1 << 5))! // G_APPLICATION_NON_UNIQUE
        connect(app, "activate") {
            let window = adw_application_window_new(cast(app, to: GtkApplication.self))!
            let label = gtk_label_new("waiting for the main actor…")!
            adw_application_window_set_content(cast(window, to: AdwApplicationWindow.self), label)
            gtk_window_present(cast(window, to: GtkWindow.self))
            Task { @MainActor in
                var ok = true
                for tick in 1...10 {
                    try? await Task.sleep(for: .milliseconds(50))
                    ok = ok && MainLoop.isMainThread
                    gtk_label_set_text(OpaquePointer(label), "tick \(tick)") // GtkLabel is opaque in GTK 4
                }
                print(ok ? "main actor ran 10 times on the GTK main thread" : "FAILED: main actor ran off the main thread")
                // Optional idle period, to check the integration doesn't spin.
                if let idle = getenv("CIRCLES_SPIKE_IDLE").flatMap({ Int(String(cString: $0)) }) {
                    try? await Task.sleep(for: .seconds(idle))
                }
                if !ok { exitCode = 1 }
                g_application_quit(cast(app, to: GApplication.self))
            }
        }
        let status = g_application_run(cast(app, to: GApplication.self), 0, nil)
        exit(status != 0 ? status : exitCode)
    }

    nonisolated(unsafe) static var exitCode: Int32 = 0
}

#if canImport(Glibc)
import Glibc
#endif
