import Foundation

enum MessageTimestampFormatter {
  static func string(
    for date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
      let components = calendar.dateComponents([.hour, .minute], from: date)
      guard let hour = components.hour, let minute = components.minute else { return "" }
      return String(format: "%02d:%02d", hour, minute)
    }

    let dayDistance = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: date),
      to: calendar.startOfDay(for: now)
    ).day
    if let dayDistance, (1...7).contains(dayDistance) {
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.calendar = calendar
      formatter.timeZone = calendar.timeZone
      formatter.setLocalizedDateFormatFromTemplate("EEEE")
      return formatter.string(from: date)
    }

    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }
}
