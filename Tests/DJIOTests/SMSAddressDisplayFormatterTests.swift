import Testing

@testable import DJIO

struct SMSAddressDisplayFormatterTests {
  @Test func groupsMainlandMobileNumbers() {
    #expect(SMSAddressDisplayFormatter.string(for: "+8615612345678") == "+86 156 1234 5678")
    #expect(SMSAddressDisplayFormatter.string(for: "+8613912345678") == "+86 139 1234 5678")
  }

  @Test func preservesShortCodesAndUnsupportedAddresses() {
    #expect(SMSAddressDisplayFormatter.string(for: "10086") == "10086")
    #expect(SMSAddressDisplayFormatter.string(for: "10690000") == "10690000")
    #expect(SMSAddressDisplayFormatter.string(for: "+1234") == "+1234")
    #expect(SMSAddressDisplayFormatter.string(for: "+861561234567") == "+861561234567")
    #expect(SMSAddressDisplayFormatter.string(for: "+8621123456789") == "+8621123456789")
    #expect(
      SMSAddressDisplayFormatter.string(for: "+86 156 1234 5678") == "+86 156 1234 5678")
  }
}
