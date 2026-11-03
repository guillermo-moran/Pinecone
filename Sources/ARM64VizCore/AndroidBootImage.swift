import Foundation

public struct AndroidBootImage: Equatable {
    public static let magic = Array("ANDROID!".utf8)
    public static let pageSize = 4096

    public let headerVersion: UInt32
    public let kernel: [UInt8]
    public let ramdisk: [UInt8]?
    public let commandLine: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= Self.pageSize else {
            throw VMError.unsupportedGuest("Android boot image is smaller than its 4096-byte header page")
        }
        guard Array(bytes.prefix(Self.magic.count)) == Self.magic else {
            throw VMError.unsupportedGuest("Android boot image is missing the ANDROID! magic")
        }

        let kernelSize = Int(try Self.readUInt32(bytes, at: 8))
        let ramdiskSize = Int(try Self.readUInt32(bytes, at: 12))
        let headerSize = Int(try Self.readUInt32(bytes, at: 20))
        let headerVersion = try Self.readUInt32(bytes, at: 40)

        guard headerVersion == 3 || headerVersion == 4 else {
            throw VMError.unsupportedGuest(
                "Android boot image header version \(headerVersion) is unsupported; LineageOS boot currently accepts v3/v4"
            )
        }
        guard headerSize >= 1580, headerSize <= Self.pageSize else {
            throw VMError.unsupportedGuest("invalid Android boot image header size \(headerSize)")
        }

        let kernelStart = Self.pageSize
        let kernelEnd = try Self.checkedEnd(start: kernelStart, count: kernelSize, total: bytes.count, name: "kernel")
        let ramdiskStart = try Self.alignedEnd(kernelEnd)
        let ramdiskEnd = try Self.checkedEnd(start: ramdiskStart, count: ramdiskSize, total: bytes.count, name: "ramdisk")

        self.headerVersion = headerVersion
        self.kernel = Array(bytes[kernelStart..<kernelEnd])
        self.ramdisk = ramdiskSize == 0 ? nil : Array(bytes[ramdiskStart..<ramdiskEnd])

        let commandLineBytes = bytes[44..<1580]
        let commandLineEnd = commandLineBytes.firstIndex(of: 0) ?? commandLineBytes.endIndex
        self.commandLine = String(decoding: commandLineBytes[..<commandLineEnd], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isAndroidBootImage(_ bytes: [UInt8]) -> Bool {
        bytes.count >= magic.count && Array(bytes.prefix(magic.count)) == magic
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else {
            throw VMError.unsupportedGuest("truncated Android boot image header")
        }
        return UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) |
            (UInt32(bytes[offset + 3]) << 24)
    }

    private static func checkedEnd(
        start: Int,
        count: Int,
        total: Int,
        name: String
    ) throws -> Int {
        guard count >= 0, start >= 0, start <= total, count <= total - start else {
            throw VMError.unsupportedGuest("Android boot image has a truncated \(name) payload")
        }
        return start + count
    }

    private static func alignedEnd(_ value: Int) throws -> Int {
        guard value <= Int.max - (pageSize - 1) else {
            throw VMError.unsupportedGuest("Android boot image payload offset overflow")
        }
        return ((value + pageSize - 1) / pageSize) * pageSize
    }
}
