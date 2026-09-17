/// Removes host-control records without buffering ordinary shell prompts.
/// State survives UART chunks, including a split control prefix.
public struct GuestControlConsoleFilter {
    private let prefix = Array("\u{1e}PINECONE_APP_PRESENTED ".utf8)
    private var candidate: [UInt8] = []
    private var atLineStart = true
    private var discarding = false

    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte == 0x1e && !discarding { atLineStart = true }
            if discarding {
                if byte == 10 { discarding = false; atLineStart = true }
                continue
            }
            if atLineStart, byte == prefix[candidate.count] {
                candidate.append(byte)
                if candidate.count == prefix.count {
                    candidate.removeAll(keepingCapacity: true)
                    discarding = true
                }
                continue
            }
            output.append(contentsOf: candidate)
            candidate.removeAll(keepingCapacity: true)
            output.append(byte)
            atLineStart = byte == 10
        }
        return output
    }
}
