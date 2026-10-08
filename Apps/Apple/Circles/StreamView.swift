import SwiftUI
import CirclesPresentation

/// The Stream: posts from your circles, newest first, with a circle filter.
struct StreamView: View {
    let session: AppModel.Session
    @State private var showingActivity = false

    private var stream: StreamScreenModel { session.stream }
    private var network: NetworkModel { session.network }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Stream")
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        }
        .task { await stream.perform(.refresh) }
        // New content from any sync, incoming or outgoing, refreshes the Stream.
        .onChange(of: network.state.newContentCount) { stream.send(.refresh) }
    }

    @ViewBuilder private var content: some View {
        let state = stream.state
        if state.cards.isEmpty {
            switch state.phase {
            case .loading, .syncing:
                ProgressView(phaseText(state.phase) ?? "")
            case .failed(let reason):
                ContentUnavailableView("Couldn't load the Stream", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
            case .idle:
                ContentUnavailableView("Nothing here yet", systemImage: "circle.dashed",
                                       description: Text("Post something, or sync with your circles."))
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if case .failed(let reason) = state.phase {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(state.cards) { card in
                        PostCardView(card: card, media: session.media, generation: network.state.newContentCount) {
                            stream.send(.setPlusOne(card.reference, !card.plusOnedByMe))
                        }
                    }
                }
                .frame(maxWidth: 640)
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Show", selection: Binding(get: { stream.state.filter },
                                              set: { stream.send(.selectFilter($0)) })) {
                ForEach(stream.state.availableFilters, id: \.self) { filter in
                    switch filter {
                    case .everything: Text("Everything")
                    case .circle(let name): Text(name)
                    }
                }
            }
            .pickerStyle(.menu)
            .help("Show posts from one of your circles")
        }
        ToolbarItem {
            if network.state.syncing || stream.state.phase == .syncing {
                ProgressView().controlSize(.small)
            } else {
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        await network.perform(.syncNow)
                        await stream.perform(.refresh)
                    }
                }
                .keyboardShortcut("r")
            }
        }
    }

    private var statusBar: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack {
                Text(network.state.summary(now: context.date))
                Spacer()
                Button("Activity", systemImage: "list.bullet.rectangle") { showingActivity.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Network activity")
                    .popover(isPresented: $showingActivity, arrowEdge: .top) { activity }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var activity: some View {
        Group {
            if network.state.activity.isEmpty {
                Text("No network activity yet.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(Array(network.state.activity.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .frame(width: 460, height: 280)
    }
}
