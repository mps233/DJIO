import Foundation
import Testing

@testable import CellularBridge

struct TrafficUsageTrackerTests {
  @Test func firstSampleOnlyEstablishesBaseline() {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = date(2026, 7, 29, 10, 0, 0)
    var tracker = makeTracker(storageURL: root.appendingPathComponent("usage.json"), now: now)

    let first = tracker.sample(
      interfaceName: "en9",
      counters: counters(index: 40, received: 8_000_000_000, sent: 3_000_000_000),
      at: now
    )
    #expect(first.session == .zero)
    #expect(first.today == .zero)
    #expect(first.month == .zero)

    let second = tracker.sample(
      interfaceName: "en9",
      counters: counters(index: 40, received: 8_000_000_800, sent: 3_000_000_250),
      at: now.addingTimeInterval(1)
    )
    let expected = TrafficUsageTotals(receivedBytes: 800, sentBytes: 250)
    #expect(second.session == expected)
    #expect(second.today == expected)
    #expect(second.month == expected)
  }

  @Test func interfaceChangesAndCounterRollbacksOnlyReplaceTheBaseline() {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = date(2026, 7, 29, 10, 0, 0)
    var tracker = makeTracker(storageURL: root.appendingPathComponent("usage.json"), now: now)
    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 100, sent: 100), at: now)
    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 150, sent: 120),
      at: now.addingTimeInterval(1))

    let switched = tracker.sample(
      interfaceName: "en10", counters: counters(index: 41, received: 9_000, sent: 8_000),
      at: now.addingTimeInterval(2))
    #expect(switched.session == TrafficUsageTotals(receivedBytes: 50, sentBytes: 20))

    let afterSwitch = tracker.sample(
      interfaceName: "en10", counters: counters(index: 41, received: 9_030, sent: 8_040),
      at: now.addingTimeInterval(3))
    #expect(afterSwitch.session == TrafficUsageTotals(receivedBytes: 80, sentBytes: 60))

    let rolledBack = tracker.sample(
      interfaceName: "en10", counters: counters(index: 41, received: 20, sent: 10),
      at: now.addingTimeInterval(4))
    #expect(rolledBack.session == TrafficUsageTotals(receivedBytes: 80, sentBytes: 60))

    let recovered = tracker.sample(
      interfaceName: "en10", counters: counters(index: 41, received: 25, sent: 17),
      at: now.addingTimeInterval(5))
    #expect(recovered.session == TrafficUsageTotals(receivedBytes: 85, sentBytes: 67))
  }

  @Test func missingSamplesAndLongSuspensionDoNotCreateTraffic() {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = date(2026, 7, 29, 10, 0, 0)
    var tracker = makeTracker(storageURL: root.appendingPathComponent("usage.json"), now: now)
    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 100, sent: 200), at: now)
    _ = tracker.sample(
      interfaceName: nil, counters: nil, at: now.addingTimeInterval(1))

    let reconnected = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 10_000, sent: 20_000),
      at: now.addingTimeInterval(2))
    #expect(reconnected.session == .zero)

    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 10_100, sent: 20_050),
      at: now.addingTimeInterval(3))
    let afterSleep = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 90_000, sent: 70_000),
      at: now.addingTimeInterval(30))
    #expect(afterSleep.session == TrafficUsageTotals(receivedBytes: 100, sentBytes: 50))

    let resumed = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 90_010, sent: 70_020),
      at: now.addingTimeInterval(31))
    #expect(resumed.session == TrafficUsageTotals(receivedBytes: 110, sentBytes: 70))
  }

  @Test func dayAndMonthBoundariesResetOnlyTheirOwnPeriods() {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let july30 = date(2026, 7, 30, 23, 59, 58)
    var tracker = makeTracker(storageURL: root.appendingPathComponent("usage.json"), now: july30)
    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 100, sent: 100), at: july30)
    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 130, sent: 120),
      at: july30.addingTimeInterval(1))

    let july31 = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 140, sent: 125),
      at: july30.addingTimeInterval(2))
    #expect(july31.session == TrafficUsageTotals(receivedBytes: 40, sentBytes: 25))
    #expect(july31.today == TrafficUsageTotals(receivedBytes: 10, sentBytes: 5))
    #expect(july31.month == TrafficUsageTotals(receivedBytes: 40, sentBytes: 25))

    let august1 = date(2026, 8, 1, 0, 0, 0)
    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 200, sent: 200),
      at: august1.addingTimeInterval(-1))
    let august = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 215, sent: 209), at: august1)
    #expect(august.session == TrafficUsageTotals(receivedBytes: 55, sentBytes: 34))
    #expect(august.today == TrafficUsageTotals(receivedBytes: 15, sentBytes: 9))
    #expect(august.month == TrafficUsageTotals(receivedBytes: 15, sentBytes: 9))
  }

  @Test func restoresDailyAndMonthlyTotalsButNotTheSession() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storageURL = root.appendingPathComponent("nested/traffic-usage.json")
    let now = date(2026, 7, 29, 10, 0, 0)

    var first = makeTracker(storageURL: storageURL, now: now, autosaveInterval: 0)
    _ = first.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 1_000, sent: 2_000), at: now)
    _ = first.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 1_300, sent: 2_100),
      at: now.addingTimeInterval(1))

    let persistedData = try Data(contentsOf: storageURL)
    #expect(!persistedData.isEmpty)

    let restored = makeTracker(storageURL: storageURL, now: now.addingTimeInterval(2))
    #expect(restored.snapshot.session == .zero)
    #expect(restored.snapshot.today == TrafficUsageTotals(receivedBytes: 300, sentBytes: 100))
    #expect(restored.snapshot.month == TrafficUsageTotals(receivedBytes: 300, sentBytes: 100))
  }

  @Test func loadingOnANewDayKeepsOnlyTheCurrentMonth() {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storageURL = root.appendingPathComponent("traffic-usage.json")
    let july29 = date(2026, 7, 29, 23, 59, 58)

    var first = makeTracker(storageURL: storageURL, now: july29, autosaveInterval: 0)
    _ = first.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 100, sent: 100), at: july29)
    _ = first.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 170, sent: 130),
      at: july29.addingTimeInterval(1))

    let nextDay = makeTracker(
      storageURL: storageURL, now: date(2026, 7, 30, 8, 0, 0), autosaveInterval: 0)
    #expect(nextDay.snapshot.today == .zero)
    #expect(nextDay.snapshot.month == TrafficUsageTotals(receivedBytes: 70, sentBytes: 30))

    let nextMonth = makeTracker(
      storageURL: storageURL, now: date(2026, 8, 1, 8, 0, 0), autosaveInterval: 0)
    #expect(nextMonth.snapshot.today == .zero)
    #expect(nextMonth.snapshot.month == .zero)
  }

  @Test func injectedClockIsUsedWhenNoSampleDateIsProvided() {
    final class Clock {
      var now: Date

      init(now: Date) {
        self.now = now
      }
    }

    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = Clock(now: date(2026, 7, 29, 10, 0, 0))
    var tracker = makeTracker(
      storageURL: root.appendingPathComponent("usage.json"),
      now: clock.now,
      nowProvider: { clock.now }
    )
    _ = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 100, sent: 100))
    clock.now = clock.now.addingTimeInterval(1)
    let result = tracker.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 130, sent: 120))

    #expect(result.session == TrafficUsageTotals(receivedBytes: 30, sentBytes: 20))
  }

  @Test func exposesPersistenceFailuresAndKeepsTotalsInMemory() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let blockedParent = root.appendingPathComponent("not-a-directory")
    try Data("blocked".utf8).write(to: blockedParent)
    let now = date(2026, 7, 29, 10, 0, 0)
    var tracker = makeTracker(
      storageURL: blockedParent.appendingPathComponent("usage.json"),
      now: now,
      autosaveInterval: 0
    )
    _ = tracker.sample(
      interfaceName: "en9",
      counters: counters(index: 40, received: 1_000, sent: 2_000),
      at: now
    )

    let result = tracker.sample(
      interfaceName: "en9",
      counters: counters(index: 40, received: 1_300, sent: 2_100),
      at: now.addingTimeInterval(1)
    )

    #expect(result.today == TrafficUsageTotals(receivedBytes: 300, sentBytes: 100))
    #expect(tracker.persistenceIssue?.contains("无法保存流量统计") == true)
  }

  private func makeTracker(
    storageURL: URL,
    now: Date,
    autosaveInterval: TimeInterval = 30,
    nowProvider: (() -> Date)? = nil
  ) -> TrafficUsageTracker {
    TrafficUsageTracker(
      storageURL: storageURL,
      calendar: utcCalendar,
      maximumSampleInterval: 5,
      autosaveInterval: autosaveInterval,
      now: nowProvider ?? { now }
    )
  }

  private func counters(index: UInt32, received: UInt64, sent: UInt64)
    -> InterfaceTrafficCounters
  {
    InterfaceTrafficCounters(interfaceIndex: index, receivedBytes: received, sentBytes: sent)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "CellularBridge-TrafficUsageTrackerTests-\(UUID().uuidString)", isDirectory: true)
  }

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    _ second: Int
  ) -> Date {
    utcCalendar.date(
      from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
      ))!
  }
}
