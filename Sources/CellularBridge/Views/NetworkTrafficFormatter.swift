import Foundation

enum NetworkTrafficFormatter {
  static func rate(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "--" }
    return value(bytesPerSecond) + "/s"
  }

  static func byteCount(_ bytes: UInt64?) -> String {
    guard let bytes else { return "--" }
    return value(Double(bytes))
  }

  private static func value(_ bytes: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var amount = max(0, bytes)
    var unitIndex = 0
    while amount >= 1_000, unitIndex < units.count - 1 {
      amount /= 1_000
      unitIndex += 1
    }

    let number: String
    if unitIndex == 0 || amount >= 100 {
      number = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), amount)
    } else if amount >= 10 {
      number = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), amount)
    } else {
      number = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }
    return "\(number) \(units[unitIndex])"
  }
}
