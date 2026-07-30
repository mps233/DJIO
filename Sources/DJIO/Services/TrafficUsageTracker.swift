import Foundation

struct TrafficUsageTotals: Codable, Sendable, Equatable {
  var receivedBytes: UInt64 = 0
  var sentBytes: UInt64 = 0

  static let zero = TrafficUsageTotals()
}

struct TrafficUsageSnapshot: Sendable, Equatable {
  let session: TrafficUsageTotals
  let today: TrafficUsageTotals
  let month: TrafficUsageTotals
  let dayStartedAt: Date
  let monthStartedAt: Date
}

struct TrafficUsageTracker {
  private static let persistenceVersion = 1

  private let storageURL: URL
  private let calendar: Calendar
  private let maximumSampleInterval: TimeInterval
  private let autosaveInterval: TimeInterval
  private let now: () -> Date

  private var previousSample: Sample?
  private var sessionTotals = TrafficUsageTotals.zero
  private var todayTotals = TrafficUsageTotals.zero
  private var monthTotals = TrafficUsageTotals.zero
  private var dayStartedAt: Date
  private var monthStartedAt: Date
  private var needsPersistence = false
  private var lastSavedAt: Date?

  private(set) var persistenceIssue: String?

  init(
    storageURL: URL = TrafficUsageTracker.defaultStorageURL(),
    calendar: Calendar = .current,
    maximumSampleInterval: TimeInterval = 5,
    autosaveInterval: TimeInterval = 30,
    now: @escaping () -> Date = Date.init
  ) {
    self.storageURL = storageURL
    self.calendar = calendar
    self.maximumSampleInterval = max(0, maximumSampleInterval)
    self.autosaveInterval = max(0, autosaveInterval)
    self.now = now

    let currentDate = now()
    dayStartedAt = calendar.startOfDay(for: currentDate)
    monthStartedAt = Self.startOfMonth(containing: currentDate, calendar: calendar)

    do {
      guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
      let data = try Data(contentsOf: storageURL)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      let persisted = try decoder.decode(PersistedUsage.self, from: data)
      guard persisted.version == Self.persistenceVersion else {
        persistenceIssue = "无法读取较新版本的流量统计文件"
        return
      }

      if calendar.isDate(persisted.monthStartedAt, equalTo: currentDate, toGranularity: .month) {
        monthTotals = persisted.month
        if calendar.isDate(persisted.dayStartedAt, inSameDayAs: currentDate) {
          todayTotals = persisted.today
        } else {
          needsPersistence = true
        }
      } else {
        needsPersistence = true
      }
    } catch {
      persistenceIssue = "无法读取流量统计：\(error.localizedDescription)"
    }
  }

  var snapshot: TrafficUsageSnapshot {
    TrafficUsageSnapshot(
      session: sessionTotals,
      today: todayTotals,
      month: monthTotals,
      dayStartedAt: dayStartedAt,
      monthStartedAt: monthStartedAt
    )
  }

  @discardableResult
  mutating func sample(
    interfaceName: String?,
    counters: InterfaceTrafficCounters?,
    at sampledAt: Date? = nil
  ) -> TrafficUsageSnapshot {
    let sampledAt = sampledAt ?? now()
    let periodChanged = updatePeriods(for: sampledAt)

    guard let interfaceName, let counters else {
      previousSample = nil
      persistIfNeeded(at: sampledAt, force: periodChanged)
      return snapshot
    }

    let current = Sample(
      interfaceName: interfaceName,
      counters: counters,
      sampledAt: sampledAt
    )
    defer { previousSample = current }

    guard
      let previousSample,
      previousSample.interfaceName == interfaceName,
      previousSample.counters.interfaceIndex == counters.interfaceIndex
    else {
      persistIfNeeded(at: sampledAt, force: periodChanged)
      return snapshot
    }

    let interval = sampledAt.timeIntervalSince(previousSample.sampledAt)
    guard interval > 0, interval <= maximumSampleInterval else {
      persistIfNeeded(at: sampledAt, force: periodChanged)
      return snapshot
    }
    guard
      counters.receivedBytes >= previousSample.counters.receivedBytes,
      counters.sentBytes >= previousSample.counters.sentBytes
    else {
      persistIfNeeded(at: sampledAt, force: periodChanged)
      return snapshot
    }

    let delta = TrafficUsageTotals(
      receivedBytes: counters.receivedBytes - previousSample.counters.receivedBytes,
      sentBytes: counters.sentBytes - previousSample.counters.sentBytes
    )
    sessionTotals.add(delta)
    todayTotals.add(delta)
    monthTotals.add(delta)
    needsPersistence = true
    persistIfNeeded(at: sampledAt, force: periodChanged)
    return snapshot
  }

