import Foundation
import CirclesCrypto
public import Observation
public import CirclesCore
public import CirclesKit

// MARK: - Onboarding

public struct OnboardingState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case editing, creating, failed(String), done }
    public var name = ""
    public var phase: Phase = .editing
    public var canCreate: Bool { phase != .creating && !name.trimmingCharacters(in: .whitespaces).isEmpty }
}

public enum OnboardingIntent: Sendable {
    case editName(String)
    case create
}

/// Creating this device's identity.
@MainActor
@Observable
public final class OnboardingScreenModel: ScreenModel {
    public private(set) var state = OnboardingState()
    /// Set once the account exists.
    public private(set) var account: Account?
    private let home: URL

    public init(home: URL) {
        self.home = home
    }

    public func perform(_ intent: OnboardingIntent) async {
        switch intent {
        case .editName(let name):
            state.name = name
        case .create:
            guard state.canCreate else { return }
            state.phase = .creating
            do {
                account = try await Account.create(home: home, displayName: state.name.trimmingCharacters(in: .whitespaces))
                state.phase = .done
            } catch {
                state.phase = .failed(String(describing: error))
            }
        }
    }
}

// MARK: - People

public struct PeopleState: Sendable, Equatable {
    public struct Person: Sendable, Equatable, Identifiable {
        public var user: UserID
        public var name: String
        public var initials: String
        public var circles: [String]
        public var id: UserID { user }
    }

    public var myName = ""
    /// Text to send to someone so they can add us.
    public var myInvite = ""
    public var inviteDraft = ""
    public var people: [Person] = []
    public var notice: String?
    public var phase: Phase = .idle

    public var canAdd: Bool { inviteDraft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("circles-invite:") }
}

public enum PeopleIntent: Sendable {
    case load
    case editInvite(String)
    case addContact
    case copyMyInvite
    /// Changes our local name for someone.
    case rename(UserID, to: String)
    /// Removes someone from our contacts and all our circles.
    case remove(UserID)
}

/// Adding people: exchange invites (docs/DESIGN.md §6.3). Both sides add
/// each other's invite before they can sync.
@MainActor
@Observable
public final class PeopleScreenModel: ScreenModel {
    public private(set) var state = PeopleState()
    private let account: Account
    private let services: any PlatformServices

    public init(account: Account, services: any PlatformServices) {
        self.account = account
        self.services = services
    }

    public func perform(_ intent: PeopleIntent) async {
        switch intent {
        case .load:
            await reload()
        case .editInvite(let text):
            state.inviteDraft = text
        case .addContact:
            guard state.canAdd else { return }
            do {
                let contact = try await account.addContact(invite: state.inviteDraft)
                state.inviteDraft = ""
                state.notice = "Added \(contact.name). They need your invite too, then you can sync."
                state.phase = .idle
                await reload()
            } catch {
                state.phase = .failed("That invite didn't work: \(error)")
            }
        case .copyMyInvite:
            await services.copyToClipboard(state.myInvite)
            state.notice = "Your invite is on the clipboard."
        case .rename(let user, let name):
            do {
                try await account.renameContact(user, to: name)
                state.phase = .idle
            } catch {
                state.phase = .failed("Couldn't rename: \(error)")
            }
            await reload()
        case .remove(let user):
            let name = state.people.first { $0.user == user }?.name ?? "them"
            do {
                try await account.removeContact(user)
                state.notice = "Removed \(name). They can't see anything you post from now on."
                state.phase = .idle
            } catch {
                state.phase = .failed("Couldn't remove \(name): \(error)")
            }
            await reload()
        }
    }

    private func reload() async {
        state.myName = await account.displayName
        state.myInvite = (try? await account.invite()) ?? ""
        let circles = await account.circles
        state.people = await account.contacts.map { contact in
            PeopleState.Person(user: contact.user, name: contact.name, initials: Format.initials(contact.name),
                               circles: circles.filter { $0.members.contains(contact.user) }.map(\.name))
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - Settings

public struct SettingsState: Sendable, Equatable {
    public var displayName = ""
    public var userID = ""
    public var deviceID = ""
    public var pods: [String] = []
    public var relays: [String] = []
    public var podCodeDraft = ""
    public var relayDraft = ""
    /// After adding a pod: what to paste into `circles-pod pair` on it.
    public var podBundle: String?
    public var notice: String?
    public var phase: Phase = .idle
}

public enum SettingsIntent: Sendable {
    case load
    case editPodCode(String)
    case addPod
    case copyPodBundle
    case editRelay(String)
    case addRelay
    case copyUserID
}

/// Identity, pods and relays. Network options live in `NetworkModel`.
@MainActor
@Observable
public final class SettingsScreenModel: ScreenModel {
    public private(set) var state = SettingsState()
    private let account: Account
    private let services: any PlatformServices

    public init(account: Account, services: any PlatformServices) {
        self.account = account
        self.services = services
    }

    public func perform(_ intent: SettingsIntent) async {
        switch intent {
        case .load:
            break
        case .editPodCode(let text):
            state.podCodeDraft = text
        case .addPod:
            do {
                let bundle = try await account.addPod(try PodPairingCode(text: state.podCodeDraft))
                state.podBundle = try bundle.text
                state.podCodeDraft = ""
                state.notice = "Pod certified. Copy the pairing bundle to the pod, then sync."
                state.phase = .idle
            } catch {
                state.phase = .failed("That pairing code didn't work: \(error)")
            }
        case .copyPodBundle:
            if let bundle = state.podBundle {
                await services.copyToClipboard("circles-pod pair " + bundle)
                state.notice = "The pairing command is on the clipboard."
            }
        case .editRelay(let text):
            state.relayDraft = text
        case .addRelay:
            do {
                try await account.addRelay(try RelayIdentity.parse(address: state.relayDraft.trimmingCharacters(in: .whitespacesAndNewlines)))
                state.relayDraft = ""
                state.notice = "Relay added. Contacts can reach you through it once they've synced your new identity."
                state.phase = .idle
            } catch {
                state.phase = .failed("That relay address didn't work: \(error)")
            }
        case .copyUserID:
            await services.copyToClipboard(state.userID)
            state.notice = "Your user ID is on the clipboard."
        }
        await reload()
    }

    private func reload() async {
        state.displayName = await account.displayName
        state.userID = account.user.description
        state.deviceID = account.deviceID.description
        let endpoints = await account.endpoints
        state.pods = endpoints.pods.map { "\($0.host):\($0.port)" }
        state.relays = endpoints.relays.map { "\($0.host):\($0.port)" }
    }
}
