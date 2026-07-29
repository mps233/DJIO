import Foundation

struct StoredDecodedSMSPart: Sendable, Hashable {
  let record: ModemStoredPDU
  let decoded: DecodedSMSPart
}

struct AssembledStoredSMS: Sendable, Hashable {
  let decoded: DecodedSMSPart
  let records: [ModemStoredPDU]
}

struct SMSAssembler {
  private struct Key: Hashable {
    let sender: String
    let reference: UInt16
    let uses16BitReference: Bool
    let total: Int
    let alphabet: String
  }

  private let maximumTimestampSpan: TimeInterval

  init(maximumTimestampSpan: TimeInterval = 5 * 60) {
    self.maximumTimestampSpan = maximumTimestampSpan
  }

  func assemble(_ parts: [StoredDecodedSMSPart]) -> [AssembledStoredSMS] {
    let singleParts = parts.filter { $0.decoded.concatenation == nil }
    var completed = Dictionary(grouping: singleParts, by: { $0.decoded.rawPDU }).compactMap {
      _, duplicates -> AssembledStoredSMS? in
      guard let representative = duplicates.min(by: recordOrder) else { return nil }
      return AssembledStoredSMS(
        decoded: representative.decoded,
        records: duplicates.map(\.record).sorted(by: recordOrder)
      )
    }
    var grouped: [Key: [StoredDecodedSMSPart]] = [:]

    for part in parts {
      guard let concatenation = part.decoded.concatenation else { continue }
      guard concatenation.totalParts > 0,
        concatenation.sequence > 0,
        concatenation.sequence <= concatenation.totalParts
      else { continue }
      let key = Key(
        sender: part.decoded.sender,
        reference: concatenation.reference,
        uses16BitReference: concatenation.uses16BitReference,
        total: concatenation.totalParts,
        alphabet: part.decoded.alphabet.rawValue
      )
      grouped[key, default: []].append(part)
    }

    for (key, candidates) in grouped {
      for cluster in timestampClusters(candidates) {
        if let message = assemble(cluster, totalParts: key.total) {
          completed.append(message)
        }
      }
    }

    return completed.sorted {
      if $0.decoded.receivedAt != $1.decoded.receivedAt {
        return $0.decoded.receivedAt < $1.decoded.receivedAt
      }
      let leftIndex = $0.records.map(\.index).min() ?? 0
      let rightIndex = $1.records.map(\.index).min() ?? 0
      if leftIndex != rightIndex { return leftIndex < rightIndex }
      return $0.decoded.rawPDU < $1.decoded.rawPDU
    }
  }

  private func timestampClusters(_ parts: [StoredDecodedSMSPart]) -> [[StoredDecodedSMSPart]] {
    let ordered = parts.sorted {
      if $0.decoded.receivedAt != $1.decoded.receivedAt {
        return $0.decoded.receivedAt < $1.decoded.receivedAt
      }
      return $0.record.index < $1.record.index
    }
    var clusters: [[StoredDecodedSMSPart]] = []
    for part in ordered {
      if let firstTimestamp = clusters.last?.first?.decoded.receivedAt,
        part.decoded.receivedAt.timeIntervalSince(firstTimestamp) <= maximumTimestampSpan
      {
        clusters[clusters.count - 1].append(part)
      } else {
        clusters.append([part])
      }
    }
    return clusters
  }

  private func assemble(_ parts: [StoredDecodedSMSPart], totalParts: Int)
    -> AssembledStoredSMS?
  {
    var bySequence: [Int: [StoredDecodedSMSPart]] = [:]
    for part in parts {
      guard let sequence = part.decoded.concatenation?.sequence else { return nil }
      bySequence[sequence, default: []].append(part)
    }

    var orderedParts: [StoredDecodedSMSPart] = []
    var records: [ModemStoredPDU] = []
    for sequence in 1...totalParts {
      guard let candidates = bySequence[sequence] else { return nil }
      let distinctPDUs = Dictionary(grouping: candidates, by: { $0.decoded.rawPDU })
      guard distinctPDUs.count == 1, let representative = candidates.min(by: recordOrder) else {
        // A reused reference inside the timestamp window is ambiguous. Keep all
        // fragments on the modem instead of risking a mixed message.
        return nil
      }
      orderedParts.append(representative)
      records.append(contentsOf: candidates.map(\.record))
    }

    guard let first = orderedParts.first else { return nil }
    let decoded = DecodedSMSPart(
      sender: first.decoded.sender,
      body: orderedParts.map(\.decoded.body).joined(),
      receivedAt: orderedParts.map(\.decoded.receivedAt).min() ?? first.decoded.receivedAt,
      alphabet: first.decoded.alphabet,
      concatenation: nil,
      rawPDU: orderedParts.map(\.decoded.rawPDU).joined(separator: ":")
    )
    let uniqueRecords = Dictionary(grouping: records, by: { "\($0.storage):\($0.index)" })
      .compactMap { $0.value.first }
      .sorted(by: recordOrder)
    return AssembledStoredSMS(decoded: decoded, records: uniqueRecords)
  }

  private func recordOrder(_ left: StoredDecodedSMSPart, _ right: StoredDecodedSMSPart) -> Bool {
    recordOrder(left.record, right.record)
  }

  private func recordOrder(_ left: ModemStoredPDU, _ right: ModemStoredPDU) -> Bool {
    if left.storage != right.storage { return left.storage < right.storage }
    return left.index < right.index
  }
}
