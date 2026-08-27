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
        let byteCount = try totalByteCount(
            buffers.lazy.map(\.count),
            offset: offset
        )
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
        let byteCount = try totalByteCount(
            buffers.lazy.map(\.count),
            offset: offset
        )
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


    private func totalByteCount<Counts: Sequence>(
        _ counts: Counts,
        offset: Int
    ) throws -> Int where Counts.Element == Int {
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

    private let nativeStorage: OpaquePointer

    public init(url: URL) throws {
        var errorCode: Int32 = 0
        guard let storage = url.path.withCString({ path in
            avz_file_block_storage_open(path, &errorCode)
        }) else {
            let code = errorCode == 0 ? EIO : errorCode
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "open mapped block storage \(url.path) failed: " +
                        String(cString: strerror(code))
                ]
            )
        }
        let byteCount = avz_file_block_storage_size(storage)
        guard byteCount > 0, byteCount <= UInt64(Int.max) else {
            avz_file_block_storage_close(storage)
            throw VMError.deviceError(
                "block storage file has an invalid size: \(url.path)"
            )
        }
        nativeStorage = storage
        count = Int(byteCount)
    }

    deinit {
        avz_file_block_storage_close(nativeStorage)
    }

    public func read(at offset: Int, count requestedCount: Int) throws -> [UInt8] {
        try validateRange(offset: offset, count: requestedCount)
        guard requestedCount > 0 else {
            return []
        }

        var result = Array(repeating: UInt8(0), count: requestedCount)
        try result.withUnsafeMutableBytes { buffer in
            var segment = AVZBlockIOSegment(
                base: buffer.baseAddress,
                length: buffer.count
            )
            let ioResult = avz_file_block_storage_readv(
                nativeStorage,
                &segment,
                1,
                UInt64(offset)
            )
            guard ioResult == Int64(requestedCount) else {
                throw Self.nativeIOError(
                    operation: "mapped block read",
                    result: ioResult
                )
            }
        }
        return result
    }

    public func write(_ bytes: [UInt8], at offset: Int) throws {
        try validateRange(offset: offset, count: bytes.count)
        guard !bytes.isEmpty else {
            return
        }

        try bytes.withUnsafeBytes { buffer in
            var segment = AVZBlockIOSegment(
                base: UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                length: buffer.count
            )
            let ioResult = avz_file_block_storage_writev(
                nativeStorage,
                &segment,
                1,
                UInt64(offset)
            )
            guard ioResult == Int64(bytes.count) else {
                throw Self.nativeIOError(
                    operation: "mapped block write",
                    result: ioResult
                )
            }
        }
    }

    public func read(into buffers: [UnsafeMutableRawBufferPointer], at offset: Int) throws {
        let byteCount = try validatedVectorByteCount(
            buffers.lazy.map(\.count),
            offset: offset
        )
        guard byteCount > 0 else { return }
        try withUnsafeTemporaryAllocation(
            of: AVZBlockIOSegment.self,
            capacity: buffers.count
        ) { segments in
            var segmentCount = 0
            for buffer in buffers where !buffer.isEmpty {
                segments[segmentCount] = AVZBlockIOSegment(
                    base: buffer.baseAddress,
                    length: buffer.count
                )
                segmentCount += 1
            }
            let ioResult = avz_file_block_storage_readv(
                nativeStorage,
                segments.baseAddress,
                segmentCount,
                UInt64(offset)
            )
            guard ioResult == Int64(byteCount) else {
                throw Self.nativeIOError(
                    operation: "mapped block readv",
                    result: ioResult
                )
            }
        }
    }

    public func write(from buffers: [UnsafeRawBufferPointer], at offset: Int) throws {
        let byteCount = try validatedVectorByteCount(
            buffers.lazy.map(\.count),
            offset: offset
        )
        guard byteCount > 0 else { return }
        try withUnsafeTemporaryAllocation(
            of: AVZBlockIOSegment.self,
            capacity: buffers.count
        ) { segments in
            var segmentCount = 0
            for buffer in buffers where !buffer.isEmpty {
                segments[segmentCount] = AVZBlockIOSegment(
                    base: UnsafeMutableRawPointer(mutating: buffer.baseAddress),
                    length: buffer.count
                )
                segmentCount += 1
            }
            let ioResult = avz_file_block_storage_writev(
                nativeStorage,
                segments.baseAddress,
                segmentCount,
                UInt64(offset)
            )
            guard ioResult == Int64(byteCount) else {
                throw Self.nativeIOError(
                    operation: "mapped block writev",
                    result: ioResult
                )
            }
        }
    }

    public func zero(at offset: Int, count requestedCount: Int) throws {
        try validateRange(offset: offset, count: requestedCount)
        guard requestedCount > 0 else {
            return
        }

        let result = avz_file_block_storage_zero(
            nativeStorage,
            UInt64(offset),
            UInt64(requestedCount)
        )
        guard result == 0 else {
            throw Self.nativeIOError(
                operation: "mapped block zero",
                result: Int64(result)
            )
        }
    }

    public func flush() throws {
        let result = avz_file_block_storage_flush(nativeStorage)
        guard result == 0 else {
            throw Self.nativeIOError(
                operation: "mapped block flush",
                result: Int64(result)
            )
        }
    }

    public func snapshot() throws -> [UInt8] {
        try read(at: 0, count: count)
    }

    private func validatedVectorByteCount<Counts: Sequence>(
        _ counts: Counts,
        offset: Int
    ) throws -> Int where Counts.Element == Int {
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
}
