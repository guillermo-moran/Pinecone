import Foundation

public struct AndroidVendorBootImage: Equatable {
    public static let magic = Array("VNDRBOOT".utf8)

    public let headerVersion: UInt32
    public let pageSize: Int
    public let vendorRamdisk: [UInt8]
    public let bootconfig: [UInt8]
    public let commandLine: String

    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 2128 else {
            throw VMError.unsupportedGuest("Android vendor_boot image has a truncated header")
        }
        guard Array(bytes.prefix(Self.magic.count)) == Self.magic else {
            throw VMError.unsupportedGuest("Android vendor_boot image is missing the VNDRBOOT magic")
        }

        let headerVersion = try Self.readUInt32(bytes, at: 8)
        guard headerVersion == 3 || headerVersion == 4 else {
            throw VMError.unsupportedGuest(
                "Android vendor_boot header version \(headerVersion) is unsupported; expected v3/v4"
            )
        }
        let pageSize = Int(try Self.readUInt32(bytes, at: 12))
        guard pageSize >= 512, pageSize.nonzeroBitCount == 1 else {
            throw VMError.unsupportedGuest("Android vendor_boot has invalid page size \(pageSize)")
        }
        let vendorRamdiskSize = Int(try Self.readUInt32(bytes, at: 24))
        let headerSize = Int(try Self.readUInt32(bytes, at: 2096))
        let dtbSize = Int(try Self.readUInt32(bytes, at: 2100))
        guard headerSize >= (headerVersion == 4 ? 2128 : 2112), headerSize <= bytes.count else {
            throw VMError.unsupportedGuest("Android vendor_boot has invalid header size \(headerSize)")
        }

        let ramdiskStart = try Self.align(headerSize, to: pageSize)
        let ramdiskEnd = try Self.checkedEnd(
            start: ramdiskStart,
            count: vendorRamdiskSize,
            total: bytes.count,
            name: "vendor ramdisk"
        )
        let dtbStart = try Self.align(ramdiskEnd, to: pageSize)
        let dtbEnd = try Self.checkedEnd(
            start: dtbStart,
            count: dtbSize,
            total: bytes.count,
            name: "DTB"
        )

        var bootconfig: [UInt8] = []
        if headerVersion == 4 {
            let tableSize = Int(try Self.readUInt32(bytes, at: 2112))
            let tableEntryCount = Int(try Self.readUInt32(bytes, at: 2116))
            let tableEntrySize = Int(try Self.readUInt32(bytes, at: 2120))
            let bootconfigSize = Int(try Self.readUInt32(bytes, at: 2124))
            guard tableEntryCount == 0 || tableEntrySize >= 12,
                  tableEntryCount <= (tableEntrySize == 0 ? 0 : tableSize / tableEntrySize) else {
                throw VMError.unsupportedGuest("Android vendor_boot has an invalid ramdisk table")
            }
            let tableStart = try Self.align(dtbEnd, to: pageSize)
            let tableEnd = try Self.checkedEnd(
                start: tableStart,
                count: tableSize,
                total: bytes.count,
                name: "vendor ramdisk table"
            )
            let bootconfigStart = try Self.align(tableEnd, to: pageSize)
            let bootconfigEnd = try Self.checkedEnd(
                start: bootconfigStart,
                count: bootconfigSize,
                total: bytes.count,
                name: "bootconfig"
            )
            bootconfig = Array(bytes[bootconfigStart..<bootconfigEnd])
        }

        let commandLineBytes = bytes[28..<2076]
        let commandLineEnd = commandLineBytes.firstIndex(of: 0) ?? commandLineBytes.endIndex
        self.headerVersion = headerVersion
        self.pageSize = pageSize
        self.vendorRamdisk = Array(bytes[ramdiskStart..<ramdiskEnd])
        self.bootconfig = bootconfig
        self.commandLine = String(decoding: commandLineBytes[..<commandLineEnd], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func assembledRamdisk(genericRamdisk: [UInt8]) -> [UInt8] {
        var result = vendorRamdisk
        result.append(contentsOf: genericRamdisk)
        guard !bootconfig.isEmpty else { return result }

        let padding = (4 - (bootconfig.count & 3)) & 3
        var configured = bootconfig
        configured.append(contentsOf: repeatElement(0, count: padding))
        result.append(contentsOf: configured)
        result.appendLittleEndian(UInt32(configured.count))
        result.appendLittleEndian(configured.reduce(UInt32(0)) { $0 &+ UInt32($1) })
        result.append(contentsOf: "#BOOTCONFIG\n".utf8)
        return result
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else {
            throw VMError.unsupportedGuest("truncated Android vendor_boot header")
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
            throw VMError.unsupportedGuest("Android vendor_boot has a truncated \(name) payload")
        }
        return start + count
    }

    private static func align(_ value: Int, to alignment: Int) throws -> Int {
        guard value <= Int.max - (alignment - 1) else {
            throw VMError.unsupportedGuest("Android vendor_boot payload offset overflow")
        }
        return ((value + alignment - 1) / alignment) * alignment
    }
}

private extension Array where Element == UInt8 {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
