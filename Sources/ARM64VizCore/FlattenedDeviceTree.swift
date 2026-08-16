import Foundation

public struct DeviceTreeInitrd: Equatable {
    public let start: GuestAddress
    public let endExclusive: GuestAddress

    public init(start: GuestAddress, endExclusive: GuestAddress) {
        precondition(start < endExclusive, "initrd range must not be empty")
        self.start = start
        self.endExclusive = endExclusive
    }
}

public enum FlattenedDeviceTree {
    public static let magic: UInt32 = 0xd00d_feed
    private static let version: UInt32 = 17
    private static let lastCompatibleVersion: UInt32 = 16

    public static func encode(
        configuration: BootConfiguration,
        initrd: DeviceTreeInitrd? = nil
    ) throws -> [UInt8] {
        let writer = FDTStructWriter()

        writer.beginNode("")
        writer.property("compatible", strings: ["arm64viz,research-vm"])
        writer.property("model", string: configuration.machineName)
        writer.property("#address-cells", cells: [2])
        writer.property("#size-cells", cells: [2])

        writer.beginNode("chosen")
        writer.property("bootargs", string: configuration.bootArguments)
        writer.property("stdout-path", string: "serial0")
        writer.property("arm64viz,entry-point", cells64: [configuration.entryPoint])
        if let initrd {
            writer.property("linux,initrd-start", cells64: [initrd.start])
            writer.property("linux,initrd-end", cells64: [initrd.endExclusive])
        }
        writer.endNode()

        writer.beginNode("memory@\(String(configuration.ramBase, radix: 16))")
        writer.property("device_type", string: "memory")
        writer.property("reg", addressSizePairs: [(configuration.ramBase, configuration.ramSize)])
        writer.endNode()

        writer.beginNode("cpus")
        writer.property("#address-cells", cells: [1])
        writer.property("#size-cells", cells: [0])
        for cpu in 0..<configuration.cpuCount {
            writer.beginNode("cpu@\(cpu)")
            writer.property("device_type", string: "cpu")
            writer.property("compatible", strings: ["arm,armv8"])
            writer.property("reg", cells: [UInt32(cpu)])
            if let cpuEnableMethod = configuration.cpuEnableMethod {
                writer.property("enable-method", string: cpuEnableMethod)
            }
            writer.endNode()
        }
        writer.endNode()

        if let psciMethod = configuration.psciMethod {
            writer.beginNode("psci")
            writer.property("compatible", strings: ["arm,psci-1.0", "arm,psci-0.2"])
            writer.property("method", string: psciMethod)
            writer.endNode()
        }

        writer.beginNode("aliases")
        if let uart = configuration.devices.first(where: { $0.name.contains("uart") }) {
            writer.property("serial0", string: "/soc/\(uart.name)@\(String(uart.base, radix: 16))")
        }
        writer.endNode()

        writer.beginNode("clk24mhz")
        writer.property("compatible", strings: ["fixed-clock"])
        writer.property("#clock-cells", cells: [0])
        writer.property("clock-frequency", cells: [24_000_000])
        writer.property("phandle", cells: [2])
        writer.endNode()

        writer.beginNode("soc")
        writer.property("compatible", strings: ["simple-bus"])
        writer.property("#address-cells", cells: [2])
        writer.property("#size-cells", cells: [2])
        writer.property("ranges", bytes: [])

        for device in configuration.devices {
            writer.beginNode("\(device.name)@\(String(device.base, radix: 16))")
            writer.property("compatible", strings: device.compatible)
            if !device.registerRanges.isEmpty {
                writer.property("reg", addressSizePairs: device.registerRanges.map { ($0.base, $0.size) })
            }
            if !device.interrupts.isEmpty {
                writer.property("interrupts", cells: device.interrupts)
            }
            for key in device.properties.keys.sorted() {
                let rawValue = device.properties[key] ?? ""
                if let strings = parseStringList(rawValue) {
                    writer.property(key, strings: strings)
                } else {
                    writer.property(key, bytes: parsePropertyData(rawValue))
                }
            }
            writer.endNode()
        }

        writer.endNode()
        writer.endNode()
        writer.end()

        let structBlock = writer.structBlock
        let stringsBlock = writer.stringsBlock
        let headerSize = 40
        let reserveMapSize = 16
        let offMemReserveMap = headerSize
        let offDtStruct = offMemReserveMap + reserveMapSize
        let offDtStrings = offDtStruct + structBlock.count
        let totalSize = offDtStrings + stringsBlock.count

        var output: [UInt8] = []
        output.appendBE32(magic)
        output.appendBE32(UInt32(totalSize))
        output.appendBE32(UInt32(offDtStruct))
        output.appendBE32(UInt32(offDtStrings))
        output.appendBE32(UInt32(offMemReserveMap))
        output.appendBE32(version)
        output.appendBE32(lastCompatibleVersion)
        output.appendBE32(0)
        output.appendBE32(UInt32(stringsBlock.count))
        output.appendBE32(UInt32(structBlock.count))
        output.appendBE64(0)
        output.appendBE64(0)
        output.append(contentsOf: structBlock)
        output.append(contentsOf: stringsBlock)
        return output
    }

