import ARM64VizNative
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
    func read(into buffers: [UnsafeMutableRawBufferPointer], at offset: Int) throws
    func write(from buffers: [UnsafeRawBufferPointer], at offset: Int) throws
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

    func read(into buffers: [UnsafeMutableRawBufferPointer], at offset: Int) throws {
        let byteCount = try totalByteCount(buffers.map(\.count), offset: offset)
        try validateRange(offset: offset, count: byteCount)
        var sourceOffset = offset
        for buffer in buffers where !buffer.isEmpty {
            _ = bytes.withUnsafeBytes { source in
                memcpy(
                    buffer.baseAddress!,
                    source.baseAddress!.advanced(by: sourceOffset),
                    buffer.count
                )
            }
            sourceOffset += buffer.count
        }
    }

    func write(from buffers: [UnsafeRawBufferPointer], at offset: Int) throws {
        let byteCount = try totalByteCount(buffers.map(\.count), offset: offset)
        try validateRange(offset: offset, count: byteCount)
        var destinationOffset = offset
        for buffer in buffers where !buffer.isEmpty {
            _ = bytes.withUnsafeMutableBytes { destination in
                memcpy(destination.baseAddress!.advanced(by: destinationOffset), buffer.baseAddress!, buffer.count)
            }
            destinationOffset += buffer.count
        }
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


    private func totalByteCount(_ counts: [Int], offset: Int) throws -> Int {
        try counts.reduce(0) { total, count in
            guard count >= 0, total <= Int.max - count else {
                throw VMError.deviceError("block storage vector length overflow at offset \(offset)")
            }
            return total + count
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

    public func read(into buffers: [UnsafeMutableRawBufferPointer], at offset: Int) throws {
        let byteCount = try validatedVectorByteCount(buffers.map(\.count), offset: offset)
        guard byteCount > 0 else { return }
        try lock.withLock {
            let segments = buffers.map {
                AVZBlockIOSegment(base: $0.baseAddress, length: $0.count)
            }
            let result = segments.withUnsafeBufferPointer { segmentBuffer in
                avz_block_io_preadv(
                    fileDescriptor,
                    segmentBuffer.baseAddress,
                    segmentBuffer.count,
                    UInt64(offset)
                )
            }
            guard result == Int64(byteCount) else {
                throw Self.nativeIOError(operation: "preadv", result: result)
            }
        }
    }

    public func write(from buffers: [UnsafeRawBufferPointer], at offset: Int) throws {
        let byteCount = try validatedVectorByteCount(buffers.map(\.count), offset: offset)
        guard byteCount > 0 else { return }
        try lock.withLock {
            let segments = buffers.map {
                AVZBlockIOSegment(
                    base: UnsafeMutableRawPointer(mutating: $0.baseAddress),
                    length: $0.count
                )
            }
            let result = segments.withUnsafeBufferPointer { segmentBuffer in
                avz_block_io_pwritev(
                    fileDescriptor,
                    segmentBuffer.baseAddress,
                    segmentBuffer.count,
                    UInt64(offset)
                )
            }
            guard result == Int64(byteCount) else {
                throw Self.nativeIOError(operation: "pwritev", result: result)
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

    private func validatedVectorByteCount(_ counts: [Int], offset: Int) throws -> Int {
        let byteCount = try counts.reduce(0) { total, count in
            guard count >= 0, total <= Int.max - count else {
                throw VMError.deviceError("block storage vector length overflow at offset \(offset)")
            }
            return total + count
        }
        try validateRange(offset: offset, count: byteCount)
        return byteCount
    }

    private static func nativeIOError(operation: String, result: Int64) -> Error {
        let code = result < 0 ? Int32(clamping: -result) : EIO
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"]
        )
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
