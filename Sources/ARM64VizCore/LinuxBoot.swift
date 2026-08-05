public enum LinuxGuestProfile: String, Codable, Equatable {
    case generic
    case postmarketOS

    public var defaultBootArguments: String {
        switch self {
        case .generic:
            return "console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 root=/dev/vda rw rootwait"
        case .postmarketOS:
            return "console=ttyAMA0 earlycon=pl011,mmio32,0x9000000 root=/dev/vda rw rootwait loglevel=7"
        }
    }
}

public struct LinuxBootArtifacts: Equatable {
    public let kernelImage: [UInt8]
    public let initrd: [UInt8]?
    public let deviceTreeBlob: [UInt8]?
    public let diskImage: [UInt8]?
    public let diskByteCountHint: Int?

    public init(
        kernelImage: [UInt8],
        initrd: [UInt8]? = nil,
        deviceTreeBlob: [UInt8]? = nil,
        diskImage: [UInt8]? = nil,
        diskByteCountHint: Int? = nil
    ) {
        self.kernelImage = kernelImage
        self.initrd = initrd
        self.deviceTreeBlob = deviceTreeBlob
        self.diskImage = diskImage
        self.diskByteCountHint = diskByteCountHint
    }
}

public struct LinuxBootLayout: Codable, Equatable {
    public let profile: LinuxGuestProfile
    public let kernelLoadAddress: GuestAddress
    public let kernelByteCount: Int
    public let fdtLoadAddress: GuestAddress
    public let fdtByteCount: Int
    public let initrdLoadAddress: GuestAddress?
    public let initrdByteCount: Int?
    public let diskByteCount: Int?
    public let usedSuppliedDeviceTree: Bool
    public let bootArguments: String

    public var initrdRange: AddressRange? {
        guard let initrdLoadAddress, let initrdByteCount else {
            return nil
        }
        return AddressRange(start: initrdLoadAddress, length: UInt64(initrdByteCount))
    }
}

public struct LinuxBootLoadResult: Equatable {
    public let configuration: BootConfiguration
    public let layout: LinuxBootLayout
    public let deviceTreeBlob: [UInt8]

    public init(
        configuration: BootConfiguration,
        layout: LinuxBootLayout,
        deviceTreeBlob: [UInt8]
    ) {
        self.configuration = configuration
        self.layout = layout
        self.deviceTreeBlob = deviceTreeBlob
    }
}

public struct LinuxDirectBootAdapter: GuestBootAdapter {
    public let identifier = "linux-direct"
    public let artifacts: LinuxBootArtifacts
    public let profile: LinuxGuestProfile
    public let kernelLoadAddress: GuestAddress
    public let fdtReserveSize: UInt64
    public let bootArguments: String

    public init(
        artifacts: LinuxBootArtifacts,
        profile: LinuxGuestProfile = .generic,
        kernelLoadAddress: GuestAddress = ARM64VizMachineLayout.toyEntryPoint,
        fdtReserveSize: UInt64 = 1024 * 1024,
        bootArguments: String? = nil
    ) {
        self.artifacts = artifacts
        self.profile = profile
        self.kernelLoadAddress = kernelLoadAddress
        self.fdtReserveSize = fdtReserveSize
        self.bootArguments = bootArguments ?? profile.defaultBootArguments
    }

    public func load(into vm: VirtualMachine) throws -> BootConfiguration {
        try loadWithResult(into: vm).configuration
    }

