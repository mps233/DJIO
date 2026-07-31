import Foundation

enum SMSAddressDisplayFormatter {
  static func string(for address: String) -> String {
    let prefix: String
    let localNumber: Substring
    if address.hasPrefix("+86") {
      prefix = "+86 "
      localNumber = address.dropFirst(3)
    } else {
      prefix = ""
      localNumber = address[...]
    }
    guard localNumber.count == 11, localNumber.first == "1",
      localNumber.allSatisfy(isASCIIDigit)
    else {
      return address
    }

    let firstBreak = localNumber.index(localNumber.startIndex, offsetBy: 3)
    let secondBreak = localNumber.index(firstBreak, offsetBy: 4)
    let firstGroup = localNumber[..<firstBreak]
    let secondGroup = localNumber[firstBreak..<secondBreak]
    let thirdGroup = localNumber[secondBreak...]
    return "\(prefix)\(firstGroup) \(secondGroup) \(thirdGroup)"
  }

  private static func isASCIIDigit(_ character: Character) -> Bool {
    character.unicodeScalars.count == 1
      && character.unicodeScalars.first.map { (48...57).contains($0.value) } == true
  }
}
