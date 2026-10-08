import SwiftUI
import CirclesPresentation

/// A new post, as a sheet over the Stream.
struct ComposerView: View {
    @State private var model: ComposerScreenModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    let onPosted: () -> Void

    init(session: AppModel.Session, onPosted: @escaping () -> Void) {
        _model = State(initialValue: ComposerScreenModel(account: session.account, services: MacServices()))
        self.onPosted = onPosted
    }

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .accessibilityIdentifier("composer-text")
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if text.isEmpty {
                    Text("What's new?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 140)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            audience

            if !state.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.attachments) { attachment in
                        HStack {
                            Label("\(attachment.mediaType) · \(attachment.sizeLabel)", systemImage: "photo")
                            Spacer()
                            Button("Remove", systemImage: "xmark.circle.fill") {
                                model.send(.removeAttachment(id: attachment.id))
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
            Button("Add Photo…", systemImage: "photo.badge.plus") { model.send(.pickImage) }

            HStack(spacing: 20) {
                Toggle("Allow comments", isOn: Binding(get: { model.state.allowComments },
                                                       set: { model.send(.setAllowComments($0)) }))
                Toggle("Allow resharing", isOn: Binding(get: { model.state.allowResharing },
                                                        set: { model.send(.setAllowResharing($0)) }))
            }
            .toggleStyle(.checkbox)

            if case .failed(let reason) = state.status {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if state.status == .posting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Post") { model.send(.post) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("composer-post")
                        .disabled(!state.canPost)
                }
            }
        }
        .navigationTitle("New Post")
        .task { await model.perform(.load) }
        .onChange(of: text) { model.send(.editText(text)) }
        .onChange(of: model.state.status) {
            if model.state.status == .posted {
                onPosted()
                dismiss()
            }
        }
    }

    /// Public, or any of your circles. An empty choice says so rather than
    /// reading as public (Strings.audience).
    private var audience: some View {
        let state = model.state
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { model.state.shareWithEveryone },
                                     set: { model.send(.setShareWithEveryone($0)) })) {
                    Label("Public", systemImage: "globe")
                }
                .accessibilityIdentifier("audience-public")
                ForEach(state.circles, id: \.self) { name in
                    Toggle(isOn: Binding(get: { model.state.selectedCircles.contains(name) },
                                         set: { _ in model.send(.toggleCircle(name)) })) {
                        Label(name, systemImage: "circle.dashed")
                    }
                }
            }
            .toggleStyle(.button)
            Text(state.audienceSummary)
                .font(.caption)
                .foregroundStyle(state.shareWithEveryone ? Style.color(.audiencePublic)
                                 : state.selectedCircles.isEmpty ? Color.secondary : Style.color(.audienceLimited))
        }
    }
}
