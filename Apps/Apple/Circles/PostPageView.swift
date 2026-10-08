import SwiftUI
import CirclesCore
import CirclesPresentation

/// Where the Stream navigates: a post, optionally straight to resharing it.
struct PostRoute: Hashable {
    let post: ObjectRef
    var reshare = false
}

/// One post with its thread, a comment box, and resharing.
struct PostPageView: View {
    let session: AppModel.Session
    @State private var model: PostScreenModel
    @State private var draft = ""
    @State private var confirmingReshare: Bool
    @State private var reshareComment = ""
    @State private var notice: String?
    @State private var confirmingDelete = false
    @State private var removingComment: CommentRow?
    @FocusState private var commentFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(route: PostRoute, session: AppModel.Session) {
        self.session = session
        _model = State(initialValue: PostScreenModel(post: route.post, account: session.account))
        _confirmingReshare = State(initialValue: route.reshare)
    }

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                if case .failed(let reason) = state.phase {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if let card = state.card {
                    PostCardView(card: card, media: session.media, generation: session.network.state.newContentCount,
                                 showThread: true,
                                 onPlusOne: { model.send(.togglePlusOne) },
                                 onOpen: { commentFocused = true },
                                 onReshare: { confirmingReshare = true },
                                 onRemoveComment: { removingComment = $0 })
                } else if state.phase == .idle || state.phase == .loading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 640)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .navigationTitle(state.card.map { "\($0.authorName)'s post" } ?? "Post")
        .toolbar {
            if state.card?.canDelete == true {
                ToolbarItem {
                    Button("Delete Post", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .help("Delete this post")
                }
            }
        }
        .onChange(of: model.state.deleted) { if model.state.deleted { dismiss() } }
        .confirmationDialog("Delete this post?", isPresented: $confirmingDelete) {
            Button("Delete Post", role: .destructive) { model.send(.delete) }
        } message: {
            Text("It's removed for everyone, along with its comments and +1s, as they sync.")
        }
        .confirmationDialog("Remove this comment?", isPresented: Binding(get: { removingComment != nil }, set: { if !$0 { removingComment = nil } }),
                            presenting: removingComment) { comment in
            Button("Remove Comment", role: .destructive) { model.send(.removeComment(comment.id)) }
        } message: { comment in
            Text("\(comment.authorName)'s comment is taken out of your post's thread for everyone.")
        }
        .task { await model.perform(.load) }
        // Comments and +1s from a sync show up while the page is open.
        .onChange(of: session.network.state.newContentCount) { model.send(.load) }
        .onChange(of: draft) { model.send(.editDraft(draft)) }
        .onChange(of: model.state.draft) {
            if model.state.draft != draft { draft = model.state.draft }
        }
        // +1s, comments and reshares made here change the Stream too.
        .onDisappear { session.stream.send(.refresh) }
        .alert("Reshare publicly?", isPresented: $confirmingReshare) {
            TextField("Add a comment (optional)", text: $reshareComment)
            Button("Reshare") { reshare() }
            Button("Cancel", role: .cancel) { reshareComment = "" }
        } message: {
            Text("Everyone will be able to see your reshare.")
        }
    }

    private var composer: some View {
        let canComment = model.state.card?.canComment ?? false
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(canComment ? "Add a comment…" : "Comments are turned off", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($commentFocused)
                .onSubmit { model.send(.submitComment) }
            Button("Comment") { model.send(.submitComment) }
                .disabled(!model.state.canSubmitComment)
        }
        .disabled(!canComment)
        .frame(maxWidth: 640)
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func reshare() {
        let comment = reshareComment.trimmingCharacters(in: .whitespacesAndNewlines)
        reshareComment = ""
        Task {
            await model.perform(.reshare(comment: comment))
            if case .failed = model.state.phase { return }
            notice = "Reshared to everyone."
        }
    }
}
