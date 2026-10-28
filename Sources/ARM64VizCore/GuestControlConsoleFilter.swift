/// Removes host-control records without buffering ordinary shell prompts.
/// State survives UART chunks, including a split control prefix.
public struct GuestControlConsoleFilter {
    private let prefixes = [Array("\u{1e}PINECONE_APP_PRESENTED ".utf8),
                            Array("\u{1e}PINECONE_APP_LIFECYCLE ".utf8)]
    private var candidate: [UInt8] = []
    private var discarding = false
    private var discardedBytes = 0

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte == 0x1e {
                output.append(contentsOf: candidate)
                candidate = [byte]
                discarding = false
                discardedBytes = 0
                continue
            }
            if discarding {
                discardedBytes += 1
                if byte == 10 { discarding = false; continue }
                if discardedBytes <= 2048 { continue }
                discarding = false
            }
            if !candidate.isEmpty {
                candidate.append(byte)
                if prefixes.contains(candidate) {
                    candidate.removeAll(keepingCapacity: true)
                    discarding = true
                    discardedBytes = 0
                    continue
                }
                if prefixes.contains(where: { $0.starts(with: candidate) }) { continue }
                output.append(contentsOf: candidate)
                candidate.removeAll(keepingCapacity: true)
                continue
            }
            output.append(byte)
        }
        return output
    }
}
