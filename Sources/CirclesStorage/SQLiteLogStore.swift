public import Foundation
public import CirclesCore
public import CirclesCrypto
public import CirclesSync

/// The `LogStore` used by devices and pods (docs/DESIGN.md §10): one SQLite
/// database holding log entries exactly as received, identity documents, and
/// blobs (encrypted media chunks). Safe for several processes sharing one
/// database file.
public actor SQLiteLogStore: LogStore {
    private let db: Database

    public init(path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try Database(path: path.path)
        try Self.migrate(db)
    }

    private static func migrate(_ db: Database) throws {
        guard try db.userVersion < 1 else { return }
        try db.transaction {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS entries (
                    author BLOB NOT NULL, device BLOB NOT NULL, seq INTEGER NOT NULL,
                    id BLOB NOT NULL, created INTEGER NOT NULL, signed BLOB NOT NULL,
                    PRIMARY KEY (author, device, seq)
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS identities (
                    user BLOB PRIMARY KEY, version INTEGER NOT NULL, document BLOB NOT NULL
                ) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS blobs (id BLOB PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID;
                CREATE TABLE IF NOT EXISTS needed_blobs (id BLOB PRIMARY KEY) WITHOUT ROWID;
                """)
            try db.setUserVersion(1)
        }
    }

    // MARK: Logs

    public func head(author: UserID, device: DeviceID) throws -> LogHead? {
        let rows = try db.query(
            "SELECT seq, id FROM entries WHERE author = ? AND device = ? ORDER BY seq DESC LIMIT 1",
            [.blob(author.multicodecBytes), .blob(device.multicodecBytes)]
        )
        guard let row = rows.first, let seq = row[0].integer, let id = row[1].blob else { return nil }
        return LogHead(sequence: UInt64(seq), id: try ContentID(multihash: id))
    }

    public func frontier(author: UserID) throws -> Frontier {
        var sequences: [DeviceID: UInt64] = [:]
        for row in try db.query("SELECT device, MAX(seq) FROM entries WHERE author = ? GROUP BY device", [.blob(author.multicodecBytes)]) {
            guard let device = row[0].blob, let seq = row[1].integer else { continue }
            sequences[try DeviceID(multicodecBytes: device)] = UInt64(seq)
        }
        return Frontier(sequences)
    }

    public func append(_ entry: VerifiedLogEntry) throws {
        let (author, device) = (entry.entry.author.multicodecBytes, entry.entry.device.multicodecBytes)
        let signed = try CBOREncoder().encode(entry.signed)
        try db.transaction {
            let head = try self.head(author: entry.entry.author, device: entry.entry.device)
            guard entry.entry.sequence == (head?.sequence ?? 0) + 1, entry.entry.previous == head?.id else {
                throw LogStoreError.notNextInSequence
            }
            try db.query("INSERT INTO entries (author, device, seq, id, created, signed) VALUES (?, ?, ?, ?, ?, ?)", [
                .blob(author), .blob(device), .integer(Int64(entry.entry.sequence)),
                .blob(entry.id.multihash), .integer(Int64(entry.entry.created.millis)), .blob(signed),
            ])
            for blob in entry.entry.blobs ?? [] {
                try db.query("""
                    INSERT OR IGNORE INTO needed_blobs (id)
                    SELECT ? WHERE NOT EXISTS (SELECT 1 FROM blobs WHERE id = ?)
                    """, [.blob(blob.multihash), .blob(blob.multihash)])
            }
        }
    }

    public func entries(author: UserID, device: DeviceID, after sequence: UInt64, limit: Int) throws -> [SignedObject] {
        try db.query(
            "SELECT signed FROM entries WHERE author = ? AND device = ? AND seq > ? ORDER BY seq LIMIT ?",
            [.blob(author.multicodecBytes), .blob(device.multicodecBytes), .integer(Int64(sequence)), .integer(Int64(min(limit, Int(Int64.max))))]
        ).map { try CBORDecoder().decode(SignedObject.self, from: $0[0].blob ?? []) }
    }

    public func authors() throws -> [UserID] {
        try db.query("SELECT DISTINCT author FROM entries").map { try UserID(multicodecBytes: $0[0].blob ?? []) }
    }

    /// All of an author's entries in one query, ordered by creation time.
    public func allEntries(author: UserID) throws -> [SignedObject] {
        try db.query("SELECT signed FROM entries WHERE author = ? ORDER BY created, device, seq", [.blob(author.multicodecBytes)])
            .map { try CBORDecoder().decode(SignedObject.self, from: $0[0].blob ?? []) }
    }

    // MARK: Identities

    public func identityDocument(for user: UserID) throws -> SignedObject? {
        guard let bytes = try db.query("SELECT document FROM identities WHERE user = ?", [.blob(user.multicodecBytes)]).first?[0].blob else {
            return nil
        }
        return try CBORDecoder().decode(SignedObject.self, from: bytes)
    }

    public func saveIdentityDocument(_ document: SignedObject, verified: VerifiedIdentity) throws {
        // Only ever moves forward, even if two processes race.
        try db.query("""
            INSERT INTO identities (user, version, document) VALUES (?, ?, ?)
            ON CONFLICT (user) DO UPDATE SET version = excluded.version, document = excluded.document
            WHERE excluded.version > identities.version
            """, [.blob(verified.user.multicodecBytes), .integer(Int64(verified.version)), .blob(try CBOREncoder().encode(document))])
        // Drop entries past a revoked device's last standing one (received
        // before we learned of the revocation).
        for (device, last) in verified.lastSequences {
            try db.query("DELETE FROM entries WHERE author = ? AND device = ? AND seq > ?",
                         [.blob(verified.user.multicodecBytes), .blob(device.multicodecBytes), .integer(Int64(min(last, UInt64(Int64.max))))])
        }
    }

    // MARK: Blobs

    public func blob(_ id: ContentID) throws -> [UInt8]? {
        try db.query("SELECT data FROM blobs WHERE id = ?", [.blob(id.multihash)]).first?[0].blob
    }

    @discardableResult
    public func putBlob(_ bytes: [UInt8]) throws -> ContentID {
        let id = ContentID(hashing: bytes)
        try db.transaction {
            try db.query("INSERT OR IGNORE INTO blobs (id, data) VALUES (?, ?)", [.blob(id.multihash), .blob(bytes)])
            try db.query("DELETE FROM needed_blobs WHERE id = ?", [.blob(id.multihash)])
        }
        return id
    }

    public func neededBlobs(limit: Int) throws -> [ContentID] {
        try db.query("SELECT id FROM needed_blobs LIMIT ?", [.integer(Int64(limit))])
            .map { try ContentID(multihash: $0[0].blob ?? []) }
    }

    // MARK: Migration

    /// Imports logs and identity documents from an M2/M3 file-based store.
    /// Entries are stored in sequence order; ones already present are skipped.
    public func importLegacyFiles(from root: URL) async throws -> Int {
        let legacy = LegacyFileLogReader(root: root)
        var imported = 0
        for document in legacy.identityDocuments() {
            let claimed = try CBORDecoder().decode(IdentityDocument.self, from: document.payload)
            try saveIdentityDocument(document, verified: try VerifiedIdentity(verifying: document, for: claimed.user))
        }
        for author in legacy.authors() {
            for device in legacy.devices(of: author) {
                for signed in legacy.entries(author: author, device: device) {
                    let entry = try CBORDecoder().decode(LogEntry.self, from: signed.payload)
                    guard entry.sequence > (try head(author: author, device: device)?.sequence ?? 0) else { continue }
                    try append(VerifiedLogEntry(previouslyVerified: signed, entry: entry))
                    imported += 1
                }
            }
        }
        return imported
    }
}
