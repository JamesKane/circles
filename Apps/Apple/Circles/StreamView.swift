import SwiftUI
import CirclesPresentation

/// The Stream: posts from your circles, newest first, with a circle filter.
struct StreamView: View {
    let session: AppModel.Session
    /// Owned by the main window, so a notification can open a post.
    @Binding var path: [PostRoute]
    @State private var composing = false
    @State private var deleting: PostCard?

    private var stream: StreamScreenModel { session.stream }
    private var network: NetworkModel { session.network }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Stream")
                .toolbar { toolbar }
                .navigationDestination(for: PostRoute.self) { route in
                    PostPageView(route: route, session: session)
                }
        }
        .sheet(isPresented: $composing) {
            ComposerView(session: session) { stream.send(.refresh) }
        }
        .confirmationDialog("Delete this post?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { card in
            Button("Delete Post", role: .destructive) { stream.send(.delete(card.reference)) }
        } message: { _ in
            Text("It's removed for everyone, along with its comments and +1s, as they sync.")
        }
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
                        PostCardView(card: card, media: session.media, generation: network.state.newContentCount,
                                     onPlusOne: { stream.send(.setPlusOne(card.reference, !card.plusOnedByMe)) },
                                     onOpen: { path.append(PostRoute(post: card.reference)) },
                                     onReshare: { path.append(PostRoute(post: card.reference, reshare: true)) },
                                     onDelete: { deleting = card })
                            .contentShape(.rect)
                            .onTapGesture { path.append(PostRoute(post: card.reference)) }
                            .contextMenu {
                                Button("Open Post") { path.append(PostRoute(post: card.reference)) }
                                if card.canDelete {
                                    Divider()
                                    Button("Delete Post…", role: .destructive) { deleting = card }
                                }
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
            Button("New Post", systemImage: "square.and.pencil") { composing = true }
                .keyboardShortcut("n")
                .accessibilityIdentifier("new-post")
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
}
