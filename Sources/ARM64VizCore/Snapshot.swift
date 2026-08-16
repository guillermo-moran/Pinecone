import Foundation

public struct VMSnapshot: Codable, Equatable {
    public let version: Int
    public var cpu: CPUState
    public var systemRegisters: ARM64SystemRegisterBank
    public var virtualCPUs: [VirtualCPUArchitecturalState]?
    public var activeVCPUID: Int?
    public var ramBase: GuestAddress
    public var ram: Data
    public var uartOutput: Data
    public var breakpoints: [GuestAddress]

    public init(
        version: Int = 3,
        cpu: CPUState,
        systemRegisters: ARM64SystemRegisterBank,
        virtualCPUs: [VirtualCPUArchitecturalState]? = nil,
        activeVCPUID: Int? = nil,
        ramBase: GuestAddress,
        ram: Data,
        uartOutput: Data,
        breakpoints: [GuestAddress]
    ) {
        self.version = version
        self.cpu = cpu
        self.systemRegisters = systemRegisters
        self.virtualCPUs = virtualCPUs
        self.activeVCPUID = activeVCPUID
        self.ramBase = ramBase
        self.ram = ram
        self.uartOutput = uartOutput
        self.breakpoints = breakpoints
    }
}

public extension VirtualMachine {
    func makeSnapshot() -> VMSnapshot {
        let uart = mmio.allDevices.compactMap { $0 as? VirtualUART }.first
        let states = virtualCPUStates
        return VMSnapshot(
            cpu: states[activeVCPUID].cpu,
            systemRegisters: states[activeVCPUID].systemRegisters,
            virtualCPUs: states,
            activeVCPUID: activeVCPUID,
            ramBase: memory.base,
            ram: Data(memory.snapshotBytes()),
            uartOutput: Data(uart?.outputBytes ?? []),
            breakpoints: Array(breakpoints).sorted()
        )
    }

    func restoreSnapshot(_ snapshot: VMSnapshot) throws {
        guard snapshot.version == 2 || snapshot.version == 3 else {
            throw VMError.invalidSnapshot("unsupported version \(snapshot.version)")
        }
        guard snapshot.ramBase == memory.base else {
            throw VMError.invalidSnapshot("RAM base \(snapshot.ramBase.hexString) does not match \(memory.base.hexString)")
        }

        try memory.restoreBytes(Array(snapshot.ram))
        if snapshot.version == 3,
           let virtualCPUs = snapshot.virtualCPUs,
           let activeVCPUID = snapshot.activeVCPUID {
            try restoreVirtualCPUStates(virtualCPUs, activeVCPUID: activeVCPUID)
        } else {
            var states = virtualCPUStates
            states[0].cpu = snapshot.cpu
            states[0].systemRegisters = snapshot.systemRegisters
            states[0].lifecycle = snapshot.cpu.halted ? .halted : .runnable
            for id in states.indices.dropFirst() {
                states[id].lifecycle = .offline
            }
            try restoreVirtualCPUStates(states, activeVCPUID: 0)
        }
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
