public import Observation
public import CirclesCore

/// Where the user is. Each backend maps routes onto its own navigation
/// (split view on desktop, a stack on phones).
public enum Route: Sendable, Hashable {
    case stream
    case post(ObjectRef)
    case composer
    case circles
}

@MainActor
@Observable
public final class NavigationModel {
    public private(set) var path: [Route] = []

    public init() {}

    public var current: Route { path.last ?? .stream }

    public func push(_ route: Route) { path.append(route) }
    public func pop() { _ = path.popLast() }
    public func popToRoot() { path.removeAll() }
}

/// Services a backend provides to the screen models.
public protocol PlatformServices: Sendable {
    /// Lets the user pick a photo; nil if they cancel.
    func pickImage() async -> PickedImage?
    func copyToClipboard(_ text: String) async
    func notify(title: String, body: String) async
}

public struct PickedImage: Sendable {
    public var data: [UInt8]
    public var mediaType: String
    public var width: UInt32?
    public var height: UInt32?

    public init(data: [UInt8], mediaType: String, width: UInt32? = nil, height: UInt32? = nil) {
        self.data = data
        self.mediaType = mediaType
        self.width = width
        self.height = height
    }
}
