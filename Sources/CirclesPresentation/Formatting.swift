import Foundation
public import CirclesCore

/// Display formatting shared by all UIs, so every platform says the same thing.
public enum Format {
    /// "just now", "5 min", "3 h", "yesterday", or a date.
    public static func relativeTime(_ timestamp: HLCTimestamp, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp.millis) / 1000)
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return Strings.justNow
        case ..<3600: return "\(seconds / 60) min"
        case ..<86_400: return "\(seconds / 3600) h"
        case ..<172_800: return Strings.yesterday
        default: return date.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// "1 KB", "2.4 MB".
    public static func byteCount(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        let tenths = bytes * 10 / (1024 * 1024)
        return "\(tenths / 10).\(tenths % 10) MB"
    }

    /// Up to two initials for an avatar placeholder, from the first letter
    /// or digit of each word, so "Bob (work)" gives "BW", not "B(".
    public static func initials(_ name: String) -> String {
        let words = name.split(separator: " ").compactMap { $0.first { $0.isLetter || $0.isNumber } }
        return String(words.prefix(2)).uppercased()
    }
}

/// User-facing text. Centralized so localization has one place to start.
public enum Strings {
    public static let justNow = "just now"
    public static let yesterday = "yesterday"
    public static let everyone = "Public"
    public static let limited = "Limited"
    public static let pending = "Only you can see this until it's approved"
    public static let noAudience = "Choose who can see this"
    /// Never says "Public" unless the post really is: an empty selection must
    /// not read as sharing with everyone.
    public static func audience(circles: [String]) -> String {
        circles.isEmpty ? noAudience : "Shared with " + circles.joined(separator: ", ")
    }
}

/// Semantic design tokens: meaning, not pixels. Each backend maps them onto
/// its own palette and spacing, including dark mode and high contrast.
public enum DesignToken: Sendable, Hashable {
    case audiencePublic
    case audienceLimited
    case plusOneActive
    case pending
}
