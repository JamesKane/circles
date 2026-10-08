import SwiftUI
import CirclesKit
import CirclesPresentation

/// The Settings window (⌘,): account, network, and pods and relays.
struct SettingsView: View {
    let app: AppModel

    var body: some View {
        Group {
            if let session = app.session {
                TabView {
                    Tab("Account", systemImage: "person.crop.circle") {
                        AccountSettings(model: session.settings)
                    }
                    Tab("Network", systemImage: "network") {
                        NetworkSettings(network: session.network)
                    }
                    Tab("Pods & Relays", systemImage: "server.rack") {
                        PodsAndRelaysSettings(model: session.settings)
                    }
                }
                .task { await session.settings.perform(.load) }
            } else {
                Text("Create or open your identity first.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .frame(width: 560, height: 460)
    }
}

private struct AccountSettings: View {
    let model: SettingsScreenModel

    var body: some View {
        let state = model.state
        Form {
            LabeledContent("Name", value: state.displayName)
            LabeledContent("User ID") {
                Text(state.userID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("This device") {
                Text(state.deviceID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Button("Copy User ID", systemImage: "doc.on.doc") { model.send(.copyUserID) }
            if let notice = state.notice {
                Label(notice, systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NetworkSettings: View {
    let network: NetworkModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: preference(\.advertiseOnLocalNetwork)) {
                    Text("Discoverable on the local network")
                    Text("Contacts on the same network find this Mac automatically.")
                }
                Toggle(isOn: preference(\.mapRouterPort)) {
                    Text("Ask the router to forward a port")
                    Text("Makes this Mac reachable from outside (PCP, NAT-PMP or UPnP).")
                }
                Toggle(isOn: preference(\.publishPublicAddress)) {
                    Text("Publish the public address")
                    Text("Lists it in your identity, so contacts can connect directly. Everyone who gets your identity learns it.")
                }
                .disabled(!network.state.preferences.mapRouterPort)
            } footer: {
                Text(network.state.summary())
            }
            Section("Activity") {
                ActivityList(network: network)
                    .frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
    }

    /// Changing a preference saves it and restarts the network service.
    private func preference(_ keyPath: WritableKeyPath<NodePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { network.state.preferences[keyPath: keyPath] },
                set: { on in
                    var preferences = network.state.preferences
                    preferences[keyPath: keyPath] = on
                    if keyPath == \.mapRouterPort, !on { preferences.publishPublicAddress = false }
                    network.send(.setPreferences(preferences))
                })
    }
}

private struct PodsAndRelaysSettings: View {
    let model: SettingsScreenModel
    @State private var podCode = ""
    @State private var relay = ""

    var body: some View {
        let state = model.state
        Form {
            Section {
                ForEach(state.pods, id: \.self) { Text($0).font(.callout.monospaced()) }
                if state.pods.isEmpty { Text("No pods yet.").foregroundStyle(.secondary) }
                HStack {
                    TextField("Pairing code from circles-pod init", text: $podCode, prompt: Text("Pairing code from circles-pod init"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Add Pod") { model.send(.addPod) }
                        .disabled(podCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if state.podBundle != nil {
                    Button("Copy Pairing Command", systemImage: "doc.on.doc") { model.send(.copyPodBundle) }
                        .help("Run it on the pod to finish pairing")
                }
            } header: {
                Text("Pods")
            } footer: {
                Text("An always-on machine of yours that keeps your posts available while this Mac is off.")
            }
            Section {
                ForEach(state.relays, id: \.self) { Text($0).font(.callout.monospaced()) }
                if state.relays.isEmpty { Text("No relays yet.").foregroundStyle(.secondary) }
                HStack {
                    TextField("Relay address", text: $relay, prompt: Text("Relay address"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    Button("Add Relay") { model.send(.addRelay) }
                        .disabled(relay.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Relays")
            } footer: {
                Text("Lets contacts reach you from other networks. Relays only see encrypted traffic.")
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
        .formStyle(.grouped)
        .onChange(of: podCode) { model.send(.editPodCode(podCode)) }
        .onChange(of: model.state.podCodeDraft) { if model.state.podCodeDraft != podCode { podCode = model.state.podCodeDraft } }
        .onChange(of: relay) { model.send(.editRelay(relay)) }
        .onChange(of: model.state.relayDraft) { if model.state.relayDraft != relay { relay = model.state.relayDraft } }
    }
}
