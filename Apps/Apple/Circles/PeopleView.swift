import SwiftUI
import CirclesCore
import CirclesPresentation

/// Adding people by exchanging invites, and managing contacts.
struct PeopleView: View {
    let model: PeopleScreenModel
    @State private var inviteDraft = ""
    @State private var renaming: PeopleState.Person?
    @State private var newName = ""
    @State private var removing: PeopleState.Person?

    var body: some View {
        let state = model.state
        Form {
            Section {
                Text(state.myInvite.isEmpty ? "…" : state.myInvite)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Button("Copy My Invite", systemImage: "doc.on.doc") { model.send(.copyMyInvite) }
                    .accessibilityIdentifier("copy-my-invite")
            } header: {
                Text("Your invite")
            } footer: {
                Text("Send this to someone so they can add you. You both need each other's invite before you can sync.")
            }

            Section("Add someone") {
                HStack {
                    TextField("Paste their invite", text: $inviteDraft, prompt: Text("Paste their invite"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.send(.addContact) }
                        .accessibilityIdentifier("invite-field")
                    Button("Add") { model.send(.addContact) }
                        .accessibilityIdentifier("add-contact")
                        .disabled(!state.canAdd)
                }
                if let notice = state.notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
                if case .failed(let reason) = state.phase {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section("People") {
                if state.people.isEmpty {
                    Text("No one yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.people) { person in
                    HStack(spacing: 10) {
                        AvatarView(name: person.name, initials: person.initials, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                            Text(person.circles.isEmpty ? "Not in any of your circles" : person.circles.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Actions", systemImage: "ellipsis.circle") { actions(for: person) }
                            .labelStyle(.iconOnly)
                            .menuIndicator(.hidden)
                            .fixedSize()
                    }
                    .contextMenu { actions(for: person) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("People")
        .task { await model.perform(.load) }
        .onChange(of: inviteDraft) { model.send(.editInvite(inviteDraft)) }
        .onChange(of: model.state.inviteDraft) {
            if model.state.inviteDraft != inviteDraft { inviteDraft = model.state.inviteDraft }
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { person in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.send(.rename(person.user, to: name)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This name is only on your devices. They never see it.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { person in
            Button("Remove", role: .destructive) { model.send(.remove(person.user)) }
        } message: { _ in
            Text("They're taken out of all your circles and can't see anything you post from now on.")
        }
    }

    @ViewBuilder private func actions(for person: PeopleState.Person) -> some View {
        Button("Rename…") {
            newName = person.name
            renaming = person
        }
        Button("Remove…", role: .destructive) { removing = person }
    }
}
