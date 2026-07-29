import CryptoKit
import Foundation
import SQLite3

enum SMSDatabaseError: LocalizedError {
  case open(String)
  case statement(String)
  case operation(String)

  var errorDescription: String? {
    switch self {
    case .open(let message): return "无法打开短信数据库：\(message)"
    case .statement(let message): return "无法准备数据库操作：\(message)"
    case .operation(let message): return "短信数据库操作失败：\(message)"
    }
  }
}

actor SMSDatabase {
  private var database: OpaquePointer?

  init(url: URL = SMSDatabase.defaultURL()) throws {
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
      throw SMSDatabaseError.open(message)
    }
    database = handle
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      try Self.execute(handle, sql: "PRAGMA journal_mode=WAL;")
      try Self.execute(handle, sql: "PRAGMA synchronous=FULL;")
      try Self.execute(
        handle,
        sql: """
          CREATE TABLE IF NOT EXISTS messages (
              id TEXT PRIMARY KEY NOT NULL,
              sender TEXT NOT NULL,
              body TEXT NOT NULL,
              received_at REAL NOT NULL,
              storage TEXT NOT NULL,
              modem_index INTEGER NOT NULL,
              raw_pdu TEXT NOT NULL,
              is_read INTEGER NOT NULL DEFAULT 0,
              imported_at REAL NOT NULL,
              uses_mac_timestamp INTEGER NOT NULL DEFAULT 0
          );
          """)
      if try Self.addMacTimestampColumnIfNeeded(handle) {
        try Self.execute(
          handle,
          sql: """
            UPDATE messages
            SET uses_mac_timestamp = CASE
                WHEN received_at > imported_at OR ABS(imported_at - received_at) <= 300 THEN 1
                ELSE 0
            END;
            """)
      }
      try Self.execute(
        handle,
        sql: """
          CREATE TABLE IF NOT EXISTS message_imports (
              id TEXT PRIMARY KEY NOT NULL,
              imported_at REAL NOT NULL
          );
          """)
      try Self.execute(
        handle,
        sql: """
          CREATE TABLE IF NOT EXISTS imported_parts (
              pdu_hash TEXT PRIMARY KEY NOT NULL,
              message_id TEXT NOT NULL,
              imported_at REAL NOT NULL
          );
          """)
      try Self.execute(
        handle,
        sql: """
          INSERT OR IGNORE INTO message_imports (id, imported_at)
          SELECT id, imported_at FROM messages;
          """)
      try Self.execute(
        handle,
        sql: "CREATE INDEX IF NOT EXISTS messages_received_at ON messages(received_at DESC);")
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

  func insert(_ message: SMSMessage, constituentPDUs: [String]? = nil) throws -> Bool {
    guard let database else { throw SMSDatabaseError.operation("数据库未打开") }
    try Self.execute(database, sql: "BEGIN IMMEDIATE;")
    do {
      let importedAt = message.receivedAt.timeIntervalSince1970
      let importStatement = try prepare(
        "INSERT OR IGNORE INTO message_imports (id, imported_at) VALUES (?, ?);")
      bind(message.id, at: 1, to: importStatement)
      sqlite3_bind_double(importStatement, 2, importedAt)
      guard sqlite3_step(importStatement) == SQLITE_DONE else {
        sqlite3_finalize(importStatement)
        throw operationError()
      }
      let isNewImport = sqlite3_changes(database) > 0
      sqlite3_finalize(importStatement)

      if isNewImport {
        let messageStatement = try prepare(
          """
          INSERT INTO messages
          (id, sender, body, received_at, storage, modem_index, raw_pdu, is_read, imported_at,
           uses_mac_timestamp)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
          """)
        bind(message.id, at: 1, to: messageStatement)
        bind(message.sender, at: 2, to: messageStatement)
        bind(message.body, at: 3, to: messageStatement)
        sqlite3_bind_double(messageStatement, 4, message.serviceCenterAt.timeIntervalSince1970)
        bind(message.storage, at: 5, to: messageStatement)
        sqlite3_bind_int(messageStatement, 6, Int32(message.modemIndex))
        bind(message.rawPDU, at: 7, to: messageStatement)
        sqlite3_bind_int(messageStatement, 8, message.isRead ? 1 : 0)
        sqlite3_bind_double(messageStatement, 9, importedAt)
        sqlite3_bind_int(messageStatement, 10, message.usesMacTimestamp ? 1 : 0)
        guard sqlite3_step(messageStatement) == SQLITE_DONE else {
          sqlite3_finalize(messageStatement)
          throw operationError()
        }
        sqlite3_finalize(messageStatement)
      }

      let rawPDUs = constituentPDUs ?? message.rawPDU.split(separator: ":").map(String.init)
      let normalizedPDUs = Set(rawPDUs.map(Self.normalizedPDU).filter { !$0.isEmpty })
      if !normalizedPDUs.isEmpty {
        let partStatement = try prepare(
          """
          INSERT OR IGNORE INTO imported_parts (pdu_hash, message_id, imported_at)
          VALUES (?, ?, ?);
          """)
        for rawPDU in normalizedPDUs {
          sqlite3_reset(partStatement)
          sqlite3_clear_bindings(partStatement)
          bind(Self.partFingerprint(rawPDU), at: 1, to: partStatement)
          bind(message.id, at: 2, to: partStatement)
          sqlite3_bind_double(partStatement, 3, importedAt)
          guard sqlite3_step(partStatement) == SQLITE_DONE else {
            sqlite3_finalize(partStatement)
            throw operationError()
          }
        }
        sqlite3_finalize(partStatement)
      }

      try Self.execute(database, sql: "COMMIT;")
      return isNewImport
    } catch {
      try? Self.execute(database, sql: "ROLLBACK;")
      throw error
    }
  }

  func allMessages() throws -> [SMSMessage] {
    let statement = try prepare(
      """
      SELECT id, sender, body, received_at, storage, modem_index, raw_pdu, is_read, imported_at,
             uses_mac_timestamp
      FROM messages
      ORDER BY CASE WHEN uses_mac_timestamp != 0 THEN imported_at ELSE received_at END DESC,
               imported_at DESC, modem_index DESC;
      """)
    defer { sqlite3_finalize(statement) }
    var messages: [SMSMessage] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      messages.append(
        SMSMessage(
          id: text(statement, column: 0),
          sender: text(statement, column: 1),
          body: text(statement, column: 2),
          receivedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
          serviceCenterAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
          usesMacTimestamp: sqlite3_column_int(statement, 9) != 0,
          storage: text(statement, column: 4),
          modemIndex: Int(sqlite3_column_int(statement, 5)),
          rawPDU: text(statement, column: 6),
          isRead: sqlite3_column_int(statement, 7) != 0
        )
      )
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw operationError() }
    return messages
  }

  func markRead(id: String) throws {
    let statement = try prepare("UPDATE messages SET is_read = 1 WHERE id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(id, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
  }

  func delete(id: String) throws {
    let statement = try prepare("DELETE FROM messages WHERE id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(id, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
  }

  func knownImportedPDUs(_ rawPDUs: [String]) throws -> Set<String> {
    let candidates = Set(rawPDUs.map(Self.normalizedPDU).filter { !$0.isEmpty })
    guard !candidates.isEmpty else { return [] }
    let statement = try prepare(
      "SELECT 1 FROM imported_parts WHERE pdu_hash = ? LIMIT 1;")
    defer { sqlite3_finalize(statement) }
    var known: Set<String> = []
    for rawPDU in candidates {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      bind(Self.partFingerprint(rawPDU), at: 1, to: statement)
      let result = sqlite3_step(statement)
      if result == SQLITE_ROW {
        known.insert(rawPDU)
      } else if result != SQLITE_DONE {
        throw operationError()
      }
    }
    return known
  }

  private static func execute(_ database: OpaquePointer, sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(error)
      throw SMSDatabaseError.operation(message)
    }
  }

  private static func addMacTimestampColumnIfNeeded(_ database: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(messages);", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else {
      throw SMSDatabaseError.statement(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      if let pointer = sqlite3_column_text(statement, 1),
        String(cString: pointer) == "uses_mac_timestamp"
      {
        return false
      }
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else {
      throw SMSDatabaseError.operation(String(cString: sqlite3_errmsg(database)))
    }
    try execute(
      database,
      sql: "ALTER TABLE messages ADD COLUMN uses_mac_timestamp INTEGER NOT NULL DEFAULT 0;")
    return true
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let database else { throw SMSDatabaseError.operation("数据库未打开") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw SMSDatabaseError.statement(String(cString: sqlite3_errmsg(database)))
    }
    return statement
  }

  private func operationError() -> SMSDatabaseError {
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

  static func defaultURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    return root.appendingPathComponent("CellularBridge", isDirectory: true).appendingPathComponent(
      "messages.sqlite3")
  }

  private static func normalizedPDU(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
  }

  private static func partFingerprint(_ rawPDU: String) -> String {
    let digest = SHA256.hash(data: Data(normalizedPDU(rawPDU).utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
