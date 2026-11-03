import Foundation

/// Coalesces UART bytes so streaming diagnostics do not perform one host write
/// per guest byte. Complete lines remain prompt and long non-text output is
/// bounded by `maximumChunkBytes`.
public final class UARTOutputChunker: @unchecked Sendable {
    public let maximumChunkBytes: Int

    private let lock = NSLock()
    private var bytes: [UInt8] = []

    public init(maximumChunkBytes: Int = 4_096) {
        precondition(maximumChunkBytes > 0)
        self.maximumChunkBytes = maximumChunkBytes
        bytes.reserveCapacity(maximumChunkBytes)
    }

    public func append(_ byte: UInt8) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(byte)
        guard byte == 0x0a || bytes.count >= maximumChunkBytes else {
            return nil
        }
        return takeBytes()
    }

    public func drain() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return takeBytes()
    }

    private func takeBytes() -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        let result = bytes
        bytes.removeAll(keepingCapacity: true)
        return result
    }
}
