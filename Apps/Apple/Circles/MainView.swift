import AppKit
import SwiftUI
import CirclesPresentation

/// The main window: a sidebar of sections, with the network status line
/// under each.
struct MainView: View {
    enum Section: Hashable {
        case stream, people, circles, communities
    }

    let app: AppModel
    let session: AppModel.Session
    @State private var section: Section? = .stream
    @State private var streamPath: [PostRoute] = []

    private var network: NetworkModel { session.network }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("Stream", systemImage: "rectangle.stack").tag(Section.stream).accessibilityIdentifier("sidebar-stream")
                Label("People", systemImage: "person.2").tag(Section.people).accessibilityIdentifier("sidebar-people")
                Label("Circles", systemImage: "circle.circle").tag(Section.circles).accessibilityIdentifier("sidebar-circles")
                Label("Communities", systemImage: "person.3").tag(Section.communities).accessibilityIdentifier("sidebar-communities")
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            Group {
                switch section ?? .stream {
                case .stream: StreamView(session: session, path: $streamPath)
                case .people: PeopleView(model: session.people)
                case .circles: CirclesView(model: session.circles)
                case .communities: CommunitiesView(session: session)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(network: network) }
        }
        .task { await session.stream.perform(.refresh) }
        // New content from any sync refreshes the Stream, whichever section
        // is showing: that also approves comments on our posts and finds
        // what to notify about.
        .onChange(of: network.state.newContentCount) { session.stream.send(.refresh) }
        .onChange(of: session.stream.state.arrivalGeneration) {
            Notifier.notify(session.stream.state.arrivals, appIsActive: NSApp.isActive)
        }
        .onChange(of: app.postToOpen, initial: true) {
            guard let post = app.postToOpen else { return }
            app.postToOpen = nil
            section = .stream
            streamPath = [PostRoute(post: post)]
        }
    }
}

/// "Online · port 41234 · synced 2 min", with the activity log in a popover.
struct StatusBar: View {
    let network: NetworkModel
    @State private var showingActivity = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack {
                Text(network.state.summary(now: context.date))
                    .accessibilityIdentifier("network-status")
                Spacer()
                Button("Activity", systemImage: "list.bullet.rectangle") { showingActivity.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Network activity")
                    .popover(isPresented: $showingActivity, arrowEdge: .top) {
                        ActivityList(network: network)
                            .frame(width: 460, height: 280)
                    }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct ActivityList: View {
    let network: NetworkModel

    var body: some View {
        if network.state.activity.isEmpty {
            Text("No network activity yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(Array(network.state.activity.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}
