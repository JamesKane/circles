import Foundation
public import Observation
public import CirclesCore
public import CirclesKit

public struct CirclesState: Sendable, Equatable {
    public struct CircleRow: Sendable, Equatable, Identifiable {
        public var name: String
        public var memberNames: [String]
        public var id: String { name }
    }

    public struct ContactRow: Sendable, Equatable, Identifiable {
        public var user: UserID
        public var name: String
        public var initials: String
        /// The circles this contact is in. They never see these names.
        public var circles: [String]
        public var id: UserID { user }
    }

    public var circles: [CircleRow] = []
    public var contacts: [ContactRow] = []
    public var phase: Phase = .idle
}

public enum CirclesIntent: Sendable {
    case load
    case createCircle(String)
    case add(UserID, toCircle: String)
    case remove(UserID, fromCircle: String)
}

/// Organizing contacts into circles, Google+'s signature screen.
@MainActor
@Observable
public final class CirclesScreenModel: ScreenModel {
    public private(set) var state = CirclesState()
    private let account: Account

    public init(account: Account) {
        self.account = account
    }

    public func perform(_ intent: CirclesIntent) async {
        do {
            switch intent {
            case .load:
                break
            case .createCircle(let name):
                try await account.createCircle(name)
            case .add(let user, let circle):
                try await account.addToCircle(circle, members: [user])
            case .remove(let user, let circle):
                try await account.removeFromCircle(circle, members: [user])
            }
            await reload()
        } catch {
            state.phase = .failed(String(describing: error))
        }
    }

    private func reload() async {
        let circles = await account.circles, contacts = await account.contacts
        var rows: [CirclesState.CircleRow] = []
        for circle in circles {
            var names: [String] = []
            for member in circle.members { names.append(await account.name(of: member)) }
            rows.append(.init(name: circle.name, memberNames: names.sorted()))
        }
        state.circles = rows
        state.contacts = contacts.map { contact in
            .init(user: contact.user, name: contact.name, initials: Format.initials(contact.name),
                  circles: circles.filter { $0.members.contains(contact.user) }.map(\.name))
        }.sorted { $0.name < $1.name }
        state.phase = .idle
    }
}
