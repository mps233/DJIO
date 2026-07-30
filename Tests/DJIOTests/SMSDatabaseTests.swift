import Foundation
import Testing

@testable import DJIO

struct SMSDatabaseTests {
  @Test func persistsDeduplicatesMarksAndDeletes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("messages.sqlite3")
    let database = try SMSDatabase(url: databaseURL)
    let message = SMSMessage(
      id: "stable-id",
      sender: "10086",
      body: "测试短信",
      receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
      serviceCenterAt: Date(timeIntervalSince1970: 1_699_999_990),
      usesMacTimestamp: true,
      storage: "ME",
      modemIndex: 3,
      rawPDU: "00AA",
      isRead: false
    )

    #expect(try await database.insert(message))
    #expect(try await !database.insert(message))
    let stored = try await database.allMessages()
    #expect(stored.count == 1)
    #expect(stored.first?.receivedAt == message.receivedAt)
    #expect(stored.first?.serviceCenterAt == message.serviceCenterAt)
    #expect(stored.first?.usesMacTimestamp == true)
    #expect(stored.first?.timelineAt == message.receivedAt)
    #expect(try await database.knownImportedPDUs(["00aa", "00BB"]) == ["00AA"])

    try await database.markRead(id: message.id)
    #expect(try await database.allMessages().first?.isRead == true)

    try await database.delete(id: message.id)
    #expect(try await database.allMessages().isEmpty)
    #expect(try await !database.insert(message))
    #expect(try await database.allMessages().isEmpty)

    let reopened = try SMSDatabase(url: databaseURL)
    #expect(try await !reopened.insert(message))
    #expect(try await reopened.allMessages().isEmpty)
  }

  @Test func ordersByMacReceiptInsteadOfServiceCenterTimestamp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SMSDatabase(url: root.appendingPathComponent("messages.sqlite3"))
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let arrivedFirst = SMSMessage(
      id: "arrived-first", sender: "10000", body: "先到",
      receivedAt: base,
      serviceCenterAt: base.addingTimeInterval(120),
      usesMacTimestamp: true,
      storage: "ME", modemIndex: 1, rawPDU: "00AA", isRead: false)
    let arrivedSecond = SMSMessage(
      id: "arrived-second", sender: "10001", body: "后到",
      receivedAt: base.addingTimeInterval(60),
      serviceCenterAt: base.addingTimeInterval(30),
      usesMacTimestamp: true,
      storage: "ME", modemIndex: 2, rawPDU: "00BB", isRead: false)

    #expect(try await database.insert(arrivedFirst))
    #expect(try await database.insert(arrivedSecond))
    #expect(try await database.allMessages().map(\.id) == ["arrived-second", "arrived-first"])
  }

  @Test func historicalImportKeepsServiceCenterTimeOnTheTimeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SMSDatabase(url: root.appendingPathComponent("messages.sqlite3"))
    let serviceCenterAt = Date(timeIntervalSince1970: 1_700_000_000)
    let message = SMSMessage(
      id: "historical", sender: "10000", body: "历史短信",
      receivedAt: serviceCenterAt.addingTimeInterval(86_400),
      serviceCenterAt: serviceCenterAt,
      usesMacTimestamp: false,
      storage: "ME", modemIndex: 1, rawPDU: "00CC", isRead: false)

    #expect(try await database.insert(message))
    #expect(try await database.allMessages().first?.timelineAt == serviceCenterAt)
  }
}