    public func loadWithResult(into vm: VirtualMachine) throws -> LinuxBootLoadResult {
        guard !artifacts.kernelImage.isEmpty else {
            throw VMError.unsupportedGuest("Linux direct boot requires a non-empty ARM64 kernel Image")
        }
        guard fdtReserveSize >= 4096 else {
            throw VMError.deviceError("FDT reserve must be at least 4096 bytes")
        }

        let configuration = BootConfiguration(
            machineName: profile == .postmarketOS ? "arm64viz-postmarketos" : "arm64viz-linux-direct",
            cpuCount: 1,
            entryPoint: kernelLoadAddress,
            ramBase: vm.memory.base,
            ramSize: UInt64(vm.memory.size),
            bootArguments: bootArguments,
            devices: vm.bootDevices
        )

        let topOfRam = vm.memory.base + UInt64(vm.memory.size)
        guard topOfRam >= fdtReserveSize, topOfRam - fdtReserveSize >= vm.memory.base else {
            throw VMError.invalidMemoryAccess(address: vm.memory.base, width: Int(fdtReserveSize))
        }
        let fdtLoadAddress = alignDown(topOfRam - fdtReserveSize, alignment: 4096)
        let initrdLoadAddress: GuestAddress?
        if let initrd = artifacts.initrd {
            guard fdtLoadAddress >= UInt64(initrd.count), fdtLoadAddress - UInt64(initrd.count) >= vm.memory.base else {
                throw VMError.invalidMemoryAccess(address: vm.memory.base, width: initrd.count)
            }
            initrdLoadAddress = alignDown(fdtLoadAddress - UInt64(initrd.count), alignment: 4096)
        } else {
            initrdLoadAddress = nil
        }

        let initrdRange = try initrdLoadAddress.map { address -> DeviceTreeInitrd in
            guard let initrd = artifacts.initrd else {
                throw VMError.deviceError("internal initrd address calculation failed")
            }
            return DeviceTreeInitrd(start: address, endExclusive: address + UInt64(initrd.count))
        }

        let fdt = try artifacts.deviceTreeBlob ?? FlattenedDeviceTree.encode(
            configuration: configuration,
            initrd: initrdRange
        )
        guard UInt64(fdt.count) <= fdtReserveSize else {
            throw VMError.deviceError("generated FDT size \(fdt.count) exceeds reserve \(fdtReserveSize)")
        }

        try validateRange(
            AddressRange(start: kernelLoadAddress, length: UInt64(artifacts.kernelImage.count)),
            name: "kernel Image",
            memory: vm.memory.range
        )
        try validateRange(
            AddressRange(start: fdtLoadAddress, length: UInt64(fdt.count)),
            name: "FDT",
            memory: vm.memory.range
        )
        if let initrdRange = initrdLoadAddress.map({ AddressRange(start: $0, length: UInt64(artifacts.initrd?.count ?? 0)) }) {
            try validateRange(initrdRange, name: "initrd", memory: vm.memory.range)
            try validateNoOverlap(
                AddressRange(start: kernelLoadAddress, length: UInt64(artifacts.kernelImage.count)),
                initrdRange,
                names: ("kernel Image", "initrd")
            )
        }
        try validateNoOverlap(
            AddressRange(start: kernelLoadAddress, length: UInt64(artifacts.kernelImage.count)),
            AddressRange(start: fdtLoadAddress, length: UInt64(fdt.count)),
            names: ("kernel Image", "FDT")
        )

        try vm.loadBinary(artifacts.kernelImage, at: kernelLoadAddress)
        if let initrd = artifacts.initrd, let initrdLoadAddress {
            try vm.loadBinary(initrd, at: initrdLoadAddress)
        }
        try vm.loadBinary(fdt, at: fdtLoadAddress)
        if let diskImage = artifacts.diskImage {
            try loadDiskImage(diskImage, into: vm)
        }

        vm.reset(entryPoint: kernelLoadAddress)
        vm.cpu.pstate = ARM64PState.el1hMasked
        vm.cpu.x[0] = fdtLoadAddress
        vm.cpu.x[1] = 0
        vm.cpu.x[2] = 0
        vm.cpu.x[3] = 0

        let layout = LinuxBootLayout(
            profile: profile,
            kernelLoadAddress: kernelLoadAddress,
            kernelByteCount: artifacts.kernelImage.count,
            fdtLoadAddress: fdtLoadAddress,
            fdtByteCount: fdt.count,
            initrdLoadAddress: initrdLoadAddress,
            initrdByteCount: artifacts.initrd?.count,
            diskByteCount: artifacts.diskImage?.count ?? artifacts.diskByteCountHint,
            usedSuppliedDeviceTree: artifacts.deviceTreeBlob != nil,
            bootArguments: bootArguments
        )

        return LinuxBootLoadResult(
            configuration: configuration,
            layout: layout,
            deviceTreeBlob: fdt
        )
    }

    private func loadDiskImage(_ bytes: [UInt8], into vm: VirtualMachine) throws {
        if let block = vm.mmio.allDevices.compactMap({ $0 as? VirtualVirtIODevice }).first(where: { $0.kind == .block }) {
            try block.replaceStorage(bytes, notifyConfigChange: false)
            return
        }

        guard let block = vm.mmio.allDevices.compactMap({ $0 as? VirtualBlockDevice }).first else {
            throw VMError.deviceError("Linux disk image supplied but no virtual block device is registered")
        }
        try block.replaceStorage(bytes)
    }

    private func alignDown(_ value: UInt64, alignment: UInt64) -> UInt64 {
        value - (value % alignment)
    }

    private func validateRange(_ range: AddressRange, name: String, memory: AddressRange) throws {
        guard memory.contains(range.start, width: range.length) else {
            throw VMError.invalidMemoryAccess(address: range.start, width: Int(range.length))
        }
    }

    private func validateNoOverlap(_ lhs: AddressRange, _ rhs: AddressRange, names: (String, String)) throws {
        guard !lhs.overlaps(rhs) else {
            throw VMError.deviceError("\(names.0) overlaps \(names.1)")
        }
    }
}
