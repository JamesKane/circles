import SwiftUI
import CirclesKit
import CirclesPresentation

struct RootView: View {
    let app: AppModel

    var body: some View {
        switch app.phase {
        case .loading:
            ProgressView()
        case .onboarding(let model):
            OnboardingView(model: model) { app.start($0) }
        case .ready(_, let network):
            MainView(network: network)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't open your account", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(message)\n\(app.home.path)")
            }
        }
    }
}

struct OnboardingView: View {
    let model: OnboardingScreenModel
    let onCreated: (Account) -> Void
    @State private var name = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "circle.circle")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Welcome to Circles")
                .font(.largeTitle)
            Text("Choose the name people will see. Your identity is created on this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("Your name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit { model.send(.create) }
            if case .failed(let reason) = model.state.phase {
                Text(reason)
                    .foregroundStyle(.red)
            }
            Button("Create Identity") { model.send(.create) }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.state.canCreate)
        }
        .padding(40)
        .onChange(of: name) { model.send(.editName(name)) }
        .onChange(of: model.state.phase) {
            if model.state.phase == .done, let account = model.account { onCreated(account) }
        }
    }
}

/// Until the Stream is built: the network status line and its activity log.
struct MainView: View {
    let network: NetworkModel

    var body: some View {
        NavigationStack {
            Group {
                if network.state.activity.isEmpty {
                    ContentUnavailableView("No network activity yet", systemImage: "antenna.radiowaves.left.and.right")
                } else {
                    List(Array(network.state.activity.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout.monospaced())
                    }
                }
            }
            .navigationTitle("Circles")
            .toolbar {
                ToolbarItem {
                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") { network.send(.syncNow) }
                        .disabled(network.state.syncing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(network.state.summary(now: context.date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                }
                .background(.bar)
            }
        }
    }
}
