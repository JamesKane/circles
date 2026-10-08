import SwiftUI
import CirclesCore
import CirclesSync
import CirclesPresentation

/// The communities we own, belong to or are joining, each opening its page.
struct CommunitiesView: View {
    let session: AppModel.Session
    @State private var path: [UserID] = []
    @State private var creating = false
    @State private var joining = false

    private var model: CommunitiesScreenModel { session.communities }

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Communities")
                .navigationDestination(for: UserID.self) { community in
                    CommunityView(session: session, community: community)
                }
                .toolbar {
                    ToolbarItem {
                        Button("Join…", systemImage: "person.badge.plus") { joining = true }
                            .help("Join with an invite someone shared")
                            .accessibilityIdentifier("join-community")
                    }
                    ToolbarItem {
                        Button("New Community…", systemImage: "plus") { creating = true }
                            .accessibilityIdentifier("new-community")
                    }
                    ToolbarItem {
                        if model.state.phase == .syncing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.send(.sync) }
                        }
                    }
                }
        }
        .task { await model.perform(.load) }
        .onChange(of: session.network.state.newContentCount) { model.send(.load) }
        // A community just created or joined opens straight away.
        .onChange(of: model.state.opened) {
            if let opened = model.state.opened { path = [opened] }
        }
        .sheet(isPresented: $creating) { NewCommunitySheet(model: model) }
        .sheet(isPresented: $joining) { JoinCommunitySheet(model: model) }
    }

    @ViewBuilder private var list: some View {
        let state = model.state
        if state.communities.isEmpty, state.phase == .idle {
            ContentUnavailableView("No communities yet", systemImage: "person.3",
                                   description: Text("Create one, or join with an invite someone shared."))
        } else {
            List {
                if case .failed(let reason) = state.phase {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                ForEach(state.communities) { row in
                    NavigationLink(value: row.community) {
                        HStack(spacing: 10) {
                            AvatarView(name: row.name, initials: row.initials, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(.headline)
                                Text("\(row.detail) · \(row.memberCount) member\(row.memberCount == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !row.description.isEmpty {
                                    Text(row.description)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(row.pendingCount > 0 ? "\(row.roleLabel) · \(row.pendingCount) waiting" : row.roleLabel)
                                .font(.caption)
                                .foregroundStyle(row.pendingCount > 0 ? Style.color(.audienceLimited) : .secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("community-\(row.name)")
                }
            }
        }
    }
}

private struct NewCommunitySheet: View {
    let model: CommunitiesScreenModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var visibility: CommunityVisibility = .private
    @State private var policy: JoinPolicy = .approval

    var body: some View {
        Form {
            TextField("Name", text: $name)
                .accessibilityIdentifier("community-name")
            TextField("What it's about (optional)", text: $description)
            Picker("Visibility", selection: $visibility) {
                Text("Private: members only, encrypted").tag(CommunityVisibility.private)
                Text("Public: anyone can read").tag(CommunityVisibility.public)
            }
            Picker("Joining", selection: $policy) {
                Text(CommunityStrings.policy(.approval)).tag(JoinPolicy.approval)
                Text(CommunityStrings.policy(.open)).tag(JoinPolicy.open)
                Text(CommunityStrings.policy(.inviteOnly)).tag(JoinPolicy.inviteOnly)
            }
            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if visibility == .private { Text(CommunityStrings.privateHistory) }
                    Text("This Mac runs the community: keep Circles open, or add a pod, so members can reach it.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    model.send(.create(name: name, description: description, visibility: visibility, joinPolicy: policy))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("create-community")
            }
        }
    }
}

private struct JoinCommunitySheet: View {
    let model: CommunitiesScreenModel
    @Environment(\.dismiss) private var dismiss
    @State private var invite = ""

    var body: some View {
        Form {
            Section {
                TextField("Invite", text: $invite, prompt: Text("circles-community:…"))
                    .labelsHidden()
                    .accessibilityIdentifier("community-invite-field")
            } footer: {
                Text("Paste the invite text someone shared with you.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Ask to Join") {
                    model.send(.join(invite: invite.trimmingCharacters(in: .whitespacesAndNewlines)))
                    dismiss()
                }
                .disabled(!invite.trimmingCharacters(in: .whitespaces).hasPrefix("circles-community:"))
            }
        }
    }
}

/// One community: its posts, members and, for its owner, moderation.
struct CommunityView: View {
    let session: AppModel.Session
    @State private var model: CommunityScreenModel
    @State private var draft = ""
    @State private var commentingOn: PostCard?
    @State private var comment = ""
    @State private var removingPost: PostCard?
    @State private var removingComment: CommentRow?
    @State private var removingMember: CommunityScreenState.Member?

    init(session: AppModel.Session, community: UserID) {
        self.session = session
        _model = State(initialValue: CommunityScreenModel(account: session.account, community: community, services: MacServices()))
    }

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(state)
                if !state.requests.isEmpty { requests(state) }
                if state.canPost { composer }
                posts(state)
                members(state)
            }
            .frame(maxWidth: 640)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(state.header?.name ?? "Community")
        .toolbar {
            ToolbarItem {
                Button("Invite", systemImage: "envelope") { model.send(.makeInvite) }
                    .help("Copy invite text to share")
                    .accessibilityIdentifier("community-invite")
            }
            ToolbarItem {
                if state.phase == .syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { model.send(.sync) }
                }
            }
        }
        .task { await model.perform(.refresh) }
        // Like the Stream, the community refreshes when any sync brings news.
        .onChange(of: session.network.state.newContentCount) { model.send(.refresh) }
        .alert("Comment on \(commentingOn?.authorName ?? "")'s post", isPresented: Binding(get: { commentingOn != nil }, set: { if !$0 { commentingOn = nil } }),
               presenting: commentingOn) { card in
            TextField("Your comment", text: $comment)
            Button("Comment") {
                model.send(.comment(on: card.reference, comment))
                comment = ""
            }
            Button("Cancel", role: .cancel) { comment = "" }
        }
        .confirmationDialog("Remove \(removingPost?.authorName ?? "")'s post?", isPresented: Binding(get: { removingPost != nil }, set: { if !$0 { removingPost = nil } }),
                            presenting: removingPost) { card in
            Button("Remove Post", role: .destructive) { model.send(.removeItem(card.id)) }
        } message: { _ in
            Text("It disappears from the community for everyone once they sync.")
        }
        .confirmationDialog("Remove \(removingComment?.authorName ?? "")'s comment?", isPresented: Binding(get: { removingComment != nil }, set: { if !$0 { removingComment = nil } }),
                            presenting: removingComment) { comment in
            Button("Remove Comment", role: .destructive) { model.send(.removeItem(comment.id)) }
        } message: { _ in
            Text("It disappears from the community for everyone once they sync.")
        }
        .confirmationDialog("Remove \(removingMember?.name ?? "")?", isPresented: Binding(get: { removingMember != nil }, set: { if !$0 { removingMember = nil } }),
                            presenting: removingMember) { member in
            Button("Remove", role: .destructive) { model.send(.removeMember(member.user)) }
        } message: { _ in
            Text("They stop receiving the community's posts. In a private community, they can't read anything posted afterwards.")
        }
    }

    @ViewBuilder private func header(_ state: CommunityScreenState) -> some View {
        if let header = state.header {
            VStack(alignment: .leading, spacing: 4) {
                if !header.description.isEmpty { Text(header.description) }
                Text("\(header.detail) · \(header.roleLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let notice = state.notice {
            Label(notice, systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
        if state.invite != nil {
            Label("Invite copied. Paste it to someone you'd like to join; they use Join… on their Communities page.",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
        if case .failed(let reason) = state.phase {
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func requests(_ state: CommunityScreenState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Waiting to join").font(.title3.bold())
            ForEach(state.requests) { request in
                HStack(spacing: 10) {
                    AvatarView(name: request.name, initials: request.initials, size: 30)
                    Text(request.name)
                    Spacer()
                    Button("Turn Down") { model.send(.reject(request.user)) }
                    Button("Let In") { model.send(.approve(request.user)) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("let-in-\(request.name)")
                }
                .padding(10)
                .background(.background, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Share something with the community…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .onSubmit(post)
                .accessibilityIdentifier("community-composer")
            Button("Post", action: post)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func post() {
        model.send(.post(draft))
        draft = ""
    }

    @ViewBuilder private func posts(_ state: CommunityScreenState) -> some View {
        if state.cards.isEmpty, state.phase == .idle, state.canPost {
            Text("No posts yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        ForEach(state.cards) { card in
            PostCardView(card: card, media: session.media, generation: session.network.state.newContentCount,
                         showThread: true,
                         onPlusOne: { model.send(.setPlusOne(card.reference, !card.plusOnedByMe)) },
                         onOpen: { commentingOn = card },
                         onRemoveComment: { removingComment = $0 },
                         onDelete: { removingPost = card }, deleteLabel: "Remove Post…")
                .contextMenu {
                    if card.canDelete {
                        Button("Remove Post…", role: .destructive) { removingPost = card }
                    }
                }
        }
    }

    private func members(_ state: CommunityScreenState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Members").font(.title3.bold())
            ForEach(state.members) { member in
                HStack(spacing: 10) {
                    AvatarView(name: member.name, initials: member.initials, size: 30)
                    Text(member.name + (member.isOwner ? " (owner)" : ""))
                    Spacer()
                    if state.isOwner && !member.isOwner {
                        Button("Remove…", role: .destructive) { removingMember = member }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
