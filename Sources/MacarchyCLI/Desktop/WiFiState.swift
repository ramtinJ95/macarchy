import Darwin
import Foundation
import SystemConfiguration

struct WiFiState: Equatable, Sendable {
  let interface: String?
  let address: String?
  let mask: String?
  let router: String?
  let hostname: String?
  let received: UInt32
  let sent: UInt32

  static func read() throws -> Self {
    guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
      throw WiFiError.queryFailed("cannot enumerate network interfaces")
    }
    let names = interfaces.filter {
      SCNetworkInterfaceGetInterfaceType($0) as String? == kSCNetworkInterfaceTypeIEEE80211
        as String
    }.compactMap { SCNetworkInterfaceGetBSDName($0) as String? }.sorted()
    guard let interface = names.first else {
      return Self(
        interface: nil, address: nil, mask: nil, router: nil,
        hostname: nil, received: 0, sent: 0)
    }
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else {
      throw WiFiError.queryFailed("cannot read interface counters")
    }
    defer { freeifaddrs(head) }
    var next = head
    var address: String?
    var mask: String?
    var counters: (UInt32, UInt32)?
    while let pointer = next {
      let item = pointer.pointee
      next = item.ifa_next
      guard String(cString: item.ifa_name) == interface, let socket = item.ifa_addr else {
        continue
      }
      if Int32(socket.pointee.sa_family) == AF_LINK, let data = item.ifa_data {
        let info = data.assumingMemoryBound(to: if_data.self).pointee
        counters = (info.ifi_ibytes, info.ifi_obytes)
      }
      if Int32(socket.pointee.sa_family) == AF_INET {
        address = numericAddress(socket)
        if let netmask = item.ifa_netmask { mask = numericAddress(netmask) }
      }
    }
    guard let counters else { throw WiFiError.queryFailed("selected Wi-Fi interface disappeared") }
    guard let store = SCDynamicStoreCreate(nil, "Macarchy Wi-Fi" as CFString, nil, nil) else {
      throw WiFiError.queryFailed("cannot read network state")
    }
    var router: String?
    if let preferences = SCPreferencesCreate(nil, "Macarchy Wi-Fi" as CFString, nil),
      let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
    {
      for service in services {
        guard let device = SCNetworkServiceGetInterface(service),
          SCNetworkInterfaceGetBSDName(device) as String? == interface,
          let identifier = SCNetworkServiceGetServiceID(service) as String?
        else { continue }
        let key = "State:/Network/Service/\(identifier)/IPv4" as CFString
        if let state = SCDynamicStoreCopyValue(store, key) as? [String: Any] {
          router = state[kSCPropNetIPv4Router as String] as? String
          if router != nil { break }
        }
      }
    }
    return Self(
      interface: interface, address: address, mask: mask, router: router,
      hostname: SCDynamicStoreCopyComputerName(store, nil) as String?,
      received: counters.0, sent: counters.1)
  }

  private static func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard
      getnameinfo(
        address, socklen_t(address.pointee.sa_len), &buffer,
        socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
    else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  func rates(since previous: Self, seconds: Double) throws -> (upload: String, download: String) {
    guard interface == previous.interface, seconds.isFinite, seconds > 0, seconds < 10 else {
      throw WiFiError.queryFailed("network sample changed or expired")
    }
    return (
      Self.rate(Double(sent &- previous.sent) / seconds),
      Self.rate(Double(received &- previous.received) / seconds)
    )
  }

  static func rate(_ bytes: Double) -> String {
    let units = [" Bps", "KBps", "MBps", "GBps"]
    var value = max(0, bytes)
    var unit = 0
    while value >= 1000 && unit < units.count - 1 {
      value /= 1000
      unit += 1
    }
    return String(format: "%03d", Int(value)) + units[unit]
  }

  var details: [(String, String)] {
    [
      (
        "ssid",
        interface == nil
          ? "No Wi-Fi interface" : address == nil ? "Disconnected / no IPv4" : "Privacy restricted"
      ),
      ("hostname", hostname ?? "Unavailable"), ("ip", address ?? "Unavailable"),
      ("mask", mask ?? "Unavailable"), ("router", router ?? "Unavailable"),
    ]
  }
}

enum WiFiError: Error {
  case queryFailed(String)
  case invalidInvocation
}
