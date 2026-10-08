import AppKit
import UniformTypeIdentifiers
import UserNotifications
import CirclesPresentation

/// PlatformServices on macOS: an open panel for photos, the general
/// pasteboard, and user notifications.
nonisolated struct MacServices: PlatformServices {
    func pickImage() async -> PickedImage? {
        guard let url = await Self.choosePhoto() else { return nil }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let photo = PhotoPreparation.prepare(data) else { return nil }
        return PickedImage(data: [UInt8](photo.data), mediaType: photo.mediaType, width: photo.width, height: photo.height)
    }

    func copyToClipboard(_ text: String) async {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func notify(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    @MainActor private static func choosePhoto() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Add a Photo"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}
