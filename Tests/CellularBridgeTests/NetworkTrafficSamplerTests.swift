import Testing

@testable import CellularBridge

struct NetworkTrafficSamplerTests {
  @Test func calculatesRatesFromMonotonicSamples() throws {
    var sampler = NetworkTrafficSampler()
    let start = ContinuousClock.now

    let first = sampler.sample(
      interfaceName: "en9",
      counters: counters(index: 40, received: 5_000_000_000, sent: 9_000_000_000),
      at: start
    )
    #expect(first.downloadBytesPerSecond == nil)
    #expect(first.uploadBytesPerSecond == nil)
    #expect(first.receivedBytes == 5_000_000_000)
    #expect(first.sentBytes == 9_000_000_000)

    let second = sampler.sample(
      interfaceName: "en9",
      counters: counters(index: 40, received: 5_000_000_600, sent: 9_000_000_200),
      at: start.advanced(by: .seconds(2))
    )
    #expect(second.downloadBytesPerSecond == 300)
    #expect(second.uploadBytesPerSecond == 100)
  }

  @Test func unchangedCountersProduceZeroRates() {
    var sampler = NetworkTrafficSampler()
    let start = ContinuousClock.now
    let value = counters(index: 40, received: 10_000, sent: 20_000)
    _ = sampler.sample(interfaceName: "en9", counters: value, at: start)
    let second = sampler.sample(
      interfaceName: "en9", counters: value, at: start.advanced(by: .seconds(1)))

    #expect(second.downloadBytesPerSecond == 0)
    #expect(second.uploadBytesPerSecond == 0)
  }

  @Test func resetsForInterfaceChangesCounterResetsAndLongGaps() {
    var sampler = NetworkTrafficSampler()
    let start = ContinuousClock.now
    _ = sampler.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 100, sent: 100), at: start)

    let changedIndex = sampler.sample(
      interfaceName: "en9",
      counters: counters(index: 41, received: 1_000, sent: 1_000),
      at: start.advanced(by: .seconds(1)))
    #expect(changedIndex.downloadBytesPerSecond == nil)

    let resetCounters = sampler.sample(
      interfaceName: "en9",
      counters: counters(index: 41, received: 10, sent: 10),
      at: start.advanced(by: .seconds(2)))
    #expect(resetCounters.downloadBytesPerSecond == nil)
    #expect(resetCounters.uploadBytesPerSecond == nil)

    let longGap = sampler.sample(
      interfaceName: "en9",
      counters: counters(index: 41, received: 1_010, sent: 510),
      at: start.advanced(by: .seconds(10)))
    #expect(longGap.downloadBytesPerSecond == nil)
    #expect(longGap.uploadBytesPerSecond == nil)
  }

  @Test func missingSampleClearsTheBaseline() {
    var sampler = NetworkTrafficSampler()
    let start = ContinuousClock.now
    _ = sampler.sample(
      interfaceName: "en9", counters: counters(index: 40, received: 100, sent: 100), at: start)
    _ = sampler.sample(interfaceName: nil, counters: nil, at: start.advanced(by: .seconds(1)))
    let recovered = sampler.sample(
      interfaceName: "en9",
      counters: counters(index: 40, received: 10_000, sent: 10_000),
      at: start.advanced(by: .seconds(2)))

    #expect(recovered.downloadBytesPerSecond == nil)
    #expect(recovered.uploadBytesPerSecond == nil)
  }

  @Test func formatsRatesAndTotals() {
    #expect(NetworkTrafficFormatter.rate(nil) == "--")
    #expect(NetworkTrafficFormatter.rate(0) == "0 B/s")
    #expect(NetworkTrafficFormatter.rate(1_500) == "1.50 KB/s")
    #expect(NetworkTrafficFormatter.rate(12_500_000) == "12.5 MB/s")
    #expect(NetworkTrafficFormatter.byteCount(5_000_000_000) == "5.00 GB")
  }

  private func counters(index: UInt32, received: UInt64, sent: UInt64)
    -> InterfaceTrafficCounters
  {
    InterfaceTrafficCounters(interfaceIndex: index, receivedBytes: received, sentBytes: sent)
  }
}
