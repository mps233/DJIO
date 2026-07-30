import Darwin
import Testing

@testable import DJIO

struct NetworkInspectorTests {
  @Test func reads64BitTrafficCountersForTheLoopbackInterface() throws {
    let counters = try #require(NetworkInspector().trafficCounters(for: "lo0"))
    #expect(counters.interfaceIndex == if_nametoindex("lo0"))
  }

  @Test func parsesTheTargetInterfaceWithoutTruncating64BitCounters() throws {
    var other = trafficMessage(index: 39, received: 1_000, sent: 2_000)
    var target = trafficMessage(index: 40, received: 5_000_000_000, sent: 9_000_000_000)
    var bytes: [UInt8] = []
    withUnsafeBytes(of: &other) { bytes.append(contentsOf: $0) }
    withUnsafeBytes(of: &target) { bytes.append(contentsOf: $0) }

    let counters: InterfaceTrafficCounters? = bytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return nil }
      return NetworkInspector.trafficCounters(
        in: baseAddress, length: buffer.count, interfaceIndex: 40)
    }
    #expect(counters?.interfaceIndex == 40)
    #expect(counters?.receivedBytes == 5_000_000_000)
    #expect(counters?.sentBytes == 9_000_000_000)
  }

  @Test func rejectsMalformedTrafficMessages() throws {
    var truncated = [UInt8](repeating: 0, count: 4)
    truncated[0] = UInt8(MemoryLayout<if_msghdr2>.size & 0xFF)
    truncated[1] = UInt8(MemoryLayout<if_msghdr2>.size >> 8)

    let counters: InterfaceTrafficCounters? = truncated.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return nil }
      return NetworkInspector.trafficCounters(
        in: baseAddress, length: buffer.count, interfaceIndex: 40)
    }
    #expect(counters == nil)
  }

  @Test func acceptsUsableIPv6AndRejectsLocalOnlyAddresses() {
    #expect(NetworkInspector.isUsableIPv6("240e:479:4ea8:1053::1"))
    #expect(NetworkInspector.isUsableIPv6("fd00:6152::1"))
    #expect(!NetworkInspector.isUsableIPv6("fe80::1%en9"))
    #expect(!NetworkInspector.isUsableIPv6("::1"))
    #expect(!NetworkInspector.isUsableIPv6("ff02::1"))

    #expect(NetworkInspector.isUsableIPv4("192.168.225.22"))
    #expect(!NetworkInspector.isUsableIPv4("169.254.113.202"))
  }

  @Test func automaticallySelectsTheBaiwangECMInterface() {
    let interfaces = [
      NetworkInterfaceSnapshot(
        name: "en0", displayName: "Wi-Fi", address: "192.168.1.20", isLinkUp: true,
        isActive: true, isPrimary: true),
      NetworkInterfaceSnapshot(
        name: "en7", displayName: "USB 10/100/1000 LAN", address: "192.168.1.21",
        isLinkUp: true, isActive: true, isPrimary: false),
      NetworkInterfaceSnapshot(
        name: "en9", displayName: "Baiwang", address: "240e:479:4ea8:1053::1",
        isLinkUp: true, isActive: true, isPrimary: false),
    ]

    let selected = NetworkInspector.selectInterface(from: interfaces, preferredInterface: nil)
    #expect(selected?.name == "en9")
  }

  @Test func honorsAnExplicitInterfaceSelection() {
    let interfaces = [
      NetworkInterfaceSnapshot(
        name: "en7", displayName: "USB Ethernet", address: nil, isLinkUp: false,
        isActive: false, isPrimary: false),
      NetworkInterfaceSnapshot(
        name: "en9", displayName: "DJI 4G", address: "240e:479::1", isLinkUp: true,
        isActive: true, isPrimary: false),
    ]

    let selected = NetworkInspector.selectInterface(from: interfaces, preferredInterface: "en7")
    #expect(selected?.name == "en7")
  }

  @Test func selectsTheKnownECMInterfaceBeforeItHasAUsableAddress() {
    let interfaces = [
      NetworkInterfaceSnapshot(
        name: "en9", displayName: "DJI 4G", address: "169.254.113.202", isLinkUp: true,
        isActive: false, isPrimary: false)
    ]

    let selected = NetworkInspector.selectInterface(from: interfaces, preferredInterface: nil)
    #expect(selected?.name == "en9")
    #expect(selected?.isActive == false)
  }

  @Test func recognizesVirtualTunnelInterfaces() {
    #expect(NetworkInspector.isVirtualTunnel("utun6"))
    #expect(NetworkInspector.isVirtualTunnel("IPSec0"))
    #expect(NetworkInspector.isVirtualTunnel("ppp0"))
    #expect(!NetworkInspector.isVirtualTunnel("en9"))
    #expect(!NetworkInspector.isVirtualTunnel("bridge100"))
  }

  private func trafficMessage(index: UInt16, received: UInt64, sent: UInt64) -> if_msghdr2 {
    var message = if_msghdr2()
    message.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
    message.ifm_version = UInt8(RTM_VERSION)
    message.ifm_type = UInt8(RTM_IFINFO2)
    message.ifm_index = index
    message.ifm_data.ifi_ibytes = received
    message.ifm_data.ifi_obytes = sent
    return message
  }
}
