import Foundation
import SQLite3

/// A small wrapper over the system SQLite: one connection, serialized by a lock, so it can be used from the
/// main actor and from background tasks. Used for the catalog pack and the local collection mirror.
final class SQLiteDB: @unchecked Sendable {
    enum Value {
        case text(String), int(Int), double(Double), null
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A stepped row; read columns by position.
    struct Row {
        fileprivate let stmt: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }

    /// A prepared statement for bulk work (inserting a catalog pack). Use only inside `locked`/`transaction`.
    final class Statement {
        fileprivate let stmt: OpaquePointer
        private let db: SQLiteDB
        fileprivate init(_ stmt: OpaquePointer, _ db: SQLiteDB) { self.stmt = stmt; self.db = db }
        deinit { sqlite3_finalize(stmt) }

        func run(_ args: [Value]) throws {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            db.bind(stmt, args)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw db.failure() }
        }
    }

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    let path: String

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var h: OpaquePointer?
        guard sqlite3_open_v2(path, &h, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "Can't open \(path)"
            sqlite3_close(h)
            throw Failure(message: msg)
        }
        handle = h
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let h = handle { sqlite3_close_v2(h) }
        handle = nil
    }

    func exec(_ sql: String) throws {
        try locked { h in
            guard sqlite3_exec(h, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        }
    }

    func run(_ sql: String, _ args: [Value] = []) throws {
        try locked { _ in try prepare(sql).run(args) }
    }

    func query<T>(_ sql: String, _ args: [Value] = [], _ map: (Row) throws -> T) throws -> [T] {
        try locked { _ in
            let s = try prepare(sql)
            bind(s.stmt, args)
            var out: [T] = []
            while true {
                let rc = sqlite3_step(s.stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw failure() }
                out.append(try map(Row(stmt: s.stmt)))
            }
            return out
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try locked { h in
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(h, sql, -1, &s, nil) == SQLITE_OK, let s else { throw failure() }
            return Statement(s, self)
        }
    }

    /// Runs `body` in one transaction holding the lock; rolls back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked { _ in
            try exec("BEGIN IMMEDIATE")
            do {
                let r = try body()
                try exec("COMMIT")
                return r
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    private func locked<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let h = handle else { throw Failure(message: "Database closed") }
        return try body(h)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate func bind(_ stmt: OpaquePointer, _ args: [Value]) {
        for (i, v) in args.enumerated() {
            let at = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, at, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(stmt, at, Int64(n))
            case .double(let d): sqlite3_bind_double(stmt, at, d)
            case .null: sqlite3_bind_null(stmt, at)
            }
        }
    }

    fileprivate func failure() -> Failure {
        Failure(message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database closed")
    }
}
