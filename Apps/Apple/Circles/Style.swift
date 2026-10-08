import SwiftUI
import CirclesCore
import CirclesPresentation

/// Maps the presentation layer's meanings onto SwiftUI, as Style.swift does
/// for libadwaita in the GNOME app.
enum Style {
    static func color(_ token: DesignToken) -> Color {
        switch token {
        case .audiencePublic: .green
        case .audienceLimited: .accentColor
        case .plusOneActive: .accentColor
        case .pending: .orange
        }
    }

    /// Rich text (an AST, docs/DESIGN.md §11.6) → AttributedString. Links
    /// come from other people's posts, so only web and mail links are made
    /// clickable; anything else (file:, custom app schemes) stays plain text.
    static func attributed(_ text: RichText) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            switch run {
            case .text(let s):
                result += AttributedString(s)
            case .emphasis(let s):
                result += styled(s) { $0.inlinePresentationIntent = .emphasized }
            case .strong(let s):
                result += styled(s) { $0.inlinePresentationIntent = .stronglyEmphasized }
            case .mention(_, let name):
                result += styled("@" + name) { $0.inlinePresentationIntent = .stronglyEmphasized }
            case .hashtag(let tag):
                result += styled("#" + tag) { $0.inlinePresentationIntent = .stronglyEmphasized }
            case .link(let url, let label):
                result += styled(label) { attributes in
                    if let url = URL(string: url), let scheme = url.scheme?.lowercased(),
                       ["http", "https", "mailto"].contains(scheme) {
                        attributes.link = url
                    }
                }
            }
        }
        return result
    }

    private static func styled(_ text: String, _ apply: (inout AttributeContainer) -> Void) -> AttributedString {
        var attributes = AttributeContainer()
        apply(&attributes)
        return AttributedString(text, attributes: attributes)
    }

    /// A stable color per name, for avatars. (String.hashValue changes
    /// between launches, so it can't be used.)
    static func avatarColor(_ name: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo, .brown]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

func phaseText(_ phase: Phase) -> String? {
    switch phase {
    case .idle: nil
    case .loading: "Loading…"
    case .syncing: "Syncing with your circles…"
    case .failed(let reason): "Something went wrong: \(reason)"
    }
}
