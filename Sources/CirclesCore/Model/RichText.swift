/// Post and comment bodies: a flat sequence of styled runs.
///
/// Deliberately an AST rather than markup, so every UI renders it natively
/// (docs/DESIGN.md §11.6) and nothing needs parsing or sanitizing.
public struct RichText: Sendable, Hashable, Codable {
    public enum Run: Sendable, Hashable {
        case text(String)
        case emphasis(String)
        case strong(String)
        case mention(UserID, displayName: String)
        case hashtag(String)
        case link(url: String, label: String)
    }

    public var runs: [Run]

    public init(_ runs: [Run]) {
        self.runs = runs
    }

    public init(plain text: String) {
        runs = [.text(text)]
    }

    public init(from decoder: any Decoder) throws {
        runs = try decoder.singleValueContainer().decode([Run].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(runs)
    }

    /// Concatenated text of all runs, for previews, search and notifications.
    public var plainText: String {
        runs.map { run in
            switch run {
            case .text(let s), .emphasis(let s), .strong(let s): s
            case .mention(_, let name): "@" + name
            case .hashtag(let tag): "#" + tag
            case .link(_, let label): label
            }
        }.joined()
    }
}

/// Wire form: a CBOR array `[kind, fields…]`. Kind numbers are permanent;
/// new kinds get new numbers, and old numbers are never reused.
extension RichText.Run: Codable {
    private enum Kind: UInt64 {
        case text = 0, emphasis = 1, strong = 2, mention = 3, hashtag = 4, link = 5
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let raw = try container.decode(UInt64.self)
        guard let kind = Kind(rawValue: raw) else {
            throw CBORError.custom("unknown rich text run kind \(raw)")
        }
        switch kind {
        case .text: self = .text(try container.decode(String.self))
        case .emphasis: self = .emphasis(try container.decode(String.self))
        case .strong: self = .strong(try container.decode(String.self))
        case .mention: self = .mention(try container.decode(UserID.self), displayName: try container.decode(String.self))
        case .hashtag: self = .hashtag(try container.decode(String.self))
        case .link: self = .link(url: try container.decode(String.self), label: try container.decode(String.self))
        }
        guard container.isAtEnd else {
            throw CBORError.typeMismatch(expected: "rich text run of kind \(raw)", path: pathDescription(decoder.codingPath))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .text(let s):
            try container.encode(Kind.text.rawValue)
            try container.encode(s)
        case .emphasis(let s):
            try container.encode(Kind.emphasis.rawValue)
            try container.encode(s)
        case .strong(let s):
            try container.encode(Kind.strong.rawValue)
            try container.encode(s)
        case .mention(let user, let name):
            try container.encode(Kind.mention.rawValue)
            try container.encode(user)
            try container.encode(name)
        case .hashtag(let tag):
            try container.encode(Kind.hashtag.rawValue)
            try container.encode(tag)
        case .link(let url, let label):
            try container.encode(Kind.link.rawValue)
            try container.encode(url)
            try container.encode(label)
        }
    }
}
