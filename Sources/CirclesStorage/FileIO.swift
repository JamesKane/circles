public import Foundation

/// Small, careful file helpers shared by the stores.
public enum FileIO {
    /// Writes atomically (temp file + rename). `private` restricts the file
    /// to its owner (0600), for files holding keys.
    public static func write(_ bytes: [UInt8], to url: URL, private isPrivate: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url, options: .atomic)
        if isPrivate {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Creates `url` with `bytes` only if it doesn't exist yet, atomically:
    /// the content is written to a temp file and hard-linked into place, and
    /// the link fails if another writer got there first.
    /// Returns false if the file already existed.
    public static func createExclusively(_ bytes: [UInt8], at url: URL) throws -> Bool {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try Data(bytes).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.linkItem(at: temp, to: url)
            return true
        } catch {
            if FileManager.default.fileExists(atPath: url.path) { return false }
            throw error
        }
    }

    public static func read(_ url: URL) throws -> [UInt8]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Array(try Data(contentsOf: url))
    }

    public static func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }
    }
}