  @discardableResult
  mutating func resetSession() -> TrafficUsageSnapshot {
    sessionTotals = .zero
    return snapshot
  }

  mutating func flush() throws {
    let persisted = PersistedUsage(
      version: Self.persistenceVersion,
      dayStartedAt: dayStartedAt,
      monthStartedAt: monthStartedAt,
      today: todayTotals,
      month: monthTotals
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(persisted)

    do {
      let parent = storageURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      try data.write(to: storageURL, options: .atomic)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: storageURL.path
      )
      needsPersistence = false
      persistenceIssue = nil
      lastSavedAt = now()
    } catch {
      persistenceIssue = "无法保存流量统计：\(error.localizedDescription)"
      throw error
    }
  }

  static func defaultStorageURL() -> URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first!
    return root.appendingPathComponent("CellularBridge", isDirectory: true)
      .appendingPathComponent("traffic-usage.json")
  }

  private mutating func updatePeriods(for date: Date) -> Bool {
    let currentDayStart = calendar.startOfDay(for: date)
    let currentMonthStart = Self.startOfMonth(containing: date, calendar: calendar)
    var changed = false

    if !calendar.isDate(monthStartedAt, equalTo: date, toGranularity: .month) {
      monthStartedAt = currentMonthStart
      monthTotals = .zero
      changed = true
    }
    if !calendar.isDate(dayStartedAt, inSameDayAs: date) {
      dayStartedAt = currentDayStart
      todayTotals = .zero
      changed = true
    }
    if changed { needsPersistence = true }
    return changed
  }

  private mutating func persistIfNeeded(at date: Date, force: Bool) {
    guard needsPersistence else { return }
    let shouldSave: Bool
    if force || autosaveInterval == 0 || lastSavedAt == nil {
      shouldSave = true
    } else if let lastSavedAt {
      let elapsed = date.timeIntervalSince(lastSavedAt)
      shouldSave = elapsed < 0 || elapsed >= autosaveInterval
    } else {
      shouldSave = true
    }
    guard shouldSave else { return }

    do {
      try flush()
      lastSavedAt = date
    } catch {
      // Keep the in-memory totals and retry on a later sample.
    }
  }

  private static func startOfMonth(containing date: Date, calendar: Calendar) -> Date {
    let components = calendar.dateComponents([.year, .month], from: date)
    return calendar.date(from: components) ?? calendar.startOfDay(for: date)
  }

  private struct Sample {
    let interfaceName: String
    let counters: InterfaceTrafficCounters
    let sampledAt: Date
  }

  private struct PersistedUsage: Codable {
    let version: Int
    let dayStartedAt: Date
    let monthStartedAt: Date
    let today: TrafficUsageTotals
    let month: TrafficUsageTotals
  }
}

extension TrafficUsageTotals {
  fileprivate mutating func add(_ other: TrafficUsageTotals) {
    receivedBytes = Self.saturatingAdd(receivedBytes, other.receivedBytes)
    sentBytes = Self.saturatingAdd(sentBytes, other.sentBytes)
  }

  private static func saturatingAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
    let (result, overflow) = left.addingReportingOverflow(right)
    return overflow ? .max : result
  }
}
