import Foundation

enum SMSAddressDisplayFormatter {
  static func string(for address: String) -> String {
    guard address.hasPrefix("+86") else { return address }
    let localNumber = address.dropFirst(3)
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
    return "+86 \(firstGroup) \(secondGroup) \(thirdGroup)"
  }

  private static func isASCIIDigit(_ character: Character) -> Bool {
    character.unicodeScalars.count == 1
      && character.unicodeScalars.first.map { (48...57).contains($0.value) } == true
  }
}