    private static func parseStringList(_ rawValue: String) -> [String]? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        var result: [String] = []
        var index = trimmed.startIndex

        func skipWhitespace() {
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
        }

        while true {
            skipWhitespace()
            guard index < trimmed.endIndex else {
                return result.isEmpty ? nil : result
            }
            guard trimmed[index] == "\"" else {
                return nil
            }
            index = trimmed.index(after: index)

            var value = ""
            while index < trimmed.endIndex {
                let character = trimmed[index]
                index = trimmed.index(after: index)
                if character == "\"" {
                    result.append(value)
                    break
                }
                if character == "\\", index < trimmed.endIndex {
                    value.append(trimmed[index])
                    index = trimmed.index(after: index)
                } else {
                    value.append(character)
                }
            }

            skipWhitespace()
            guard index < trimmed.endIndex else {
                return result
            }
            guard trimmed[index] == "," else {
                return nil
            }
            index = trimmed.index(after: index)
        }
    }

    private static func parsePropertyData(_ rawValue: String) -> [UInt8] {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") {
            let body = trimmed.dropFirst().dropLast()
            let values = body
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .compactMap { token -> UInt32? in
                    let string = String(token)
                    if string.hasPrefix("0x") || string.hasPrefix("0X") {
                        return UInt32(String(string.dropFirst(2)), radix: 16)
                    }
                    return UInt32(string, radix: 10)
                }
            var data: [UInt8] = []
            for value in values {
                data.appendBE32(value)
            }
            return data
        }

        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return nulTerminated(String(trimmed.dropFirst().dropLast()))
        }

        if trimmed.isEmpty {
            return []
        }

        return nulTerminated(trimmed)
    }

    private static func nulTerminated(_ string: String) -> [UInt8] {
        Array(string.utf8) + [0]
    }
}

private final class FDTStructWriter {
    private enum Token: UInt32 {
        case beginNode = 1
        case endNode = 2
        case property = 3
        case end = 9
    }

    private(set) var structBlock: [UInt8] = []
    private var stringOffsets: [String: UInt32] = [:]
    private var strings: [UInt8] = []

    var stringsBlock: [UInt8] {
        strings
    }

    func beginNode(_ name: String) {
        structBlock.appendBE32(Token.beginNode.rawValue)
        structBlock.append(contentsOf: name.utf8)
        structBlock.append(0)
        structBlock.padToFourBytes()
    }

    func endNode() {
        structBlock.appendBE32(Token.endNode.rawValue)
    }

    func end() {
        structBlock.appendBE32(Token.end.rawValue)
    }

    func property(_ name: String, string: String) {
        property(name, bytes: Array(string.utf8) + [0])
    }

    func property(_ name: String, strings: [String]) {
        property(name, bytes: strings.flatMap { Array($0.utf8) + [0] })
    }

    func property(_ name: String, cells: [UInt32]) {
        var data: [UInt8] = []
        for cell in cells {
            data.appendBE32(cell)
        }
        property(name, bytes: data)
    }

    func property(_ name: String, cells64: [UInt64]) {
        var data: [UInt8] = []
        for value in cells64 {
            data.appendBE32(UInt32(value >> 32))
            data.appendBE32(UInt32(value & 0xffff_ffff))
        }
        property(name, bytes: data)
    }

    func property(_ name: String, addressSizePairs: [(GuestAddress, UInt64)]) {
        var data: [UInt8] = []
        for (address, size) in addressSizePairs {
            data.appendBE32(UInt32(address >> 32))
            data.appendBE32(UInt32(address & 0xffff_ffff))
            data.appendBE32(UInt32(size >> 32))
            data.appendBE32(UInt32(size & 0xffff_ffff))
        }
        property(name, bytes: data)
    }

    func property(_ name: String, bytes: [UInt8]) {
        structBlock.appendBE32(Token.property.rawValue)
        structBlock.appendBE32(UInt32(bytes.count))
        structBlock.appendBE32(offset(for: name))
        structBlock.append(contentsOf: bytes)
        structBlock.padToFourBytes()
    }

    private func offset(for name: String) -> UInt32 {
        if let existing = stringOffsets[name] {
            return existing
        }
        let offset = UInt32(strings.count)
        stringOffsets[name] = offset
        strings.append(contentsOf: name.utf8)
        strings.append(0)
        return offset
    }
}

private extension Array where Element == UInt8 {
    mutating func appendBE32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendBE64(_ value: UInt64) {
        appendBE32(UInt32(value >> 32))
        appendBE32(UInt32(value & 0xffff_ffff))
    }

    mutating func padToFourBytes() {
        while count % 4 != 0 {
            append(0)
        }
    }
}
