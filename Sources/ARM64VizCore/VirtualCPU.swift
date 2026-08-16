public enum VirtualCPULifecycle: String, Codable, Equatable {
    case offline
    case runnable
    case waitingForInterrupt
    case halted
}

public struct VirtualCPUArchitecturalState: Codable, Equatable {
    public let id: Int
    public var cpu: CPUState
    public var systemRegisters: ARM64SystemRegisterBank
    public var lifecycle: VirtualCPULifecycle

    public init(
        id: Int,
        cpu: CPUState,
        systemRegisters: ARM64SystemRegisterBank,
        lifecycle: VirtualCPULifecycle
    ) {
        self.id = id
        self.cpu = cpu
        self.systemRegisters = systemRegisters
        self.lifecycle = lifecycle
    }
}
