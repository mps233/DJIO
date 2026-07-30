import Foundation
import Testing

@testable import DJIO

struct CallHistoryStoreTests {
  @Test func persistsAndInsertsIdempotently() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CallHistoryStore(url: databaseURL)
    let call = IncomingCallRecord(
      id: "stable-id",
      callerNumber: "+8613800138000",
      receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(try await store.insert(call))
    #expect(
      try await !store.insert(
        IncomingCallRecord(
          id: call.id,
          callerNumber: "10000",
          receivedAt: call.receivedAt.addingTimeInterval(60)
        )))

    let reopened = try CallHistoryStore(url: databaseURL)
    #expect(try await reopened.allCalls() == [call])
  }

  @Test func ordersByReceiptTimeThenIDDescending() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CallHistoryStore(url: databaseURL)
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let calls = [
      IncomingCallRecord(
        id: "older-z", callerNumber: "10000", receivedAt: timestamp.addingTimeInterval(-60)),
      IncomingCallRecord(id: "same-a", callerNumber: nil, receivedAt: timestamp),
      IncomingCallRecord(id: "same-b", callerNumber: "10086", receivedAt: timestamp),
    ]

    for call in calls {
      #expect(try await store.insert(call))
    }

    #expect(try await store.allCalls().map(\.id) == ["same-b", "same-a", "older-z"])
    #expect(try await store.allCalls().first(where: { $0.id == "same-a" })?.callerNumber == nil)
  }

  @Test func deletesOnlyTheRequestedCall() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CallHistoryStore(url: databaseURL)
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let first = IncomingCallRecord(id: "first", callerNumber: "10000", receivedAt: timestamp)
    let second = IncomingCallRecord(
      id: "second", callerNumber: "10086", receivedAt: timestamp.addingTimeInterval(1))

    #expect(try await store.insert(first))
    #expect(try await store.insert(second))
    try await store.delete(id: first.id)
    try await store.delete(id: "missing")

    #expect(try await store.allCalls() == [second])
    let reopened = try CallHistoryStore(url: databaseURL)
    #expect(try await reopened.allCalls() == [second])
  }

  @Test func updatesAnUnknownCallerWithoutAllowingEmptyValuesToOverwriteIt() async throws {
    let (root, databaseURL) = temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CallHistoryStore(url: databaseURL)
    let call = IncomingCallRecord(
      id: "unknown-caller",
      callerNumber: nil,
      receivedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(try await store.insert(call))
    try await store.updateCallerNumber(id: call.id, callerNumber: "+8613800138000")
    try await store.updateCallerNumber(id: call.id, callerNumber: nil)
    try await store.updateCallerNumber(id: call.id, callerNumber: "  ")

    let reopened = try CallHistoryStore(url: databaseURL)
    #expect(try await reopened.allCalls().first?.callerNumber == "+8613800138000")
  }

  private func temporaryDatabase() -> (root: URL, databaseURL: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    return (root, root.appendingPathComponent("calls.sqlite3"))
  }
}
