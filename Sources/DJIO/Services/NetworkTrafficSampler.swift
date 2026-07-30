import Foundation

struct NetworkTrafficSampler {
  private var previous: Sample?
  private let maximumInterval: Duration

  init(maximumInterval: Duration = .seconds(5)) {
    self.maximumInterval = maximumInterval
  }

  mutating func sample(
    interfaceName: String?,
    counters: InterfaceTrafficCounters?,
    at sampledAt: ContinuousClock.Instant = ContinuousClock.now
  ) -> NetworkTrafficSnapshot {
    guard let interfaceName, let counters else {
      reset()
      return .unavailable
    }

    let current = Sample(interfaceName: interfaceName, counters: counters, sampledAt: sampledAt)
    defer { previous = current }

    var snapshot = NetworkTrafficSnapshot(
      interfaceName: interfaceName,
      receivedBytes: counters.receivedBytes,
      sentBytes: counters.sentBytes
    )
    guard
      let previous,
      previous.interfaceName == interfaceName,
      previous.counters.interfaceIndex == counters.interfaceIndex
    else { return snapshot }

    let interval = previous.sampledAt.duration(to: sampledAt)
    guard interval > .zero, interval <= maximumInterval else { return snapshot }
    guard
      counters.receivedBytes >= previous.counters.receivedBytes,
      counters.sentBytes >= previous.counters.sentBytes
    else { return snapshot }

    let components = interval.components
    let seconds =
      Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    snapshot.downloadBytesPerSecond =
      Double(counters.receivedBytes - previous.counters.receivedBytes) / seconds
    snapshot.uploadBytesPerSecond =
      Double(counters.sentBytes - previous.counters.sentBytes) / seconds
    return snapshot
  }

  mutating func reset() {
    previous = nil
  }

  private struct Sample {
    let interfaceName: String
    let counters: InterfaceTrafficCounters
    let sampledAt: ContinuousClock.Instant
  }
}
