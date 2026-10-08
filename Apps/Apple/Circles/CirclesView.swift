import SwiftUI
import CirclesCore
import CirclesPresentation

/// Organizing contacts into circles.
struct CirclesView: View {
    let model: CirclesScreenModel
    @State private var newCircle = ""

    var body: some View {
        let state = model.state
        Form {
            Section("Your circles") {
                if state.circles.isEmpty {
                    Text("No circles yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.circles) { circle in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(circle.name)
                        Text(circle.memberNames.isEmpty ? "Empty" : circle.memberNames.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    TextField("New circle name", text: $newCircle, prompt: Text("New circle name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(create)
                        .accessibilityIdentifier("new-circle-field")
                    Button("Create", action: create)
                        .disabled(newCircle.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("create-circle")
                }
            }

            Section {
                if state.contacts.isEmpty {
                    Text("Add people first, on the People page.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.contacts) { contact in
                    HStack(spacing: 10) {
                        AvatarView(name: contact.name, initials: contact.initials, size: 30)
                        Text(contact.name)
                        Spacer()
                        Menu(contact.circles.isEmpty ? "No circles" : contact.circles.joined(separator: ", ")) {
                            ForEach(state.circles) { circle in
                                Toggle(circle.name, isOn: Binding(
                                    get: { contact.circles.contains(circle.name) },
                                    set: { on in
                                        model.send(on ? .add(contact.user, toCircle: circle.name)
                                                      : .remove(contact.user, fromCircle: circle.name))
                                    }))
                            }
                        }
                        .fixedSize()
                        .disabled(state.circles.isEmpty)
                        .accessibilityIdentifier("circles-menu-\(contact.name)")
                    }
                }
            } header: {
                Text("People")
            } footer: {
                Text("Choose the circles each person is in. They never see your circles or their names.")
            }

            if case .failed(let reason) = state.phase {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Circles")
        .task { await model.perform(.load) }
    }

    private func create() {
        let name = newCircle.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.send(.createCircle(name))
        newCircle = ""
    }
}
