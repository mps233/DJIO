import Foundation
import SQLite3

enum SMSOutboxError: LocalizedError, Equatable {
  case open(String)
  case statement(String)
  case operation(String)
  case invalidRecipient
  case emptyBody
  case invalidPartCount
  case missingConcatenationReference
  case noConcatenationReferenceAvailable
  case messageNotFound(String)
  case partNotFound(Int)
  case invalidTransition(from: OutgoingSMSState, to: OutgoingSMSState)

  var errorDescription: String? {
    switch self {
    case .open(let message): return "无法打开发件箱数据库：\(message)"
    case .statement(let message): return "无法准备发件箱数据库操作：\(message)"
    case .operation(let message): return "发件箱数据库操作失败：\(message)"
    case .invalidRecipient: return "收件号码不能为空"
    case .emptyBody: return "短信内容不能为空"
    case .invalidPartCount: return "短信分段数必须大于零"
    case .missingConcatenationReference: return "长短信必须包含稳定的拼接引用"
    case .noConcatenationReferenceAvailable:
      return "同一收件人的长短信过多，请稍后再试"
    case .messageNotFound: return "找不到待发送短信"
    case .partNotFound(let index): return "找不到短信分段 \(index + 1)"
    case .invalidTransition(let from, let to):
      return "无法将短信状态从 \(from.rawValue) 改为 \(to.rawValue)"
    }
  }
}

