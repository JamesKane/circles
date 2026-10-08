import CSQLite

/// A minimal SQLite connection. Not thread-safe: each one is owned by a
/// single actor.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws(SQLiteError) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let error = SQLiteError(handle)
            sqlite3_close_v2(handle)
            throw error
        }
        // Several processes may share one database (e.g. `circles serve`
        // alongside CLI commands): WAL lets readers and a writer coexist, and
        // the busy timeout makes writers wait for each other instead of failing.
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws(SQLiteError) {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteError(handle) }
    }

    /// Runs `sql` with `values` bound to its `?` parameters and returns every row.
    @discardableResult
    func query(_ sql: String, _ values: [SQLValue] = []) throws(SQLiteError) -> [[SQLValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw SQLiteError(handle) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .integer(let int):
                result = sqlite3_bind_int64(statement, position, int)
            case .text(let text):
                result = sqlite3_bind_text(statement, position, text, -1, transient)
            case .blob(let bytes):
                result = bytes.withUnsafeBytes { buffer in
                    // A zero-length blob still needs a non-null pointer to bind as a blob.
                    sqlite3_bind_blob(statement, position, buffer.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(buffer.count), transient)
                }
            case .null:
                result = sqlite3_bind_null(statement, position)
            }
            guard result == SQLITE_OK else { throw SQLiteError(handle) }
        }
        var rows: [[SQLValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
            case SQLITE_DONE:
                return rows
            default:
                throw SQLiteError(handle)
            }
        }
    }

    /// Runs `body` in a write transaction (`BEGIN IMMEDIATE`, so the write
    /// lock is taken up front and concurrent writers queue on the busy timeout).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int64 {
        get throws(SQLiteError) { try query("PRAGMA user_version").first?.first?.integer ?? 0 }
    }

    func setUserVersion(_ version: Int64) throws(SQLiteError) {
        try execute("PRAGMA user_version = \(version)")
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .blob([]) }
            return .blob(Array(UnsafeRawBufferPointer(start: pointer, count: count)))
        default:
            return .null
        }
    }
}

/// SQLite's SQLITE_TRANSIENT: copy bound values immediately.
private let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

enum SQLValue: Equatable {
    case integer(Int64)
    case text(String)
    case blob([UInt8])
    case null

    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var blob: [UInt8]? { if case .blob(let value) = self { value } else { nil } }
    var text: String? { if case .text(let value) = self { value } else { nil } }
}

public struct SQLiteError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String

    init(_ handle: OpaquePointer?) {
        code = sqlite3_errcode(handle)
        message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
    }

    public var description: String { "SQLite error \(code): \(message)" }
}
