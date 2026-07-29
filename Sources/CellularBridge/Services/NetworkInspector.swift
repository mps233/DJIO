import Darwin
import Foundation
import SystemConfiguration

struct NetworkInspector {
  func snapshot(preferredInterface: String?) -> NetworkSnapshot {
    let addresses = interfaceAddresses()
    let primary = primaryInterface()
    let interfaces = ethernetInterfaces().map { item in
      let interfaceAddresses = addresses[item.name] ?? InterfaceAddresses()
      return NetworkInterfaceSnapshot(
        name: item.name,
        displayName: item.displayName,
        address: interfaceAddresses.displayAddress,
        isLinkUp: interfaceAddresses.isLinkUp,
        isActive: interfaceAddresses.hasUsableAddress,
        isPrimary: item.name == primary
      )
    }

    let selected = Self.selectInterface(from: interfaces, preferredInterface: preferredInterface)
    return NetworkSnapshot(
      interfaces: interfaces, selectedInterface: selected, primaryInterface: primary)
  }

  func trafficCounters(for interfaceName: String) -> InterfaceTrafficCounters? {
    let interfaceIndex = if_nametoindex(interfaceName)
    guard interfaceIndex != 0 else { return nil }

    var managementInformationBase = [
      Int32(CTL_NET), Int32(PF_ROUTE), 0, 0, Int32(NET_RT_IFLIST2), Int32(interfaceIndex),
    ]
    for _ in 0..<3 {
      var bufferLength = 0
      let sizeStatus = managementInformationBase.withUnsafeMutableBufferPointer { values in
        sysctl(values.baseAddress, u_int(values.count), nil, &bufferLength, nil, 0)
      }
      guard sizeStatus == 0, bufferLength >= MemoryLayout<if_msghdr2>.size else { return nil }

      let buffer = UnsafeMutableRawPointer.allocate(
        byteCount: bufferLength,
        alignment: MemoryLayout<if_msghdr2>.alignment
      )
      var actualLength = bufferLength
      let readStatus = managementInformationBase.withUnsafeMutableBufferPointer { values in
        sysctl(values.baseAddress, u_int(values.count), buffer, &actualLength, nil, 0)
      }
      if readStatus == 0 {
        let counters = Self.trafficCounters(
          in: UnsafeRawPointer(buffer), length: actualLength, interfaceIndex: interfaceIndex)
        buffer.deallocate()
        return counters
      }
      let readError = errno
      buffer.deallocate()
      guard readError == ENOMEM else { return nil }
    }
    return nil
  }

  static func trafficCounters(
    in buffer: UnsafeRawPointer,
    length: Int,
    interfaceIndex: UInt32
  ) -> InterfaceTrafficCounters? {
    var offset = 0
    while offset + MemoryLayout<UInt32>.size <= length {
      let message = buffer.advanced(by: offset)
      let messageLength = Int(message.loadUnaligned(as: UInt16.self))
      let messageVersion = message.advanced(by: 2).load(as: UInt8.self)
      let messageType = message.advanced(by: 3).load(as: UInt8.self)
      guard messageLength >= MemoryLayout<UInt32>.size, offset + messageLength <= length else {
        return nil
      }

      if messageVersion == UInt8(RTM_VERSION),
        Int32(messageType) == RTM_IFINFO2,
        messageLength >= MemoryLayout<if_msghdr2>.size
      {
        let information = message.loadUnaligned(as: if_msghdr2.self)
        if UInt32(information.ifm_index) == interfaceIndex {
          return InterfaceTrafficCounters(
            interfaceIndex: interfaceIndex,
            receivedBytes: information.ifm_data.ifi_ibytes,
            sentBytes: information.ifm_data.ifi_obytes
          )
        }
      }
      offset += messageLength
    }
    return nil
  }

