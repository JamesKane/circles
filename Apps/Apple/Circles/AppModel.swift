import Foundation
import Observation
import CirclesCore
import CirclesKit
import CirclesPresentation

/// Opens or creates the account and keeps the device online, like the GNOME
/// app's AppController.
@Observable
final class AppModel {
    enum Phase {
        case loading
        case onboarding(OnboardingScreenModel)
        case ready(Session)
        case failed(String)
    }

    /// The models that live as long as the open account.
    struct Session {
        let account: Account
        let network: NetworkModel
        let stream: StreamScreenModel
        let people: PeopleScreenModel
        let circles: CirclesScreenModel
        let settings: SettingsScreenModel
        let media: MediaLoader
        /// Sleep, wake, network changes and App Nap.
        let lifecycle: NetworkLifecycle
    }

    private(set) var phase: Phase = .loading
    /// A post to show, e.g. from a clicked notification. The main window
    /// opens it and clears this.
    var postToOpen: ObjectRef?
    let home: URL

    init(home: URL = AppModel.defaultHome()) {
        self.home = home
    }

    /// Application Support (inside the sandbox container), or $CIRCLES_HOME,
    /// which must also be inside the container. With CIRCLES_FRESH_HOME=1
    /// (UI tests), a new empty directory each launch, so the app starts at
    /// onboarding.
    static func defaultHome() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["CIRCLES_FRESH_HOME"] == "1" {
            return URL.temporaryDirectory.appending(path: "circles-fresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        }
        if let path = environment["CIRCLES_HOME"] {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Circles", directoryHint: .isDirectory)
    }

    var session: Session? {
        if case .ready(let session) = phase { session } else { nil }
    }

    var network: NetworkModel? { session?.network }

    func launch() async {
        guard case .loading = phase else { return }
        guard Account.exists(home: home) else {
            phase = .onboarding(OnboardingScreenModel(home: home))
            return
        }
        do {
            start(try await Account.open(home: home))
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Shows the main UI and goes online.
    func start(_ account: Account) {
        if case .ready = phase { return }
        let services = MacServices()
        let network = NetworkModel(account: account)
        let session = Session(account: account, network: network,
                              stream: StreamScreenModel(account: account),
                              people: PeopleScreenModel(account: account, services: services),
                              circles: CirclesScreenModel(account: account),
                              settings: SettingsScreenModel(account: account, services: services),
                              media: MediaLoader(account: account),
                              lifecycle: NetworkLifecycle(network: network))
        phase = .ready(session)
        session.network.send(.start)
        session.lifecycle.start()
    }

    /// Stops the network, giving up after a few seconds so quitting can't hang.
    func shutdown() async {
        guard let session else { return }
        session.lifecycle.stop()
        let network = session.network
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await network.perform(.stop) }
            group.addTask { try? await Task.sleep(for: .seconds(3)) }
            await group.next()
            group.cancelAll()
        }
    }
}