actor SMSOutboxStore {
  private static let concatenationReferenceReuseInterval: TimeInterval = 24 * 60 * 60
  private var database: OpaquePointer?

  init(url: URL = SMSOutboxStore.defaultURL()) throws {
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
      throw SMSOutboxError.open(message)
    }
    database = handle

    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      try Self.execute(handle, sql: "PRAGMA foreign_keys=ON;")
      try Self.execute(handle, sql: "PRAGMA journal_mode=WAL;")
      try Self.execute(handle, sql: "PRAGMA synchronous=FULL;")
      try Self.execute(
        handle,
        sql: """
          CREATE TABLE IF NOT EXISTS outgoing_messages (
              id TEXT PRIMARY KEY NOT NULL,
              recipient TEXT NOT NULL,
              body TEXT NOT NULL,
              concatenation_reference INTEGER,
              state TEXT NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              sent_at REAL,
              attempt_count INTEGER NOT NULL DEFAULT 0,
              last_error TEXT
          );
          """)
      try Self.addConcatenationReferenceColumnIfNeeded(handle)
      try Self.execute(
        handle,
        sql: """
          CREATE TABLE IF NOT EXISTS outgoing_concatenation_references (
              recipient TEXT NOT NULL,
              reference INTEGER NOT NULL,
              allocated_at REAL NOT NULL,
              PRIMARY KEY (recipient, reference)
          );
          """)
      try Self.execute(
        handle,
        sql: """
          INSERT OR IGNORE INTO outgoing_concatenation_references
              (recipient, reference, allocated_at)
          SELECT recipient, concatenation_reference, updated_at
          FROM outgoing_messages
          WHERE concatenation_reference IS NOT NULL;
          """)
      try Self.execute(
        handle,
        sql: """
          CREATE TABLE IF NOT EXISTS outgoing_parts (
              message_id TEXT NOT NULL,
              part_index INTEGER NOT NULL,
              pdu TEXT,
              tpdu_length INTEGER,
              state TEXT NOT NULL,
              attempt_count INTEGER NOT NULL DEFAULT 0,
              modem_reference INTEGER,
              last_error TEXT,
              updated_at REAL NOT NULL,
              PRIMARY KEY (message_id, part_index),
              FOREIGN KEY (message_id) REFERENCES outgoing_messages(id) ON DELETE CASCADE
          );
          """)
      try Self.addOutgoingPartPayloadColumnsIfNeeded(handle)
      try Self.backfillOutgoingPartPayloads(handle)
      try Self.execute(
        handle,
        sql:
          "CREATE INDEX IF NOT EXISTS outgoing_messages_state_created ON outgoing_messages(state, created_at);"
      )
      try Self.recoverInterruptedMessages(handle, at: Date())
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

  func enqueue(
    recipient: String,
    body: String,
    at date: Date = Date()
  ) throws -> OutgoingSMS {
    let probeParts = try SMSPDUEncoder(concatenationReferenceProvider: { 0 }).encode(
      recipient: recipient,
      body: body
    )
    guard let firstPart = probeParts.first else { throw SMSPDUEncodingError.emptyMessage }
    guard probeParts.count > 1 else {
      return try enqueue(
        recipient: firstPart.recipient,
        body: body,
        encodedParts: probeParts,
        at: date
      )
    }

    let reference = try reserveConcatenationReference(for: firstPart.recipient, at: date)
    let encodedParts = try SMSPDUEncoder(
      concatenationReferenceProvider: { reference }
    ).encode(recipient: firstPart.recipient, body: body)
    return try enqueue(
      recipient: firstPart.recipient,
      body: body,
      encodedParts: encodedParts,
      at: date
    )
  }

  func enqueue(
    recipient: String,
    body: String,
    partCount: Int,
    concatenationReference: UInt8? = nil,
    at date: Date = Date()
  ) throws -> OutgoingSMS {
    let normalizedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRecipient.isEmpty else { throw SMSOutboxError.invalidRecipient }
    guard !body.isEmpty else { throw SMSOutboxError.emptyBody }
    guard partCount > 0 else { throw SMSOutboxError.invalidPartCount }
    guard partCount == 1 || concatenationReference != nil else {
      throw SMSOutboxError.missingConcatenationReference
    }

    let reference = concatenationReference ?? 0
    let encodedParts: [EncodedSMSPart]
    do {
      encodedParts = try SMSPDUEncoder(concatenationReferenceProvider: { reference }).encode(
        recipient: normalizedRecipient,
        body: body
      )
    } catch {
      throw SMSOutboxError.operation(error.localizedDescription)
    }
    guard encodedParts.count == partCount,
      encodedParts.first?.concatenationReference == concatenationReference
    else {
      throw SMSOutboxError.operation("短信编码结果与分段信息不一致")
    }
    return try enqueue(
      recipient: encodedParts[0].recipient,
      body: body,
      encodedParts: encodedParts,
      at: date
    )
  }

  func enqueue(
    recipient: String,
    body: String,
    encodedParts: [EncodedSMSPart],
    at date: Date = Date()
  ) throws -> OutgoingSMS {
    let normalizedRecipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRecipient.isEmpty else { throw SMSOutboxError.invalidRecipient }
    guard !body.isEmpty else { throw SMSOutboxError.emptyBody }
    guard !encodedParts.isEmpty else { throw SMSOutboxError.invalidPartCount }
    guard encodedParts.count == 1 || encodedParts.first?.concatenationReference != nil else {
      throw SMSOutboxError.missingConcatenationReference
    }
    guard
      encodedParts.enumerated().allSatisfy({ offset, part in
        part.recipient == normalizedRecipient && part.sequence == offset + 1
          && part.totalParts == encodedParts.count
          && part.concatenationReference == encodedParts.first?.concatenationReference
      })
    else {
      throw SMSOutboxError.operation("短信编码分段不一致")
    }

    let id = UUID().uuidString.lowercased()
    try transaction {
      if let reference = encodedParts.first?.concatenationReference {
        try recordConcatenationReference(
          reference,
          recipient: normalizedRecipient,
          at: date
        )
      }
      let messageStatement = try prepare(
        """
        INSERT INTO outgoing_messages
        (id, recipient, body, concatenation_reference, state, created_at, updated_at, sent_at,
         attempt_count, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, NULL, 0, NULL);
        """)
      defer { sqlite3_finalize(messageStatement) }
      bind(id, at: 1, to: messageStatement)
      bind(normalizedRecipient, at: 2, to: messageStatement)
      bind(body, at: 3, to: messageStatement)
      if let concatenationReference = encodedParts.first?.concatenationReference {
        sqlite3_bind_int(messageStatement, 4, Int32(concatenationReference))
      } else {
        sqlite3_bind_null(messageStatement, 4)
      }
      bind(OutgoingSMSState.queued.rawValue, at: 5, to: messageStatement)
      sqlite3_bind_double(messageStatement, 6, date.timeIntervalSince1970)
      sqlite3_bind_double(messageStatement, 7, date.timeIntervalSince1970)
      guard sqlite3_step(messageStatement) == SQLITE_DONE else { throw operationError() }

      let partStatement = try prepare(
        """
        INSERT INTO outgoing_parts
        (message_id, part_index, pdu, tpdu_length, state, attempt_count, modem_reference,
         last_error, updated_at)
        VALUES (?, ?, ?, ?, ?, 0, NULL, NULL, ?);
        """)
      defer { sqlite3_finalize(partStatement) }
      for (index, part) in encodedParts.enumerated() {
        sqlite3_reset(partStatement)
        sqlite3_clear_bindings(partStatement)
        bind(id, at: 1, to: partStatement)
        sqlite3_bind_int(partStatement, 2, Int32(index))
        bind(part.pdu, at: 3, to: partStatement)
        sqlite3_bind_int(partStatement, 4, Int32(part.tpduLength))
        bind(OutgoingSMSState.queued.rawValue, at: 5, to: partStatement)
        sqlite3_bind_double(partStatement, 6, date.timeIntervalSince1970)
        guard sqlite3_step(partStatement) == SQLITE_DONE else { throw operationError() }
      }
    }
    return try requiredMessage(id: id)
  }

  func messages() throws -> [OutgoingSMS] {
    let statement = try prepare(
      """
      SELECT id, recipient, body, concatenation_reference, state, created_at, updated_at, sent_at,
             attempt_count, last_error
      FROM outgoing_messages
      ORDER BY created_at DESC, id DESC;
      """)
    defer { sqlite3_finalize(statement) }

    var messages: [OutgoingSMS] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      messages.append(try readMessage(statement))
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw operationError() }
    return messages
  }

  func message(id: String) throws -> OutgoingSMS? {
    let statement = try prepare(
      """
      SELECT id, recipient, body, concatenation_reference, state, created_at, updated_at, sent_at,
             attempt_count, last_error
      FROM outgoing_messages
      WHERE id = ?;
      """)
    defer { sqlite3_finalize(statement) }
    bind(id, at: 1, to: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW { return try readMessage(statement) }
    guard result == SQLITE_DONE else { throw operationError() }
    return nil
  }

  func nextQueued() throws -> OutgoingSMS? {
    let statement = try prepare(
      """
      SELECT id, recipient, body, concatenation_reference, state, created_at, updated_at, sent_at,
             attempt_count, last_error
      FROM outgoing_messages
      WHERE state = ?
      ORDER BY created_at ASC, id ASC
      LIMIT 1;
      """)
    defer { sqlite3_finalize(statement) }
    bind(OutgoingSMSState.queued.rawValue, at: 1, to: statement)
    let result = sqlite3_step(statement)
    if result == SQLITE_ROW { return try readMessage(statement) }
    guard result == SQLITE_DONE else { throw operationError() }
    return nil
  }

  @discardableResult
  func beginSending(id: String, at date: Date = Date()) throws -> OutgoingSMS {
    try transaction {
      let current = try requiredMessage(id: id)
      guard current.state == .queued else {
        throw SMSOutboxError.invalidTransition(from: current.state, to: .sending)
      }
      let statement = try prepare(
        """
        UPDATE outgoing_messages
        SET state = ?, updated_at = ?, attempt_count = attempt_count + 1, last_error = NULL
        WHERE id = ?;
        """)
      defer { sqlite3_finalize(statement) }
      bind(OutgoingSMSState.sending.rawValue, at: 1, to: statement)
      sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
      bind(id, at: 3, to: statement)
      guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
    }
    return try requiredMessage(id: id)
  }

  @discardableResult
  func beginPart(id: String, index: Int, at date: Date = Date()) throws -> OutgoingSMS {
    try transaction {
      let current = try requiredMessage(id: id)
      guard current.state == .sending else {
        throw SMSOutboxError.invalidTransition(from: current.state, to: .sending)
      }
      guard let part = current.parts.first(where: { $0.index == index }) else {
        throw SMSOutboxError.partNotFound(index)
      }
      guard part.state == .queued || part.state == .failed else {
        throw SMSOutboxError.invalidTransition(from: part.state, to: .sending)
      }

      let statement = try prepare(
        """
        UPDATE outgoing_parts
        SET state = ?, attempt_count = attempt_count + 1, last_error = NULL, updated_at = ?
        WHERE message_id = ? AND part_index = ?;
        """)
      defer { sqlite3_finalize(statement) }
      bind(OutgoingSMSState.sending.rawValue, at: 1, to: statement)
      sqlite3_bind_double(statement, 2, date.timeIntervalSince1970)
      bind(id, at: 3, to: statement)
      sqlite3_bind_int(statement, 4, Int32(index))
      guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
    }
    return try requiredMessage(id: id)
  }

  @discardableResult
  func markPartSent(
    id: String,
    index: Int,
    modemReference: Int? = nil,
    at date: Date = Date()
  ) throws -> OutgoingSMS {
    try transaction {
      let current = try requiredMessage(id: id)
      guard let part = current.parts.first(where: { $0.index == index }) else {
        throw SMSOutboxError.partNotFound(index)
      }
      if part.state == .sent { return }
      guard current.state == .sending, part.state == .sending else {
        throw SMSOutboxError.invalidTransition(from: part.state, to: .sent)
      }

      let partStatement = try prepare(
        """
        UPDATE outgoing_parts
        SET state = ?, modem_reference = ?, last_error = NULL, updated_at = ?
        WHERE message_id = ? AND part_index = ?;
        """)
      defer { sqlite3_finalize(partStatement) }
      bind(OutgoingSMSState.sent.rawValue, at: 1, to: partStatement)
      if let modemReference {
        sqlite3_bind_int(partStatement, 2, Int32(modemReference))
      } else {
        sqlite3_bind_null(partStatement, 2)
      }
      sqlite3_bind_double(partStatement, 3, date.timeIntervalSince1970)
      bind(id, at: 4, to: partStatement)
      sqlite3_bind_int(partStatement, 5, Int32(index))
      guard sqlite3_step(partStatement) == SQLITE_DONE else { throw operationError() }

      let remaining = try unfinishedPartCount(id: id)
      let messageStatement = try prepare(
        remaining == 0
          ? """
          UPDATE outgoing_messages
          SET state = ?, updated_at = ?, sent_at = ?, last_error = NULL
          WHERE id = ?;
          """
          : "UPDATE outgoing_messages SET updated_at = ? WHERE id = ?;"
      )
      defer { sqlite3_finalize(messageStatement) }
      if remaining == 0 {
        bind(OutgoingSMSState.sent.rawValue, at: 1, to: messageStatement)
        sqlite3_bind_double(messageStatement, 2, date.timeIntervalSince1970)
        sqlite3_bind_double(messageStatement, 3, date.timeIntervalSince1970)
        bind(id, at: 4, to: messageStatement)
      } else {
        sqlite3_bind_double(messageStatement, 1, date.timeIntervalSince1970)
        bind(id, at: 2, to: messageStatement)
      }
      guard sqlite3_step(messageStatement) == SQLITE_DONE else { throw operationError() }
    }
    return try requiredMessage(id: id)
  }

  @discardableResult
  func markFailed(id: String, error: String, at date: Date = Date()) throws -> OutgoingSMS {
    let normalizedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
    try transaction {
      let current = try requiredMessage(id: id)
      guard current.state == .queued || current.state == .sending || current.state == .failed else {
        throw SMSOutboxError.invalidTransition(from: current.state, to: .failed)
      }

      let partStatement = try prepare(
        """
        UPDATE outgoing_parts
        SET state = ?, last_error = ?, updated_at = ?
        WHERE message_id = ? AND state = ?;
        """)
      defer { sqlite3_finalize(partStatement) }
      bind(OutgoingSMSState.failed.rawValue, at: 1, to: partStatement)
      bind(normalizedError, at: 2, to: partStatement)
      sqlite3_bind_double(partStatement, 3, date.timeIntervalSince1970)
      bind(id, at: 4, to: partStatement)
      bind(OutgoingSMSState.sending.rawValue, at: 5, to: partStatement)
      guard sqlite3_step(partStatement) == SQLITE_DONE else { throw operationError() }

      let messageStatement = try prepare(
        """
        UPDATE outgoing_messages
        SET state = ?, updated_at = ?, last_error = ?
        WHERE id = ?;
        """)
      defer { sqlite3_finalize(messageStatement) }
      bind(OutgoingSMSState.failed.rawValue, at: 1, to: messageStatement)
      sqlite3_bind_double(messageStatement, 2, date.timeIntervalSince1970)
      bind(normalizedError, at: 3, to: messageStatement)
      bind(id, at: 4, to: messageStatement)
      guard sqlite3_step(messageStatement) == SQLITE_DONE else { throw operationError() }
    }
    return try requiredMessage(id: id)
  }

  @discardableResult
  func markOutcomeUnknown(id: String, error: String, at date: Date = Date()) throws -> OutgoingSMS {
    let normalizedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
    try transaction {
      let current = try requiredMessage(id: id)
      guard current.state == .sending else {
        throw SMSOutboxError.invalidTransition(from: current.state, to: .outcomeUnknown)
      }

      let partStatement = try prepare(
        """
        UPDATE outgoing_parts
        SET state = ?, last_error = ?, updated_at = ?
        WHERE message_id = ? AND state = ?;
        """)
      defer { sqlite3_finalize(partStatement) }
      bind(OutgoingSMSState.outcomeUnknown.rawValue, at: 1, to: partStatement)
      bind(normalizedError, at: 2, to: partStatement)
      sqlite3_bind_double(partStatement, 3, date.timeIntervalSince1970)
      bind(id, at: 4, to: partStatement)
      bind(OutgoingSMSState.sending.rawValue, at: 5, to: partStatement)
      guard sqlite3_step(partStatement) == SQLITE_DONE else { throw operationError() }

      let messageStatement = try prepare(
        """
        UPDATE outgoing_messages
        SET state = ?, updated_at = ?, last_error = ?
        WHERE id = ?;
        """)
      defer { sqlite3_finalize(messageStatement) }
      bind(OutgoingSMSState.outcomeUnknown.rawValue, at: 1, to: messageStatement)
      sqlite3_bind_double(messageStatement, 2, date.timeIntervalSince1970)
      bind(normalizedError, at: 3, to: messageStatement)
      bind(id, at: 4, to: messageStatement)
      guard sqlite3_step(messageStatement) == SQLITE_DONE else { throw operationError() }
    }
    return try requiredMessage(id: id)
  }

  @discardableResult
  func deferSending(id: String, error: String, at date: Date = Date()) throws -> OutgoingSMS {
    let normalizedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
    try transaction {
      let current = try requiredMessage(id: id)
      guard current.state == .sending else {
        throw SMSOutboxError.invalidTransition(from: current.state, to: .queued)
      }

      let partStatement = try prepare(
        """
        UPDATE outgoing_parts
        SET state = ?, last_error = ?, updated_at = ?
        WHERE message_id = ? AND state = ?;
        """)
      defer { sqlite3_finalize(partStatement) }
      bind(OutgoingSMSState.queued.rawValue, at: 1, to: partStatement)
      bind(normalizedError, at: 2, to: partStatement)
      sqlite3_bind_double(partStatement, 3, date.timeIntervalSince1970)
      bind(id, at: 4, to: partStatement)
      bind(OutgoingSMSState.sending.rawValue, at: 5, to: partStatement)
      guard sqlite3_step(partStatement) == SQLITE_DONE else { throw operationError() }

      let messageStatement = try prepare(
        """
        UPDATE outgoing_messages
        SET state = ?, updated_at = ?, last_error = ?
        WHERE id = ?;
        """)
      defer { sqlite3_finalize(messageStatement) }
      bind(OutgoingSMSState.queued.rawValue, at: 1, to: messageStatement)
      sqlite3_bind_double(messageStatement, 2, date.timeIntervalSince1970)
      bind(normalizedError, at: 3, to: messageStatement)
      bind(id, at: 4, to: messageStatement)
      guard sqlite3_step(messageStatement) == SQLITE_DONE else { throw operationError() }
    }
    return try requiredMessage(id: id)
  }

  @discardableResult
  func retry(id: String, at date: Date = Date()) throws -> OutgoingSMS {
    try transaction {
      let current = try requiredMessage(id: id)
      guard current.state == .failed || current.state == .outcomeUnknown else {
        throw SMSOutboxError.invalidTransition(from: current.state, to: .queued)
      }

      let partStatement = try prepare(
        """
        UPDATE outgoing_parts
        SET state = ?, last_error = NULL, updated_at = ?
        WHERE message_id = ? AND state IN (?, ?, ?);
        """)
      defer { sqlite3_finalize(partStatement) }
      bind(OutgoingSMSState.queued.rawValue, at: 1, to: partStatement)
      sqlite3_bind_double(partStatement, 2, date.timeIntervalSince1970)
      bind(id, at: 3, to: partStatement)
      bind(OutgoingSMSState.failed.rawValue, at: 4, to: partStatement)
      bind(OutgoingSMSState.sending.rawValue, at: 5, to: partStatement)
      bind(OutgoingSMSState.outcomeUnknown.rawValue, at: 6, to: partStatement)
      guard sqlite3_step(partStatement) == SQLITE_DONE else { throw operationError() }

      let messageStatement = try prepare(
        """
        UPDATE outgoing_messages
        SET state = ?, updated_at = ?, last_error = NULL
        WHERE id = ?;
        """)
      defer { sqlite3_finalize(messageStatement) }
      bind(OutgoingSMSState.queued.rawValue, at: 1, to: messageStatement)
      sqlite3_bind_double(messageStatement, 2, date.timeIntervalSince1970)
      bind(id, at: 3, to: messageStatement)
      guard sqlite3_step(messageStatement) == SQLITE_DONE else { throw operationError() }
    }
    return try requiredMessage(id: id)
  }

  func delete(id: String) throws {
    let statement = try prepare("DELETE FROM outgoing_messages WHERE id = ?;")
    defer { sqlite3_finalize(statement) }
    bind(id, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
  }

  static func defaultURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    return root.appendingPathComponent("CellularBridge", isDirectory: true).appendingPathComponent(
      "outbox.sqlite3")
  }

  private func requiredMessage(id: String) throws -> OutgoingSMS {
    guard let message = try message(id: id) else { throw SMSOutboxError.messageNotFound(id) }
    return message
  }

  private func readMessage(_ statement: OpaquePointer) throws -> OutgoingSMS {
    let id = text(statement, column: 0)
    return OutgoingSMS(
      id: id,
      recipient: text(statement, column: 1),
      body: text(statement, column: 2),
      concatenationReference: try optionalUInt8(statement, column: 3),
      state: try state(statement, column: 4),
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
      sentAt: optionalDate(statement, column: 7),
      attemptCount: Int(sqlite3_column_int(statement, 8)),
      lastError: optionalText(statement, column: 9),
      parts: try parts(messageID: id)
    )
  }

  private func parts(messageID: String) throws -> [OutgoingSMSPart] {
    let statement = try prepare(
      """
      SELECT part_index, pdu, tpdu_length, state, attempt_count, modem_reference, last_error,
             updated_at
      FROM outgoing_parts
      WHERE message_id = ?
      ORDER BY part_index ASC;
      """)
    defer { sqlite3_finalize(statement) }
    bind(messageID, at: 1, to: statement)

    var parts: [OutgoingSMSPart] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      let modemReference =
        sqlite3_column_type(statement, 5) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int(statement, 5))
      parts.append(
        OutgoingSMSPart(
          index: Int(sqlite3_column_int(statement, 0)),
          pdu: text(statement, column: 1),
          tpduLength: Int(sqlite3_column_int(statement, 2)),
          state: try state(statement, column: 3),
          attemptCount: Int(sqlite3_column_int(statement, 4)),
          modemReference: modemReference,
          lastError: optionalText(statement, column: 6),
          updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        ))
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw operationError() }
    return parts
  }

  private func unfinishedPartCount(id: String) throws -> Int {
    let statement = try prepare(
      "SELECT COUNT(*) FROM outgoing_parts WHERE message_id = ? AND state != ?;")
    defer { sqlite3_finalize(statement) }
    bind(id, at: 1, to: statement)
    bind(OutgoingSMSState.sent.rawValue, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw operationError() }
    return Int(sqlite3_column_int(statement, 0))
  }

  private func state(_ statement: OpaquePointer, column: Int32) throws -> OutgoingSMSState {
    let rawValue = text(statement, column: column)
    guard let state = OutgoingSMSState(rawValue: rawValue) else {
      throw SMSOutboxError.operation("未知发件箱状态：\(rawValue)")
    }
    return state
  }

  private func transaction(_ operation: () throws -> Void) throws {
    guard let database else { throw SMSOutboxError.operation("数据库未打开") }
    try Self.execute(database, sql: "BEGIN IMMEDIATE;")
    do {
      try operation()
      try Self.execute(database, sql: "COMMIT;")
    } catch {
      try? Self.execute(database, sql: "ROLLBACK;")
      throw error
    }
  }

  private func reserveConcatenationReference(for recipient: String, at date: Date) throws
    -> UInt8
  {
    var reservedReference: UInt8?
    try transaction {
      let cleanupStatement = try prepare(
        """
        DELETE FROM outgoing_concatenation_references
        WHERE allocated_at < ?
          AND NOT EXISTS (
            SELECT 1
            FROM outgoing_messages
            WHERE outgoing_messages.recipient = outgoing_concatenation_references.recipient
              AND outgoing_messages.concatenation_reference =
                  outgoing_concatenation_references.reference
              AND outgoing_messages.state != ?
          );
        """)
      defer { sqlite3_finalize(cleanupStatement) }
      sqlite3_bind_double(
        cleanupStatement,
        1,
        date.addingTimeInterval(-Self.concatenationReferenceReuseInterval).timeIntervalSince1970
      )
      bind(OutgoingSMSState.sent.rawValue, at: 2, to: cleanupStatement)
      guard sqlite3_step(cleanupStatement) == SQLITE_DONE else { throw operationError() }

      let statement = try prepare(
        """
        SELECT reference
        FROM outgoing_concatenation_references
        WHERE recipient = ?;
        """)
      defer { sqlite3_finalize(statement) }
      bind(recipient, at: 1, to: statement)
      var usedReferences = Set<UInt8>()
      var result = sqlite3_step(statement)
      while result == SQLITE_ROW {
        let rawValue = sqlite3_column_int(statement, 0)
        if let reference = UInt8(exactly: rawValue) {
          usedReferences.insert(reference)
        }
        result = sqlite3_step(statement)
      }
      guard result == SQLITE_DONE else { throw operationError() }

      let startingReference = UInt8.random(in: .min ... .max)
      guard
        let reference = (0..<256).lazy
          .map({ startingReference &+ UInt8(truncatingIfNeeded: $0) })
          .first(where: { !usedReferences.contains($0) })
      else {
        throw SMSOutboxError.noConcatenationReferenceAvailable
      }
      try recordConcatenationReference(reference, recipient: recipient, at: date)
      reservedReference = reference
    }
    guard let reservedReference else {
      throw SMSOutboxError.noConcatenationReferenceAvailable
    }
    return reservedReference
  }

  private func recordConcatenationReference(
    _ reference: UInt8,
    recipient: String,
    at date: Date
  ) throws {
    let statement = try prepare(
      """
      INSERT INTO outgoing_concatenation_references (recipient, reference, allocated_at)
      VALUES (?, ?, ?)
      ON CONFLICT(recipient, reference) DO UPDATE SET
          allocated_at = MAX(allocated_at, excluded.allocated_at);
      """)
    defer { sqlite3_finalize(statement) }
    bind(recipient, at: 1, to: statement)
    sqlite3_bind_int(statement, 2, Int32(reference))
    sqlite3_bind_double(statement, 3, date.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw operationError() }
  }

  private static func recoverInterruptedMessages(_ database: OpaquePointer, at date: Date) throws {
    try execute(database, sql: "BEGIN IMMEDIATE;")
    do {
      var statement: OpaquePointer?
      let unknownMessagesSQL = """
        UPDATE outgoing_messages
        SET state = ?, last_error = ?, updated_at = ?
        WHERE state = ? AND EXISTS (
          SELECT 1 FROM outgoing_parts
          WHERE outgoing_parts.message_id = outgoing_messages.id
            AND outgoing_parts.state = ?
        );
        """
      guard sqlite3_prepare_v2(database, unknownMessagesSQL, -1, &statement, nil) == SQLITE_OK,
        let unknownMessageStatement = statement
      else {
        throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
      }
      sqlite3_bind_text(
        unknownMessageStatement, 1, OutgoingSMSState.outcomeUnknown.rawValue, -1,
        transientDestructor)
      sqlite3_bind_text(
        unknownMessageStatement, 2, "发送过程被中断，结果未知", -1, transientDestructor)
      sqlite3_bind_double(unknownMessageStatement, 3, date.timeIntervalSince1970)
      sqlite3_bind_text(
        unknownMessageStatement, 4, OutgoingSMSState.sending.rawValue, -1,
        transientDestructor)
      sqlite3_bind_text(
        unknownMessageStatement, 5, OutgoingSMSState.sending.rawValue, -1,
        transientDestructor)
      guard sqlite3_step(unknownMessageStatement) == SQLITE_DONE else {
        sqlite3_finalize(unknownMessageStatement)
        throw SMSOutboxError.operation(String(cString: sqlite3_errmsg(database)))
      }
      sqlite3_finalize(unknownMessageStatement)

      statement = nil
      let partsSQL = """
        UPDATE outgoing_parts
        SET state = ?, last_error = ?, updated_at = ?
        WHERE state = ?;
        """
      guard sqlite3_prepare_v2(database, partsSQL, -1, &statement, nil) == SQLITE_OK,
        let partStatement = statement
      else {
        throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
      }
      sqlite3_bind_text(
        partStatement, 1, OutgoingSMSState.outcomeUnknown.rawValue, -1, transientDestructor)
      sqlite3_bind_text(
        partStatement, 2, "发送过程被中断，结果未知", -1, transientDestructor)
      sqlite3_bind_double(partStatement, 3, date.timeIntervalSince1970)
      sqlite3_bind_text(
        partStatement, 4, OutgoingSMSState.sending.rawValue, -1, transientDestructor)
      guard sqlite3_step(partStatement) == SQLITE_DONE else {
        sqlite3_finalize(partStatement)
        throw SMSOutboxError.operation(String(cString: sqlite3_errmsg(database)))
      }
      sqlite3_finalize(partStatement)

      statement = nil
      let deferredMessagesSQL = """
        UPDATE outgoing_messages
        SET state = ?, last_error = ?, updated_at = ?
        WHERE state = ?;
        """
      guard sqlite3_prepare_v2(database, deferredMessagesSQL, -1, &statement, nil) == SQLITE_OK,
        let deferredMessageStatement = statement
      else {
        throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
      }
      sqlite3_bind_text(
        deferredMessageStatement, 1, OutgoingSMSState.queued.rawValue, -1,
        transientDestructor)
      sqlite3_bind_text(
        deferredMessageStatement, 2, "发送已暂停，将继续未发送分段", -1,
        transientDestructor)
      sqlite3_bind_double(deferredMessageStatement, 3, date.timeIntervalSince1970)
      sqlite3_bind_text(
        deferredMessageStatement, 4, OutgoingSMSState.sending.rawValue, -1,
        transientDestructor)
      guard sqlite3_step(deferredMessageStatement) == SQLITE_DONE else {
        sqlite3_finalize(deferredMessageStatement)
        throw SMSOutboxError.operation(String(cString: sqlite3_errmsg(database)))
      }
      sqlite3_finalize(deferredMessageStatement)
      try execute(database, sql: "COMMIT;")
    } catch {
      try? execute(database, sql: "ROLLBACK;")
      throw error
    }
  }

  private static func execute(_ database: OpaquePointer, sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
      sqlite3_free(error)
      throw SMSOutboxError.operation(message)
    }
  }

  private static func addConcatenationReferenceColumnIfNeeded(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(outgoing_messages);", -1, &statement, nil)
        == SQLITE_OK,
      let statement
    else {
      throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      if let pointer = sqlite3_column_text(statement, 1),
        String(cString: pointer) == "concatenation_reference"
      {
        return
      }
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else {
      throw SMSOutboxError.operation(String(cString: sqlite3_errmsg(database)))
    }
    try execute(
      database,
      sql: "ALTER TABLE outgoing_messages ADD COLUMN concatenation_reference INTEGER;")
  }

  private static func addOutgoingPartPayloadColumnsIfNeeded(_ database: OpaquePointer) throws {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(database, "PRAGMA table_info(outgoing_parts);", -1, &statement, nil)
        == SQLITE_OK, let statement
    else {
      throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }

    var columns: Set<String> = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      if let pointer = sqlite3_column_text(statement, 1) {
        columns.insert(String(cString: pointer))
      }
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else {
      throw SMSOutboxError.operation(String(cString: sqlite3_errmsg(database)))
    }
    if !columns.contains("pdu") {
      try execute(database, sql: "ALTER TABLE outgoing_parts ADD COLUMN pdu TEXT;")
    }
    if !columns.contains("tpdu_length") {
      try execute(database, sql: "ALTER TABLE outgoing_parts ADD COLUMN tpdu_length INTEGER;")
    }
  }

  private static func backfillOutgoingPartPayloads(_ database: OpaquePointer) throws {
    typealias LegacyMessage = (
      id: String, recipient: String, body: String, reference: UInt8?, partCount: Int
    )
    var statement: OpaquePointer?
    let query = """
      SELECT m.id, m.recipient, m.body, m.concatenation_reference,
             (SELECT COUNT(*) FROM outgoing_parts p WHERE p.message_id = m.id)
      FROM outgoing_messages m
      WHERE EXISTS (
        SELECT 1 FROM outgoing_parts p
        WHERE p.message_id = m.id AND (p.pdu IS NULL OR p.tpdu_length IS NULL)
      );
      """
    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
      let queryStatement = statement
    else {
      throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
    }

    var messages: [LegacyMessage] = []
    var result = sqlite3_step(queryStatement)
    while result == SQLITE_ROW {
      guard let idPointer = sqlite3_column_text(queryStatement, 0),
        let recipientPointer = sqlite3_column_text(queryStatement, 1),
        let bodyPointer = sqlite3_column_text(queryStatement, 2)
      else {
        sqlite3_finalize(queryStatement)
        throw SMSOutboxError.operation("旧发件箱记录缺少必要字段")
      }
      let reference: UInt8?
      if sqlite3_column_type(queryStatement, 3) == SQLITE_NULL {
        reference = nil
      } else {
        guard let value = UInt8(exactly: sqlite3_column_int(queryStatement, 3)) else {
          sqlite3_finalize(queryStatement)
          throw SMSOutboxError.operation("旧发件箱记录包含无效拼接引用")
        }
        reference = value
      }
      messages.append(
        (
          String(cString: idPointer),
          String(cString: recipientPointer),
          String(cString: bodyPointer),
          reference,
          Int(sqlite3_column_int(queryStatement, 4))
        ))
      result = sqlite3_step(queryStatement)
    }
    guard result == SQLITE_DONE else {
      sqlite3_finalize(queryStatement)
      throw SMSOutboxError.operation(String(cString: sqlite3_errmsg(database)))
    }
    sqlite3_finalize(queryStatement)
    guard !messages.isEmpty else { return }

    try execute(database, sql: "BEGIN IMMEDIATE;")
    do {
      let updateSQL = """
        UPDATE outgoing_parts
        SET pdu = ?, tpdu_length = ?
        WHERE message_id = ? AND part_index = ?;
        """
      guard sqlite3_prepare_v2(database, updateSQL, -1, &statement, nil) == SQLITE_OK,
        let updateStatement = statement
      else {
        throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
      }
      defer { sqlite3_finalize(updateStatement) }

      for message in messages {
        let reference = message.reference ?? 0
        let encoded: [EncodedSMSPart]
        do {
          encoded = try SMSPDUEncoder(concatenationReferenceProvider: { reference }).encode(
            recipient: message.recipient,
            body: message.body
          )
        } catch {
          throw SMSOutboxError.operation("无法迁移旧发件箱记录：\(error.localizedDescription)")
        }
        guard encoded.count == message.partCount,
          encoded.first?.concatenationReference == message.reference
        else {
          throw SMSOutboxError.operation("旧发件箱记录的分段信息不一致")
        }
        for (index, part) in encoded.enumerated() {
          sqlite3_reset(updateStatement)
          sqlite3_clear_bindings(updateStatement)
          sqlite3_bind_text(updateStatement, 1, part.pdu, -1, transientDestructor)
          sqlite3_bind_int(updateStatement, 2, Int32(part.tpduLength))
          sqlite3_bind_text(updateStatement, 3, message.id, -1, transientDestructor)
          sqlite3_bind_int(updateStatement, 4, Int32(index))
          guard sqlite3_step(updateStatement) == SQLITE_DONE else {
            throw SMSOutboxError.operation(String(cString: sqlite3_errmsg(database)))
          }
        }
      }
      try execute(database, sql: "COMMIT;")
    } catch {
      try? execute(database, sql: "ROLLBACK;")
      throw error
    }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    guard let database else { throw SMSOutboxError.operation("数据库未打开") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw SMSOutboxError.statement(String(cString: sqlite3_errmsg(database)))
    }
    return statement
  }

  private func operationError() -> SMSOutboxError {
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
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return text(statement, column: column)
  }

  private func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
  }

  private func optionalUInt8(_ statement: OpaquePointer, column: Int32) throws -> UInt8? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    guard let value = UInt8(exactly: sqlite3_column_int(statement, column)) else {
      throw SMSOutboxError.operation("无效的长短信拼接引用")
    }
    return value
  }

  private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
