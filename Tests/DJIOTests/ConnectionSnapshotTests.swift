import Testing

@testable import DJIO

struct ConnectionSnapshotTests {
  @Test func recognizesDJIPrivateMode() {
    let snapshot = ConnectionSnapshot(
      usbDeviceIdentifier: .djiFirstGenerationFactory,
      usbNetworkMode: 0
    )

    #expect(snapshot.moduleUsageMode == .dji)
  }

  @Test func recognizesECMForBothSupportedUSBIdentities() {
    let converted = ConnectionSnapshot(
      usbDeviceIdentifier: .quectelEC25,
      usbNetworkMode: 1
    )
    let factoryIdentity = ConnectionSnapshot(
      usbDeviceIdentifier: .djiFirstGenerationFactory,
      usbNetworkMode: 1
    )

    #expect(converted.moduleUsageMode == .ecm)
    #expect(factoryIdentity.moduleUsageMode == .ecm)
  }

  @Test func doesNotPresentUnknownModesAsHealthySelections() {
    let unread = ConnectionSnapshot(
      usbDeviceIdentifier: .djiFirstGenerationFactory,
      usbNetworkMode: nil
    )
    let mbim = ConnectionSnapshot(
      usbDeviceIdentifier: .quectelEC25,
      usbNetworkMode: 2
    )
    let rndis = ConnectionSnapshot(
      usbDeviceIdentifier: .djiFirstGenerationFactory,
      usbNetworkMode: 3
    )

    #expect(unread.moduleUsageMode == nil)
    #expect(mbim.moduleUsageMode == nil)
    #expect(rndis.moduleUsageMode == nil)
  }
}
