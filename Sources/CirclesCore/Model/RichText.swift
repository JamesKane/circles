/// Post and comment bodies: a flat sequence of styled runs.
///
/// Deliberately an AST rather than markup, so every UI renders it natively
/// (docs/DESIGN.md §11.6) and nothing needs parsing or sanitizing.
public struct RichText: Sendable, Hashable, Codable {
    public enum Run: Sendable, Hashable, Codable {
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
}
