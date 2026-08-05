public protocol GuestBootAdapter {
    var identifier: String { get }
    func load(into vm: VirtualMachine) throws -> BootConfiguration
}

public struct ToyUARTGuestAdapter: GuestBootAdapter {
    public let identifier = "toy-uart"
    public let entryPoint: GuestAddress
    public let uartBase: GuestAddress
    public let message: String

    public init(
        entryPoint: GuestAddress = ARM64VizMachineLayout.toyEntryPoint,
        uartBase: GuestAddress = ARM64VizMachineLayout.uartBase,
        message: String = "arm64viz toy guest\n"
    ) {
        self.entryPoint = entryPoint
        self.uartBase = uartBase
        self.message = message
    }

    public func load(into vm: VirtualMachine) throws -> BootConfiguration {
        let image = ToyUARTProgram.image(message: message, uartBase: uartBase)
        try vm.loadBinary(image, at: entryPoint)
        vm.reset(entryPoint: entryPoint)
        return BootConfiguration(
            entryPoint: entryPoint,
            ramBase: vm.memory.base,
            ramSize: UInt64(vm.memory.size),
            bootArguments: "console=ttyAMA0 earlycon=arm64viz-uart",
            devices: vm.bootDevices
        )
    }
}

public struct MobileOSToyGuestAdapter: GuestBootAdapter {
    public let identifier = "mobile-os-image"
    public let entryPoint: GuestAddress
    public let uartBase: GuestAddress
    public let appRuntime: String

    public init(
        entryPoint: GuestAddress = ARM64VizMachineLayout.toyEntryPoint,
        uartBase: GuestAddress = ARM64VizMachineLayout.uartBase,
        appRuntime: String = "javascript"
    ) {
        self.entryPoint = entryPoint
        self.uartBase = uartBase
        self.appRuntime = appRuntime
    }

    public func load(into vm: VirtualMachine) throws -> BootConfiguration {
        try RuntimeDirection.requireJavaScriptMobileOSEnabled(operation: identifier)
        return try MobileOSImageBootAdapter(
            image: .developmentImage(
                runtime: appRuntime,
                loadAddress: entryPoint,
                uartBase: uartBase
            )
        ).load(into: vm)
    }
}

public extension MobileOSImageBootAdapter {
    init(
        runtime: String,
        loadAddress: GuestAddress = ARM64VizMachineLayout.toyEntryPoint,
        uartBase: GuestAddress = ARM64VizMachineLayout.uartBase
    ) {
        self.init(
            image: .developmentImage(
                runtime: runtime,
                loadAddress: loadAddress,
                uartBase: uartBase
            )
        )
    }
}

public enum MobileOSBootLog {
    public static func message(runtime: String) -> String {
        MobileOSImageBootTranscript.render(manifest: MobileOSImage.developmentImage(runtime: runtime).manifest)
    }
}

public enum ToyUARTProgram {
    public static func image(message: String, uartBase: GuestAddress) -> [UInt8] {
        var instructions: [UInt32] = []
        instructions.append(contentsOf: loadImmediate64(register: 0, value: uartBase))

        for byte in message.utf8 {
            instructions.append(movz(register: 1, immediate: UInt16(byte), shift: 0))
            instructions.append(strbUnsigned(source: 1, base: 0, offset: 0))
        }

        instructions.append(hlt())
        return instructions.flatMap(littleEndianBytes)
    }

    public static func loadImmediate64(register: Int, value: UInt64) -> [UInt32] {
        var result: [UInt32] = []
        result.append(movz(register: register, immediate: UInt16(value & 0xffff), shift: 0))

        for shift in stride(from: 16, through: 48, by: 16) {
            let chunk = UInt16((value >> UInt64(shift)) & 0xffff)
            if chunk != 0 {
                result.append(movk(register: register, immediate: chunk, shift: shift))
            }
        }

        return result
    }

    public static func movz(register: Int, immediate: UInt16, shift: Int) -> UInt32 {
        0xd280_0000 | wideImmediateFields(register: register, immediate: immediate, shift: shift)
    }

    public static func movk(register: Int, immediate: UInt16, shift: Int) -> UInt32 {
        0xf280_0000 | wideImmediateFields(register: register, immediate: immediate, shift: shift)
    }

    public static func strbUnsigned(source: Int, base: Int, offset: UInt16) -> UInt32 {
        0x3900_0000 | (UInt32(offset) << 10) | (UInt32(base & 0x1f) << 5) | UInt32(source & 0x1f)
    }

    public static func hlt(immediate: UInt16 = 0) -> UInt32 {
        0xd440_0000 | (UInt32(immediate) << 5)
    }

    private static func wideImmediateFields(register: Int, immediate: UInt16, shift: Int) -> UInt32 {
        precondition(shift % 16 == 0 && shift >= 0 && shift <= 48)
        let hw = UInt32(shift / 16)
        return (hw << 21) | (UInt32(immediate) << 5) | UInt32(register & 0x1f)
    }

    private static func littleEndianBytes(_ word: UInt32) -> [UInt8] {
        [
            UInt8(word & 0xff),
            UInt8((word >> 8) & 0xff),
            UInt8((word >> 16) & 0xff),
            UInt8((word >> 24) & 0xff)
        ]
    }
}
