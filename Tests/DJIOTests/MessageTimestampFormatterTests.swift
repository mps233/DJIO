import Foundation
import Testing

@testable import DJIO

struct MessageTimestampFormatterTests {
  @Test func formatsTodayRecentWeekAndOlderDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
    let now = try date(2026, 7, 29, 12, 0, calendar: calendar)
    let locale = Locale(identifier: "zh_CN")

    #expect(
      MessageTimestampFormatter.string(
        for: try date(2026, 7, 29, 7, 36, calendar: calendar),
        relativeTo: now,
        calendar: calendar,
        locale: locale
      ) == "07:36")
    #expect(
      MessageTimestampFormatter.string(
        for: try date(2026, 7, 28, 9, 43, calendar: calendar),
        relativeTo: now,
        calendar: calendar,
        locale: locale
      ) == "星期二")
    #expect(
      MessageTimestampFormatter.string(
        for: try date(2026, 7, 22, 23, 59, calendar: calendar),
        relativeTo: now,
        calendar: calendar,
        locale: locale
      ) == "星期三")
    #expect(
      MessageTimestampFormatter.string(
        for: try date(2026, 7, 20, 9, 43, calendar: calendar),
        relativeTo: now,
        calendar: calendar,
        locale: locale
      ) == "2026/7/20")
    #expect(
      MessageTimestampFormatter.string(
        for: try date(2026, 7, 21, 9, 43, calendar: calendar),
        relativeTo: now,
        calendar: calendar,
        locale: locale
      ) == "2026/7/21")
    #expect(
      MessageTimestampFormatter.string(
        for: try date(2025, 12, 31, 23, 59, calendar: calendar),
        relativeTo: now,
        calendar: calendar,
        locale: locale
      ) == "2025/12/31")
  }

  private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int,
    calendar: Calendar
  ) throws -> Date {
    try #require(
      calendar.date(
        from: DateComponents(
          timeZone: calendar.timeZone,
          year: year,
          month: month,
          day: day,
          hour: hour,
          minute: minute
        )))
  }
}
