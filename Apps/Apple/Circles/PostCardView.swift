import AppKit
import SwiftUI
import CirclesCore
import CirclesPresentation

/// A post: in the Stream as a card, and on the post page with its thread.
struct PostCardView: View {
    let card: PostCard
    let media: MediaLoader
    /// Bumps when a sync brings new content, so attachments that hadn't
    /// synced yet try again.
    let generation: Int
    var showThread = false
    let onPlusOne: () -> Void
    var onOpen: () -> Void = {}
    var onReshare: () -> Void = {}
    var onRemoveComment: (CommentRow) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !card.body.plainText.isEmpty {
                Text(Style.attributed(card.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let original = card.reshared {
                ResharedView(original: original, media: media, generation: generation)
            }
            ForEach(card.attachments) { preview in
                AttachmentView(preview: preview, media: media, generation: generation)
            }
            actions
            if showThread {
                thread
            }
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: card.authorName, initials: card.authorInitials)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.authorName)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text(card.timestamp)
                    Text("·")
                    Text(card.audienceLabel)
                        .foregroundStyle(Style.color(card.audienceToken))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(action: onPlusOne) {
                Text(card.plusOnes > 0 ? "+1  \(card.plusOnes)" : "+1")
                    .monospacedDigit()
            }
            .buttonStyle(.bordered)
            .tint(card.plusOnedByMe ? Style.color(.plusOneActive) : nil)
            .background(card.plusOnedByMe ? Style.color(.plusOneActive).opacity(0.15) : .clear, in: .capsule)
            .help(card.plusOnedByMe ? "Remove your +1" : "+1 this post")
            .accessibilityLabel(card.plusOnedByMe ? "Remove +1, \(card.plusOnes) total" : "+1, \(card.plusOnes) total")

            Button(action: onOpen) {
                Label(card.comments.isEmpty ? "Comment" : "\(card.comments.count)", systemImage: "bubble.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(card.comments.isEmpty ? "Comment" : "\(card.comments.count) comments")
            .accessibilityLabel(card.comments.isEmpty ? "Comment" : "\(card.comments.count) comments")
            if card.canReshare {
                Button("Reshare publicly", systemImage: "arrow.2.squarepath", action: onReshare)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reshare publicly")
            }
            Spacer()
        }
        .font(.callout)
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(card.comments) { comment in
                // A visible menu as well as the context menu: right-clicking
                // the comment's (selectable) text shows the text menu instead.
                HStack(alignment: .top) {
                    CommentView(comment: comment)
                    Spacer(minLength: 0)
                    if comment.canRemove {
                        Menu("Comment Actions", systemImage: "ellipsis") {
                            Button("Remove Comment…", role: .destructive) { onRemoveComment(comment) }
                        }
                        .labelStyle(.iconOnly)
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    if comment.canRemove {
                        Button("Remove Comment…", role: .destructive) { onRemoveComment(comment) }
                    }
                }
            }
            if !card.canComment {
                Text("Comments are turned off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, card.comments.isEmpty ? 0 : 4)
    }
}

struct CommentView: View {
    let comment: CommentRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(name: comment.authorName, initials: Format.initials(comment.authorName), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(comment.authorName).fontWeight(.semibold)
                    Text("· \(comment.timestamp)").foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(Style.attributed(comment.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if comment.pending {
                    Label(Strings.pending, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(Style.color(.pending))
                }
            }
        }
        .opacity(comment.pending ? 0.8 : 1)
    }
}

struct ResharedView: View {
    let original: ResharedCard
    let media: MediaLoader
    let generation: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(original.authorName) · \(original.timestamp)", systemImage: "arrow.2.squarepath")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !original.body.plainText.isEmpty {
                Text(Style.attributed(original.body))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(original.attachments) { preview in
                AttachmentView(preview: preview, media: media, generation: generation)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

struct AvatarView: View {
    let name: String
    let initials: String
    var size: CGFloat = 36

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Style.avatarColor(name), in: .circle)
            .accessibilityHidden(true)
    }
}

/// A placeholder until the bytes load, then the picture, or a note if they
/// haven't synced yet or aren't an image.
struct AttachmentView: View {
    let preview: AttachmentPreview
    let media: MediaLoader
    let generation: Int
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel("Attached image")
            } else {
                Label(missing ? "\(preview.mediaType) · \(preview.sizeLabel) · not synced yet"
                              : "\(preview.mediaType) · \(preview.sizeLabel)",
                      systemImage: preview.mediaType.hasPrefix("image/") ? "photo" : "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: placeholderHeight)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }
        }
        .task(id: LoadKey(id: preview.id, generation: generation)) {
            guard image == nil else { return }
            guard let bytes = try? await media.data(for: preview) else {
                missing = true
                return
            }
            missing = false
            if preview.mediaType.hasPrefix("image/") {
                image = NSImage(data: Data(bytes))
            }
        }
    }

    private struct LoadKey: Equatable {
        let id: ContentID
        let generation: Int
    }

    /// Reserves roughly the picture's height, when its size is known, so
    /// the list doesn't jump when it loads.
    private var placeholderHeight: CGFloat {
        guard let width = preview.width, let height = preview.height, width > 0 else { return 60 }
        return min(420, 640 * CGFloat(height) / CGFloat(width))
    }
}
