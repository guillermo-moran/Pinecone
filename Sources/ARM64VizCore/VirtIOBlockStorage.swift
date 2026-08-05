import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol VirtIOBlockStorage: AnyObject {
    var count: Int { get }

    func read(at offset: Int, count: Int) throws -> [UInt8]
    func write(_ bytes: [UInt8], at offset: Int) throws
    func zero(at offset: Int, count: Int) throws
    func flush() throws
    func snapshot() throws -> [UInt8]
}

final class InMemoryVirtIOBlockStorage: VirtIOBlockStorage {
    private var bytes: [UInt8]

    var count: Int {
        bytes.count
    }

    init(count: Int) {
        bytes = Array(repeating: 0, count: count)
    }

    func read(at offset: Int, count: Int) throws -> [UInt8] {
        try validateRange(offset: offset, count: count)
        return Array(bytes[offset..<(offset + count)])
    }

    func write(_ source: [UInt8], at offset: Int) throws {
        try validateRange(offset: offset, count: source.count)
        bytes.replaceSubrange(offset..<(offset + source.count), with: source)
    }

    func zero(at offset: Int, count: Int) throws {
        try validateRange(offset: offset, count: count)
        guard count > 0 else {
            return
        }
        _ = bytes.withUnsafeMutableBytes { buffer in
            memset(buffer.baseAddress!.advanced(by: offset), 0, count)
        }
    }

    func flush() throws {}

    func snapshot() throws -> [UInt8] {
        bytes
    }

    private func validateRange(offset: Int, count requestedCount: Int) throws {
        guard offset >= 0,
              requestedCount >= 0,
              offset <= bytes.count,
              requestedCount <= bytes.count - offset else {
            throw VMError.deviceError(
                "block storage range offset=\(offset) count=\(requestedCount) exceeds \(bytes.count) bytes"
            )
        }
    }
}

public final class FileBackedVirtIOBlockStorage: VirtIOBlockStorage, @unchecked Sendable {
    public let count: Int

    private static let zeroChunk = Array(repeating: UInt8(0), count: 64 * 1024)

    private let fileDescriptor: Int32
    private let lock = NSLock()

    public init(url: URL) throws {
        let descriptor = open(url.path, O_RDWR)
        guard descriptor >= 0 else {
            throw Self.posixError(operation: "open", path: url.path)
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = Self.posixError(operation: "fstat", path: url.path)
            close(descriptor)
            throw error
        }
        guard status.st_size > 0, UInt64(status.st_size) <= UInt64(Int.max) else {
            close(descriptor)
            throw VMError.deviceError("block storage file has an invalid size: \(url.path)")
        }

        fileDescriptor = descriptor
        count = Int(status.st_size)
    }

    deinit {
        close(fileDescriptor)
    }

    public func read(at offset: Int, count requestedCount: Int) throws -> [UInt8] {
        try validateRange(offset: offset, count: requestedCount)
        guard requestedCount > 0 else {
            return []
        }

        return try lock.withLock {
            var result = Array(repeating: UInt8(0), count: requestedCount)
            try result.withUnsafeMutableBytes { buffer in
                try readFully(
                    into: buffer.baseAddress!,
                    count: requestedCount,
                    offset: offset
                )
            }
            return result
        }
    }

    public func write(_ bytes: [UInt8], at offset: Int) throws {
        try validateRange(offset: offset, count: bytes.count)
        guard !bytes.isEmpty else {
            return
        }

        try lock.withLock {
            try bytes.withUnsafeBytes { buffer in
                try writeFully(
                    from: buffer.baseAddress!,
                    count: bytes.count,
                    offset: offset
                )
            }
        }
    }

    public func zero(at offset: Int, count requestedCount: Int) throws {
        try validateRange(offset: offset, count: requestedCount)
        guard requestedCount > 0 else {
            return
        }

        try lock.withLock {
            var written = 0
            try Self.zeroChunk.withUnsafeBytes { buffer in
                while written < requestedCount {
                    let chunkCount = min(buffer.count, requestedCount - written)
                    try writeFully(
                        from: buffer.baseAddress!,
                        count: chunkCount,
                        offset: offset + written
                    )
                    written += chunkCount
                }
            }
        }
    }

    public func flush() throws {
        try lock.withLock {
            guard fsync(fileDescriptor) == 0 else {
                throw Self.posixError(operation: "fsync")
            }
        }
    }

    public func snapshot() throws -> [UInt8] {
        try read(at: 0, count: count)
    }

    private func readFully(into destination: UnsafeMutableRawPointer, count: Int, offset: Int) throws {
        var completed = 0
        while completed < count {
            let result = pread(
                fileDescriptor,
                destination.advanced(by: completed),
                count - completed,
                off_t(offset + completed)
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw Self.posixError(operation: result == 0 ? "pread reached EOF" : "pread")
            }
            completed += result
        }
    }

    private func writeFully(from source: UnsafeRawPointer, count: Int, offset: Int) throws {
        var completed = 0
        while completed < count {
            let result = pwrite(
                fileDescriptor,
                source.advanced(by: completed),
                count - completed,
                off_t(offset + completed)
            )
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                throw Self.posixError(operation: "pwrite")
            }
            completed += result
        }
    }

    private func validateRange(offset: Int, count requestedCount: Int) throws {
        guard offset >= 0,
              requestedCount >= 0,
              offset <= count,
              requestedCount <= count - offset else {
            throw VMError.deviceError(
                "block storage range offset=\(offset) count=\(requestedCount) exceeds \(count) bytes"
            )
        }
    }

    private static func posixError(operation: String, path: String? = nil) -> VMError {
        let errorNumber = errno
        let reason = String(cString: strerror(errorNumber))
        let target = path.map { " \($0)" } ?? ""
        return .deviceError("\(operation)\(target) failed: \(reason) (errno \(errorNumber))")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
