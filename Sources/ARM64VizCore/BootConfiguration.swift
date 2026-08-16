public struct BootRegisterRange: Codable, Equatable {
    public let base: GuestAddress
    public let size: UInt64

    public init(base: GuestAddress, size: UInt64) {
        self.base = base
        self.size = size
    }
}

public struct BootDeviceDescriptor: Codable, Equatable {
    public let name: String
    public let compatible: [String]
    public let base: GuestAddress
    public let size: UInt64
    public let registerRanges: [BootRegisterRange]
    public let interrupts: [UInt32]
    public let properties: [String: String]

    public init(
        name: String,
        compatible: [String],
        base: GuestAddress,
        size: UInt64,
        registerRanges: [BootRegisterRange]? = nil,
        interrupts: [UInt32] = [],
        properties: [String: String] = [:]
    ) {
        self.name = name
        self.compatible = compatible
        self.base = base
        self.size = size
        self.registerRanges = registerRanges ?? (size > 0 ? [BootRegisterRange(base: base, size: size)] : [])
        self.interrupts = interrupts
        self.properties = properties
    }
}

public struct BootConfiguration: Codable, Equatable {
    public let machineName: String
    public let cpuCount: Int
    public let cpuEnableMethod: String?
    public let psciMethod: String?
    public let entryPoint: GuestAddress
    public let ramBase: GuestAddress
    public let ramSize: UInt64
    public let bootArguments: String
    public let devices: [BootDeviceDescriptor]

    public init(
        machineName: String = "arm64viz-research-vm",
        cpuCount: Int = 1,
        cpuEnableMethod: String? = nil,
        psciMethod: String? = nil,
        entryPoint: GuestAddress,
        ramBase: GuestAddress,
        ramSize: UInt64,
        bootArguments: String = "",
        devices: [BootDeviceDescriptor]
    ) {
        self.machineName = machineName
        self.cpuCount = cpuCount
        self.cpuEnableMethod = cpuEnableMethod
        self.psciMethod = psciMethod
        self.entryPoint = entryPoint
        self.ramBase = ramBase
        self.ramSize = ramSize
        self.bootArguments = bootArguments
        self.devices = devices
    }

    public func renderDTS() -> String {
        var lines: [String] = []
        lines.append("/dts-v1/;")
        lines.append("")
        lines.append("/ {")
        lines.append("    compatible = \"arm64viz,research-vm\";")
        lines.append("    model = \"\(escape(machineName))\";")
        lines.append("    #address-cells = <2>;")
        lines.append("    #size-cells = <2>;")
        lines.append("")
        lines.append("    chosen {")
        lines.append("        bootargs = \"\(escape(bootArguments))\";")
        lines.append("        stdout-path = \"serial0\";")
        lines.append("        arm64viz,entry-point = \(cell64(entryPoint));")
        lines.append("    };")
        lines.append("")
        lines.append("    memory@\(String(ramBase, radix: 16)) {")
        lines.append("        device_type = \"memory\";")
        lines.append("        reg = \(regCells(base: ramBase, size: ramSize));")
        lines.append("    };")
        lines.append("")
        lines.append("    cpus {")
        lines.append("        #address-cells = <1>;")
        lines.append("        #size-cells = <0>;")
        for cpu in 0..<cpuCount {
            lines.append("        cpu@\(cpu) {")
            lines.append("            device_type = \"cpu\";")
            lines.append("            compatible = \"arm,armv8\";")
            lines.append("            reg = <\(cpu)>;")
            if let cpuEnableMethod {
                lines.append("            enable-method = \"\(escape(cpuEnableMethod))\";")
            }
            lines.append("        };")
        }
        lines.append("    };")
        if let psciMethod {
            lines.append("")
            lines.append("    psci {")
            lines.append("        compatible = \"arm,psci-1.0\", \"arm,psci-0.2\";")
            lines.append("        method = \"\(escape(psciMethod))\";")
            lines.append("    };")
        }
        lines.append("")
        lines.append("    aliases {")
        if devices.contains(where: { $0.name.contains("uart") }) {
            lines.append("        serial0 = &uart0;")
        }
        lines.append("    };")
        lines.append("")
        lines.append("    clk24mhz: clk24mhz {")
        lines.append("        compatible = \"fixed-clock\";")
        lines.append("        #clock-cells = <0>;")
        lines.append("        clock-frequency = <24000000>;")
        lines.append("        phandle = <2>;")
        lines.append("    };")
        lines.append("")
        lines.append("    soc {")
        lines.append("        compatible = \"simple-bus\";")
        lines.append("        #address-cells = <2>;")
        lines.append("        #size-cells = <2>;")
        lines.append("        ranges;")

        for device in devices {
            let label = labelName(for: device.name)
            lines.append("")
            lines.append("        \(label): \(device.name)@\(String(device.base, radix: 16)) {")
            lines.append("            compatible = \(compatibleList(device.compatible));")
            if !device.registerRanges.isEmpty {
                lines.append("            reg = \(regCells(ranges: device.registerRanges));")
            }
            if !device.interrupts.isEmpty {
                lines.append("            interrupts = <\(device.interrupts.map(String.init).joined(separator: " "))>;")
            }
            for key in device.properties.keys.sorted() {
                let value = device.properties[key] ?? ""
                if value.isEmpty {
                    lines.append("            \(key);")
                } else {
                    lines.append("            \(key) = \(value);")
                }
            }
            lines.append("        };")
        }

        lines.append("    };")
        lines.append("};")
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private func escape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func labelName(for deviceName: String) -> String {
    if deviceName.contains("uart") { return "uart0" }
    if deviceName == "intc" { return "intc" }
    if deviceName == "timer" { return "timer" }
    return deviceName.replacingOccurrences(of: "-", with: "_")
}

private func compatibleList(_ compatible: [String]) -> String {
    compatible.map { "\"\(escape($0))\"" }.joined(separator: ", ")
}

private func cell64(_ value: UInt64) -> String {
    let high = UInt32(value >> 32)
    let low = UInt32(value & 0xffff_ffff)
    return "<0x\(String(high, radix: 16)) 0x\(String(low, radix: 16))>"
}

private func regCells(base: UInt64, size: UInt64) -> String {
    let baseHigh = UInt32(base >> 32)
    let baseLow = UInt32(base & 0xffff_ffff)
    let sizeHigh = UInt32(size >> 32)
    let sizeLow = UInt32(size & 0xffff_ffff)
    return "<0x\(String(baseHigh, radix: 16)) 0x\(String(baseLow, radix: 16)) 0x\(String(sizeHigh, radix: 16)) 0x\(String(sizeLow, radix: 16))>"
}

private func regCells(ranges: [BootRegisterRange]) -> String {
    let cells = ranges.flatMap { range -> [String] in
        [
            "0x\(String(UInt32(range.base >> 32), radix: 16))",
            "0x\(String(UInt32(range.base & 0xffff_ffff), radix: 16))",
            "0x\(String(UInt32(range.size >> 32), radix: 16))",
            "0x\(String(UInt32(range.size & 0xffff_ffff), radix: 16))"
        ]
    }
    return "<\(cells.joined(separator: " "))>"
}
