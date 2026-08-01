import Foundation
import CoreGraphics
import Testing

@testable import DJIO

struct EuiccTests {
  @Test func parsesStandardActivationCode() throws {
    let code = try EuiccActivationCode("LPA:1$smdp.example.com$MATCH-123")
    #expect(code.smdpAddress == "smdp.example.com")
    #expect(code.matchingID == "MATCH-123")
    #expect(code.rawValue == "LPA:1$smdp.example.com$MATCH-123")
  }

  @Test func trimsActivationCodeWhitespace() throws {
    let code = try EuiccActivationCode("  LPA:1$smdp.example.com$MATCH-123\n")
    #expect(code.rawValue == "LPA:1$smdp.example.com$MATCH-123")
  }

  @Test(arguments: [
    "smdp.example.com$MATCH-123",
    "LPA:1$$MATCH-123",
    "LPA:1$smdp.example.com$",
    "LPA:1$https://smdp.example.com$MATCH-123",
    "LPA:1$smdp.example.com/path$MATCH-123",
  ])
  func rejectsMalformedActivationCodes(_ value: String) {
    #expect(throws: EuiccError.self) {
      _ = try EuiccActivationCode(value)
    }
  }

  @Test func masksEIDAndICCIDInSnapshots() {
    let profile = EuiccProfile(
      id: "890440458467274948",
      iccid: "890440458467274948",
      nickname: nil,
      serviceProviderName: "Example",
      profileName: "Travel",
      state: .disabled,
      profileClass: nil
    )
    let snapshot = EuiccSnapshot(
      available: true,
      eid: "89044045846727494800000000000000",
      profiles: [profile],
      lastUpdated: nil,
      issue: nil
    )
    #expect(snapshot.maskedEID == "8904••••••••0000")
    #expect(snapshot.profiles[0].maskedICCID == "8904••••••••4948")
  }

  @Test func nicknameTakesPriorityOverOperatorNames() {
    let profile = EuiccProfile(
      id: "890440458467274948",
      iccid: "890440458467274948",
      nickname: "工作卡",
      serviceProviderName: "Example",
      profileName: "Travel",
      state: .enabled,
      profileClass: nil
    )

    #expect(profile.displayName == "工作卡")
  }

  @Test func buildsNicknameAndClearCommands() throws {
    #expect(
      try EuiccLPAService.profileNicknameArguments(
        iccid: " 890440458467274948 ",
        nickname: "  工作卡  "
      ) == ["profile", "nickname", "890440458467274948", "工作卡"]
    )
    #expect(
      try EuiccLPAService.profileNicknameArguments(
        iccid: "890440458467274948",
        nickname: "   "
      ) == ["profile", "nickname", "890440458467274948"]
    )
  }

  @Test func distinguishesManagedEuiccWithoutAnEnabledProfile() {
    let disabledProfile = EuiccProfile(
      id: "890440458467274948",
      iccid: "890440458467274948",
      nickname: nil,
      serviceProviderName: "Example",
      profileName: nil,
      state: .disabled,
      profileClass: nil
    )
    let disabled = EuiccSnapshot(
      available: true,
      eid: nil,
      profiles: [disabledProfile],
      lastUpdated: nil,
      issue: nil
    )
    let enabled = EuiccSnapshot(
      available: true,
      eid: nil,
      profiles: [
        EuiccProfile(
          id: disabledProfile.id,
          iccid: disabledProfile.iccid,
          nickname: nil,
          serviceProviderName: "Example",
          profileName: nil,
          state: .enabled,
          profileClass: nil
        )
      ],
      lastUpdated: nil,
      issue: nil
    )

    #expect(disabled.hasProfilesButNoneEnabled)
    #expect(!disabled.hasEnabledProfile)
    #expect(enabled.hasEnabledProfile)
    #expect(!enabled.hasProfilesButNoneEnabled)
    #expect(!EuiccSnapshot.unavailable.hasProfilesButNoneEnabled)
  }

  @Test func rejectsUnreadableQRCodeImage() {
    #expect(throws: EuiccQRCodeError.unreadableImage) {
      _ = try EuiccQRCodeDecoder.activationCode(
        from: URL(fileURLWithPath: "/tmp/djio-no-such-qr-image.png")
      )
    }
  }

  @Test func rejectsImageWithoutQRCode() throws {
    let pixels = Data(repeating: 0xFF, count: 4)
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(
      CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    )

    #expect(throws: EuiccQRCodeError.noQRCode) {
      _ = try EuiccQRCodeDecoder.activationCode(from: image)
    }
  }
}
