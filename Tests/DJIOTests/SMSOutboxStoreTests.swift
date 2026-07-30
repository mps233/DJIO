import Foundation
import SQLite3
import Testing

@testable import DJIO

struct SMSOutboxStoreTests {
  @Test func reservesMultipartReferencesAcrossMessagesAndRestarts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("outbox.sqlite3")
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let firstStore = try SMSOutboxStore(url: url)

    let first = try await firstStore.enqueue(
      recipient: "+86 13800138000",
      body: String(repeating: "甲", count: 71),
      at: createdAt
    )
    let second = try await firstStore.enqueue(
      recipient: "+8613800138000",
      body: String(repeating: "乙", count: 71),
      at: createdAt.addingTimeInterval(1)
    )
    let reopenedStore = try SMSOutboxStore(url: url)
    let third = try await reopenedStore.enqueue(
      recipient: "+8613800138000",
      body: String(repeating: "丙", count: 71),
      at: createdAt.addingTimeInterval(2)
    )

    let references = [
      try #require(first.concatenationReference),
      try #require(second.concatenationReference),
      try #require(third.concatenationReference),
    ]
    #expect(Set(references).count == references.count)
    #expect(first.parts.allSatisfy { !$0.pdu.isEmpty })
    #expect(second.parts.allSatisfy { !$0.pdu.isEmpty })
    #expect(third.parts.allSatisfy { !$0.pdu.isEmpty })
  }

  @Test func persistsProgressAndResumesOnlyUnsentParts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("outbox.sqlite3")
    let store = try SMSOutboxStore(url: url)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    var message = try await store.enqueue(
      recipient: " 13800138000 ",
      body: String(repeating: "你", count: 71),
      partCount: 2,
      concatenationReference: 0x7A,
      at: createdAt
    )
    #expect(message.recipient == "13800138000")
    #expect(message.state == .queued)
    #expect(message.concatenationReference == 0x7A)
    #expect(message.totalPartCount == 2)
    #expect(message.parts.allSatisfy { !$0.pdu.isEmpty && $0.tpduLength > 0 })
    #expect(message.sentPartCount == 0)
    #expect(message.progress == 0)

    message = try await store.beginSending(id: message.id, at: createdAt.addingTimeInterval(1))
    #expect(message.state == .sending)
    #expect(message.attemptCount == 1)

    message = try await store.beginPart(
      id: message.id, index: 0, at: createdAt.addingTimeInterval(2))
    #expect(message.parts[0].state == .sending)
    #expect(message.parts[0].attemptCount == 1)

    message = try await store.markPartSent(
      id: message.id,
      index: 0,
      modemReference: 41,
      at: createdAt.addingTimeInterval(3)
    )
    #expect(message.state == .sending)
    #expect(message.sentPartCount == 1)
    #expect(message.progress == 0.5)
    #expect(message.parts[0].modemReference == 41)

    message = try await store.beginPart(
      id: message.id, index: 1, at: createdAt.addingTimeInterval(4))
    message = try await store.markFailed(
      id: message.id, error: "网络拒绝", at: createdAt.addingTimeInterval(5))
    #expect(message.state == .failed)
    #expect(message.lastError == "网络拒绝")
    #expect(message.parts[0].state == .sent)
    #expect(message.parts[1].state == .failed)

    message = try await store.retry(id: message.id, at: createdAt.addingTimeInterval(6))
    #expect(message.state == .queued)
    #expect(message.lastError == nil)
    #expect(message.parts[0].state == .sent)
    #expect(message.parts[1].state == .queued)
    #expect(message.pendingPartIndexes == [1])

    message = try await store.beginSending(id: message.id, at: createdAt.addingTimeInterval(7))
    message = try await store.beginPart(
      id: message.id, index: 1, at: createdAt.addingTimeInterval(8))
    message = try await store.markPartSent(
      id: message.id,
      index: 1,
      modemReference: 42,
      at: createdAt.addingTimeInterval(9)
    )
    #expect(message.state == .sent)
    #expect(message.attemptCount == 2)
    #expect(message.sentPartCount == 2)
    #expect(message.progress == 1)
    #expect(message.sentAt == createdAt.addingTimeInterval(9))

    let reopened = try SMSOutboxStore(url: url)
    let persisted = try #require(await reopened.message(id: message.id))
    #expect(persisted == message)
  }

  @Test func startupMarksInterruptedMessageOutcomeUnknownWithoutAutomaticRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("outbox.sqlite3")
    let firstStore = try SMSOutboxStore(url: url)

    var message = try await firstStore.enqueue(
      recipient: "10086",
      body: String(repeating: "中", count: 71),
      partCount: 2,
      concatenationReference: 0x32)
    message = try await firstStore.beginSending(id: message.id)
    message = try await firstStore.beginPart(id: message.id, index: 0)
    #expect(message.state == .sending)
    #expect(message.parts[0].state == .sending)

    let recoveredStore = try SMSOutboxStore(url: url)
    let recovered = try #require(await recoveredStore.message(id: message.id))
    #expect(recovered.state == .outcomeUnknown)
    #expect(recovered.parts[0].state == .outcomeUnknown)
    #expect(recovered.lastError == "发送过程被中断，结果未知")
    #expect(recovered.parts[0].attemptCount == 1)
    #expect(recovered.attemptCount == 1)
    #expect(try await recoveredStore.nextQueued() == nil)

    let retried = try await recoveredStore.retry(id: message.id)
    #expect(retried.state == .queued)
    #expect(retried.parts[0].state == .queued)
  }

  @Test func recordsUnknownOutcomeSeparatelyFromDefiniteFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SMSOutboxStore(url: root.appendingPathComponent("outbox.sqlite3"))
    var message = try await store.enqueue(recipient: "10086", body: "状态未知", partCount: 1)
    message = try await store.beginSending(id: message.id)
    message = try await store.beginPart(id: message.id, index: 0)

    message = try await store.markOutcomeUnknown(id: message.id, error: "回执超时")

    #expect(message.state == .outcomeUnknown)
    #expect(message.parts[0].state == .outcomeUnknown)
    #expect(message.lastError == "回执超时")
    #expect(try await store.nextQueued() == nil)
  }

  @Test func startupSafelyResumesBetweenPartsUsingPersistedPDUs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("outbox.sqlite3")
    let firstStore = try SMSOutboxStore(url: url)

    var message = try await firstStore.enqueue(
      recipient: "10086",
      body: String(repeating: "续", count: 71),
      partCount: 2,
      concatenationReference: 0x39)
    let originalPDUs = message.parts.map(\.pdu)
    message = try await firstStore.beginSending(id: message.id)
    message = try await firstStore.beginPart(id: message.id, index: 0)
    message = try await firstStore.markPartSent(id: message.id, index: 0, modemReference: 21)
    #expect(message.state == .sending)
    #expect(message.parts[1].state == .queued)

    let recoveredStore = try SMSOutboxStore(url: url)
    let recovered = try #require(await recoveredStore.message(id: message.id))
    #expect(recovered.state == .queued)
    #expect(recovered.parts.map(\.pdu) == originalPDUs)
    #expect(recovered.parts[0].state == .sent)
    #expect(recovered.parts[1].state == .queued)
    #expect(recovered.pendingPartIndexes == [1])
  }

  @Test func backfillsMissingPayloadsFromLegacyOutboxRows() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("outbox.sqlite3")
    let firstStore = try SMSOutboxStore(url: url)
    let original = try await firstStore.enqueue(
      recipient: "10086",
      body: String(repeating: "旧", count: 71),
      partCount: 2,
      concatenationReference: 0x47)
    let originalPDUs = original.parts.map(\.pdu)
    let originalTPDULengths = original.parts.map(\.tpduLength)

    var database: OpaquePointer?
    #expect(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    let handle = try #require(database)
    #expect(
      sqlite3_exec(handle, "UPDATE outgoing_parts SET pdu=NULL, tpdu_length=NULL;", nil, nil, nil)
        == SQLITE_OK)
    sqlite3_close(handle)

    let migratedStore = try SMSOutboxStore(url: url)
    let migrated = try #require(await migratedStore.message(id: original.id))
    #expect(migrated.parts.map(\.pdu) == originalPDUs)
    #expect(migrated.parts.map(\.tpduLength) == originalTPDULengths)
  }

  @Test func defersSafeTransportFailuresWithoutResendingCompletedParts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SMSOutboxStore(url: root.appendingPathComponent("outbox.sqlite3"))
    var message = try await store.enqueue(
      recipient: "10086",
      body: String(repeating: "等", count: 71),
      partCount: 2,
      concatenationReference: 0x28)
    message = try await store.beginSending(id: message.id)
    message = try await store.beginPart(id: message.id, index: 0)
    message = try await store.markPartSent(id: message.id, index: 0, modemReference: 42)
    message = try await store.beginPart(id: message.id, index: 1)

    message = try await store.deferSending(id: message.id, error: "AT 控制通道已断开")

    #expect(message.state == .queued)
    #expect(message.lastError == "AT 控制通道已断开")
    #expect(message.parts[0].state == .sent)
    #expect(message.parts[0].modemReference == 42)
    #expect(message.parts[1].state == .queued)
    #expect(message.pendingPartIndexes == [1])
    #expect(try await store.nextQueued()?.id == message.id)
  }

  @Test func rejectsInvalidStateTransitionsAndInputs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SMSOutboxStore(url: root.appendingPathComponent("outbox.sqlite3"))

    await #expect(throws: SMSOutboxError.invalidRecipient) {
      try await store.enqueue(recipient: "  ", body: "内容", partCount: 1)
    }
    await #expect(throws: SMSOutboxError.emptyBody) {
      try await store.enqueue(recipient: "10086", body: "", partCount: 1)
    }
    await #expect(throws: SMSOutboxError.invalidPartCount) {
      try await store.enqueue(recipient: "10086", body: "内容", partCount: 0)
    }
    await #expect(throws: SMSOutboxError.missingConcatenationReference) {
      try await store.enqueue(recipient: "10086", body: "长短信", partCount: 2)
    }

    let message = try await store.enqueue(recipient: "10086", body: "内容", partCount: 1)
    await #expect(
      throws: SMSOutboxError.invalidTransition(from: .queued, to: .sent)
    ) {
      try await store.markPartSent(id: message.id, index: 0)
    }
    try await store.delete(id: message.id)
    #expect(try await store.message(id: message.id) == nil)
  }
}
