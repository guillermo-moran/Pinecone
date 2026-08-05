import Foundation

public struct VMSnapshot: Codable, Equatable {
    public let version: Int
    public var cpu: CPUState
    public var systemRegisters: ARM64SystemRegisterBank
    public var ramBase: GuestAddress
    public var ram: Data
    public var uartOutput: Data
    public var breakpoints: [GuestAddress]

    public init(
        version: Int = 2,
        cpu: CPUState,
        systemRegisters: ARM64SystemRegisterBank,
        ramBase: GuestAddress,
        ram: Data,
        uartOutput: Data,
        breakpoints: [GuestAddress]
    ) {
        self.version = version
        self.cpu = cpu
        self.systemRegisters = systemRegisters
        self.ramBase = ramBase
        self.ram = ram
        self.uartOutput = uartOutput
        self.breakpoints = breakpoints
    }
}

public extension VirtualMachine {
    func makeSnapshot() -> VMSnapshot {
        let uart = mmio.allDevices.compactMap { $0 as? VirtualUART }.first
        return VMSnapshot(
            cpu: cpu,
            systemRegisters: systemRegisters,
            ramBase: memory.base,
            ram: Data(memory.snapshotBytes()),
            uartOutput: Data(uart?.outputBytes ?? []),
            breakpoints: Array(breakpoints).sorted()
        )
    }

    func restoreSnapshot(_ snapshot: VMSnapshot) throws {
        guard snapshot.version == 2 else {
            throw VMError.invalidSnapshot("unsupported version \(snapshot.version)")
        }
        guard snapshot.ramBase == memory.base else {
            throw VMError.invalidSnapshot("RAM base \(snapshot.ramBase.hexString) does not match \(memory.base.hexString)")
        }

        try memory.restoreBytes(Array(snapshot.ram))
        cpu = snapshot.cpu
        systemRegisters = snapshot.systemRegisters
        refreshCachedTranslationRegisters()
        invalidateTranslationCache()
        backend.invalidateCodeCache(
            physicalAddress: memory.base,
            byteCount: UInt64(memory.size)
        )
        breakpoints = Set(snapshot.breakpoints)

        if let uart = mmio.allDevices.compactMap({ $0 as? VirtualUART }).first {
            uart.replaceOutput(Array(snapshot.uartOutput))
        }
    }
}
