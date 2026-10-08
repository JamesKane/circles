import Foundation
public import Observation
import CirclesCore
public import CirclesKit

public struct ComposerState: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case editing, posting, posted, failed(String) }

    public struct AttachmentDraft: Sendable, Equatable, Identifiable {
        public var id: Int
        public var mediaType: String
        public var sizeLabel: String
    }

    public var text = ""
    public var shareWithEveryone = false
    /// All our circles, and which are selected.
    public var circles: [String] = []
    public var selectedCircles: Set<String> = []
    public var attachments: [AttachmentDraft] = []
    public var allowComments = true
    public var allowResharing = true
    public var status: Status = .editing

    /// e.g. "Shared with Family, Friends" or "Public".
    public var audienceSummary: String {
        shareWithEveryone ? Strings.everyone : Strings.audience(circles: circles.filter(selectedCircles.contains))
    }

    public var canPost: Bool {
        status != .posting
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && (shareWithEveryone || !selectedCircles.isEmpty)
    }
}

public enum ComposerIntent: Sendable {
    case load
    case editText(String)
    case setShareWithEveryone(Bool)
    case toggleCircle(String)
    case pickImage
    case removeAttachment(id: Int)
    case setAllowComments(Bool)
    case setAllowResharing(Bool)
    case post
}

@MainActor
@Observable
public final class ComposerScreenModel: ScreenModel {
    public private(set) var state = ComposerState()
    private let account: Account
    private let services: any PlatformServices
    private var pending: [Int: Attachment] = [:]
    private var nextID = 0

    public init(account: Account, services: any PlatformServices) {
        self.account = account
        self.services = services
    }

    public func perform(_ intent: ComposerIntent) async {
        switch intent {
        case .load:
            state.circles = await account.circles.map(\.name)
        case .editText(let text):
            state.text = text
        case .setShareWithEveryone(let everyone):
            state.shareWithEveryone = everyone
            if everyone { state.selectedCircles = [] }
        case .toggleCircle(let name):
            if state.selectedCircles.remove(name) == nil { state.selectedCircles.insert(name) }
            state.shareWithEveryone = false
        case .pickImage:
            guard let image = await services.pickImage() else { return }
            pending[nextID] = Attachment(data: image.data, mediaType: image.mediaType, width: image.width, height: image.height)
            state.attachments.append(.init(id: nextID, mediaType: image.mediaType, sizeLabel: Format.byteCount(UInt64(image.data.count))))
            nextID += 1
        case .removeAttachment(let id):
            pending[id] = nil
            state.attachments.removeAll { $0.id == id }
        case .setAllowComments(let allow):
            state.allowComments = allow
        case .setAllowResharing(let allow):
            state.allowResharing = allow
        case .post:
            guard state.canPost else { return }
            state.status = .posting
            let audience: PostAudience = state.shareWithEveryone
                ? .everyone : .circles(state.circles.filter(state.selectedCircles.contains))
            let attachments = state.attachments.compactMap { pending[$0.id] }
            let policy = ReplyPolicy(commentsEnabled: state.allowComments, resharesEnabled: state.allowResharing)
            do {
                try await account.post(RichText(plain: state.text), to: audience, attachments: attachments, replyPolicy: policy)
                state = ComposerState(circles: state.circles, status: .posted)
                pending = [:]
            } catch {
                state.status = .failed(String(describing: error))
            }
        }
    }
}