  private func ethernetInterfaces() -> [(name: String, displayName: String)] {
    guard let values = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
    let serviceNames = networkServiceNamesByInterface()
    return values.compactMap { interface in
      guard
        let type = SCNetworkInterfaceGetInterfaceType(interface),
        type == kSCNetworkInterfaceTypeEthernet,
        let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?
      else { return nil }
      let hardwareName = (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? "以太网"
      let displayName = serviceNames[bsdName] ?? hardwareName
      return (bsdName, displayName)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func networkServiceNamesByInterface() -> [String: String] {
    guard
      let preferences = SCPreferencesCreate(nil, "CellularBridge" as CFString, nil),
      let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
    else { return [:] }

    var result: [String: String] = [:]
    for service in services {
      guard
        let interface = SCNetworkServiceGetInterface(service),
        let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
        let serviceName = SCNetworkServiceGetName(service) as String?
      else { continue }
      result[bsdName] = serviceName
    }
    return result
  }

  private func interfaceAddresses() -> [String: InterfaceAddresses] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [:] }
    defer { freeifaddrs(head) }

    var result: [String: InterfaceAddresses] = [:]
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let item = cursor?.pointee {
      defer { cursor = item.ifa_next }
      guard let address = item.ifa_addr else { continue }
      let flags = Int32(item.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }
      let interfaceName = String(cString: item.ifa_name)
      var addresses = result[interfaceName] ?? InterfaceAddresses()
      addresses.isLinkUp = true
      result[interfaceName] = addresses

      let family = Int32(address.pointee.sa_family)
      guard family == AF_INET || family == AF_INET6 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let status = getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &host,
        socklen_t(host.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      if status == 0 {
        let value = String(cString: host)
        addresses = result[interfaceName] ?? InterfaceAddresses()
        if family == AF_INET {
          if Self.isUsableIPv4(value) {
            addresses.usableIPv4 = addresses.usableIPv4 ?? value
          } else {
            addresses.fallbackIPv4 = addresses.fallbackIPv4 ?? value
          }
        } else if Self.isUsableIPv6(value) {
          addresses.usableIPv6 = addresses.usableIPv6 ?? value
        }
        result[interfaceName] = addresses
      }
    }
    return result
  }

  private func primaryInterface() -> String? {
    guard
      let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString),
      let dictionary = value as? [String: Any]
    else { return nil }
    return dictionary["PrimaryInterface"] as? String
  }

  static func selectInterface(
    from interfaces: [NetworkInterfaceSnapshot], preferredInterface: String?
  ) -> NetworkInterfaceSnapshot? {
    if let preferredInterface,
      let preferred = interfaces.first(where: { $0.name == preferredInterface })
    {
      return preferred
    }
    let likelyCellular = interfaces.filter { $0.name != "en0" && isLikelyCellular($0) }
    return likelyCellular.first(where: { $0.isActive && $0.isPrimary })
      ?? likelyCellular.first(where: \.isActive)
      ?? likelyCellular.first(where: \.isLinkUp)
      ?? likelyCellular.first
  }

  static func isLikelyCellular(_ interface: NetworkInterfaceSnapshot) -> Bool {
    let name = interface.displayName.lowercased()
    return ["dji", "ecm", "4g", "modem", "cellular", "baiwang", "quectel"].contains {
      name.contains($0)
    }
  }

  static func isVirtualTunnel(_ interfaceName: String) -> Bool {
    let normalized = interfaceName.lowercased()
    return ["utun", "ipsec", "ppp", "gif", "stf"].contains {
      normalized.hasPrefix($0)
    }
  }

  static func isUsableIPv4(_ value: String) -> Bool {
    let octets = value.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
    guard octets[0] != 0, octets[0] != 127 else { return false }
    return !(octets[0] == 169 && octets[1] == 254)
  }

  static func isUsableIPv6(_ value: String) -> Bool {
    let address =
      value.lowercased().split(separator: "%", maxSplits: 1).first.map(String.init) ?? value
    guard address.contains(":"), address != "::", address != "::1" else { return false }
    return !address.hasPrefix("fe80:") && !address.hasPrefix("ff")
  }

  private struct InterfaceAddresses {
    var usableIPv4: String?
    var usableIPv6: String?
    var fallbackIPv4: String?
    var isLinkUp = false

    var displayAddress: String? { usableIPv4 ?? usableIPv6 ?? fallbackIPv4 }
    var hasUsableAddress: Bool { usableIPv4 != nil || usableIPv6 != nil }
  }
}
