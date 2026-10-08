import CGtk
import Foundation
import GtkKit
import CirclesCore
import CirclesPresentation

/// GNOME-specific rendering of shared presentation values.
@MainActor
enum Style {
    /// Design tokens (meaning) → libadwaita style classes (look).
    static func classes(for token: DesignToken) -> [String] {
        switch token {
        case .audiencePublic: ["success"]
        case .audienceLimited: ["accent"]
        case .plusOneActive: ["suggested-action"]
        case .pending: ["dim-label", "warning"]
        }
    }

    /// Rich text (an AST, docs/DESIGN.md §11.6) → Pango markup.
    static func markup(_ text: RichText) -> String {
        text.runs.map { run in
            switch run {
            case .text(let s): escape(s)
            case .emphasis(let s): "<i>\(escape(s))</i>"
            case .strong(let s): "<b>\(escape(s))</b>"
            case .mention(_, let name): "<b>@\(escape(name))</b>"
            case .hashtag(let tag): "<span weight=\"bold\">#\(escape(tag))</span>"
            case .link(let url, let label): "<a href=\"\(escape(url))\">\(escape(label))</a>"
            }
        }.joined()
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&apos;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Adds the app's own icons, so they render whatever the desktop's icon
    /// theme is (e.g. Breeze lacks some Adwaita icons).
    static func loadIcons() {
        guard let icons = Bundle.module.url(forResource: "Icons", withExtension: nil) else { return }
        let theme = gtk_icon_theme_get_for_display(gdk_display_get_default())
        gtk_icon_theme_add_search_path(theme, icons.path)
    }

    static func loadCSS() {
        let provider = gtk_css_provider_new()!
        gtk_css_provider_load_from_string(provider, """
            .post-card { padding: 14px; }
            .post-body { font-size: 1.05em; }
            .reshared { padding: 10px; border-left: 3px solid alpha(currentColor, 0.2); }
            .comment { padding: 6px 0; }
            .attachment { border-radius: 8px; }
            """)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), g(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}
