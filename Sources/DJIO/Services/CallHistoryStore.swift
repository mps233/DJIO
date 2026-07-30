import Foundation
import SQLite3

enum CallHistoryStoreError: LocalizedError {
  case open(String)
  case statement(String)
  case operation(String)

  var errorDescription: String? {
    switch self {
    case .open(let message): return "无法打开来电记录数据库：\(message)"
    case .statement(let message): return "无法准备来电记录数据库操作：\(message)"
    case .operation(let message): return "来电记录数据库操作失败：\(message)"
    }
  }
}

actor CallHistoryStore {
  private var database: OpaquePointer?

  init(url: URL = CallHistoryStore.defaultURL()) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.deletingLastPathComponent().path
    )

    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
      if let handle { sqlite3_close(handle) }
      throw CallHistoryStoreError.open(message)
    }
    database = handle

    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      try Self.execute(handle, sql: "PRAGMA journal_mode=WAL;")
      try Self.execute(handle, sql: "PRAGMA synchronous=FULL;")
      try Self.execute(
        handle,
        sql: """
          CREATE TABLE IF NOT EXISTS calls (
              id TEXT PRIMARY KEY NOT NULL,
              caller_number TEXT,
              received_at REAL NOT NULL
          );
          """)
      try Self.execute(
        handle,
        sql:
          "CREATE INDEX IF NOT EXISTS calls_received_at ON calls(received_at DESC, id DESC);")
    } catch {
      database = nil
      sqlite3_close(handle)
      throw error
    }
  }

  deinit {
    if let database {
      sqlite3_close(database)
    }
  }

  func insert(_ call: IncomingCallRecord) throws -> Bool {
    guard let database else { throw CallHistoryStoreError.operation("数据库未打开") }
    let statement = try prepare(
      "INSERT OR IGNORE INTO calls (id, caller_number, received_at) VALUES (?, ?, ?);")
    defer { sqlite3_finalize(statement) }

    bind(call.id, at: 1, to: statement)
    if let callerNumber = call.callerNumber {
      bind(callerNumber, at: 2, to: statement)
    } else {
      sqlite3_bind_null(statement, 2)
    }
    sqlite3_bind_double(statement, 3, call.receivedAt.timeIntervalSince1970)

    guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
    return sqlite3_changes(database) > 0
  }

  func allCalls() throws -> [IncomingCallRecord] {
    let statement = try prepare(
      """
      SELECT id, caller_number, received_at
      FROM calls
      ORDER BY received_at DESC, id DESC;
      """)
    defer { sqlite3_finalize(statement) }

    var calls: [IncomingCallRecord] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      calls.append(
        IncomingCallRecord(
          id: text(statement, column: 0),
          callerNumber: optionalText(statement, column: 1),
          receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        ))
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw operationError() }
    return calls
  }

  func delete(id: String) throws {
    let statement = try prepare("DELETE FROM calls WHERE id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(id, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
  }

  func updateCallerNumber(id: String, callerNumber: String?) throws {
    guard
      let callerNumber = callerNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
      !callerNumber.isEmpty
    else {
      return
    }
    let statement = try prepare("UPDATE calls SET caller_number = ? WHERE id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(callerNumber, at: 1, to: statement)
    bind(id, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
  }

  static func defaultURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    return root.appendingPathComponent("CellularBridge", isDirectory: true).appendingPathComponent(
      "calls.sqlite3")
  }

  private static func execute(_ database: OpaquePointer, sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(error)
      throw CallHistoryStoreError.operation(message)
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let database else { throw CallHistoryStoreError.operation("数据库未打开") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw CallHistoryStoreError.statement(String(cString: sqlite3_errmsg(database)))
    }
    return statement
  }

  private func operationError() -> CallHistoryStoreError {
    let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库未打开"
    return .operation(message)
  }

  private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
    sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
  }

  private func text(_ statement: OpaquePointer, column: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: pointer)
  }

  private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL,
      let pointer = sqlite3_column_text(statement, column)
    else {
      return nil
    }
    return String(cString: pointer)
  }

  private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
