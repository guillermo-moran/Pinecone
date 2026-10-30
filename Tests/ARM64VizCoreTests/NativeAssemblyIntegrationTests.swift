import XCTest
@testable import ARM64VizCore

final class NativeAssemblyIntegrationTests: XCTestCase {
    func testPlatformDefaultAndEnvironmentOverride() {
        let backend = SoftwareARM64Backend()
        let override = ProcessInfo.processInfo.environment["PINECONE_ASSEMBLY_EXECUTOR"]
#if os(iOS)
        let requested = override.map { $0 == "1" } ?? true
#else
        let requested = override == "1"
#endif
#if arch(arm64) && canImport(Darwin)
        let available = requested
#else
        let available = false
#endif
        XCTAssertEqual(backend.nativeAssemblyStatistics["enabled"], available ? 1 : 0)
        XCTAssertEqual(backend.nativeAssemblyStatistics["chainEnabled"],
                       available && ProcessInfo.processInfo.environment["PINECONE_ASSEMBLY_CHAINING"] == "1" ? 1 : 0)
        if requested {
            XCTAssertEqual(backend.nativeThreadedPrototypeStatistics["enabled"], 0)
        }
    }

    func testBoundedGraphBudgetsInvalidationAndIndependentOptOut() throws {
        let reference = try makeVM(assembly: false)
        let candidate = try makeVM(assembly: true)
        candidate.1.setNativeAssemblyChainingEnabled(true)
        candidate.1.setNativeAssemblyBoundedEnabled(true)
        guard candidate.1.nativeAssemblyStatistics["boundedEnabled"] == 1 else {
            throw XCTSkip("Bounded assembly requires Darwin arm64")
        }
        for vm in [reference.0, candidate.0] {
            XCTAssertTrue(try vm.writeGuestRAMFast(vm.cpu.pc + 4, width: .word, value: 0x17ffffff))
        }
        for budget in [4096, 1, 31, 1023, 1024, 1025, 8192] {
            let expected = try reference.0.run(maxSteps: budget)
            let actual = try candidate.0.run(maxSteps: budget)
            XCTAssertEqual(actual.steps, expected.steps)
            XCTAssertEqual(actual.stopReason, expected.stopReason)
            XCTAssertEqual(candidate.0.cpu.x, reference.0.cpu.x)
            XCTAssertEqual(candidate.0.cpu.pc, reference.0.cpu.pc)
            XCTAssertEqual(candidate.0.cpu.pstate, reference.0.cpu.pstate)
        }
        let counters = candidate.1.nativeAssemblyStatistics
        XCTAssertGreaterThan(counters["boundedSteps", default: 0], 0)
        XCTAssertGreaterThan(counters["boundedVisits", default: 0], counters["boundedRuns", default: 0])
        for vm in [reference.0, candidate.0] {
            XCTAssertTrue(try vm.writeGuestRAMFast(0x1000, width: .word, value: 0x91000800))
        }
        _ = try reference.0.run(maxSteps: 4096)
        _ = try candidate.0.run(maxSteps: 4096)
        XCTAssertEqual(candidate.0.cpu.x, reference.0.cpu.x)
        XCTAssertEqual(candidate.0.cpu.pc, reference.0.cpu.pc)
        candidate.1.setNativeAssemblyBoundedEnabled(false)
        let before = candidate.1.nativeAssemblyStatistics["boundedSteps"]
        _ = try candidate.0.run(maxSteps: 4096)
        XCTAssertEqual(candidate.1.nativeAssemblyStatistics["boundedSteps"], before)
        XCTAssertEqual(candidate.1.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertTrue(candidate.1.unsupportedInstructionCounts.isEmpty)
    }

    func testBoundedFlagAloneDoesNotEnableChaining() throws {
        let (vm, backend) = try makeVM(assembly: true)
        backend.setNativeAssemblyBoundedEnabled(true)
        _ = try vm.run(maxSteps: 4096)
        XCTAssertEqual(backend.nativeAssemblyStatistics["chainRuns"], 0)
        XCTAssertEqual(backend.nativeAssemblyStatistics["boundedRuns"], 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }
    func testChainingFlagAloneDoesNotSelectAssembly() throws {
        let (vm, backend) = try makeVM(assembly: false)
        backend.setNativeAssemblyChainingEnabled(true)
        let result = try vm.run(maxSteps: 4096)
        XCTAssertEqual(result.steps, 4096)
        XCTAssertEqual(backend.nativeAssemblyStatistics["enabled"], 0)
        XCTAssertEqual(backend.nativeAssemblyStatistics["steps"], 0)
        XCTAssertEqual(backend.nativeAssemblyStatistics["chainRuns"], 0)
        XCTAssertEqual(backend.nativeAssemblyStatistics["chainSteps"], 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testAssemblyChainSelfLoopBudgetsAndInvalidation() throws {
        let reference = try makeVM(assembly: false)
        let candidate = try makeVM(assembly: true)
        candidate.1.setNativeAssemblyChainingEnabled(true)
        guard candidate.1.nativeAssemblyStatistics["chainEnabled"] == 1 else {
            throw XCTSkip("Assembly chaining requires Darwin arm64")
        }
        for vm in [reference.0, candidate.0] {
            XCTAssertTrue(try vm.writeGuestRAMFast(vm.cpu.pc + 4, width: .word,
                                                 value: 0x17ffffff)) // b start
        }
        for budget in [4096, 1, 31, 4096, 3, 8192] {
            let expected = try reference.0.run(maxSteps: budget)
            let actual = try candidate.0.run(maxSteps: budget)
            XCTAssertEqual(actual.steps, expected.steps)
            XCTAssertEqual(actual.stopReason, expected.stopReason)
            XCTAssertEqual(candidate.0.cpu.x, reference.0.cpu.x)
            XCTAssertEqual(candidate.0.cpu.pc, reference.0.cpu.pc)
            XCTAssertEqual(candidate.0.cpu.pstate, reference.0.cpu.pstate)
        }
        let stats = candidate.1.nativeAssemblyStatistics
        XCTAssertGreaterThan(stats["chainSteps", default: 0], 0)
        XCTAssertGreaterThan(stats["chainVisits", default: 0], stats["chainRuns", default: 0])
        // Replace enrolled code after a warm chain; stale snapshots must not run.
        for vm in [reference.0, candidate.0] {
            XCTAssertTrue(try vm.writeGuestRAMFast(0x1000, width: .word, value: 0x91000800))
        }
        let expected = try reference.0.run(maxSteps: 4096)
        let actual = try candidate.0.run(maxSteps: 4096)
        XCTAssertEqual(actual.steps, expected.steps)
        XCTAssertEqual(candidate.0.cpu.x, reference.0.cpu.x)
        XCTAssertEqual(candidate.0.cpu.pc, reference.0.cpu.pc)
        XCTAssertEqual(candidate.1.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertTrue(candidate.1.unsupportedInstructionCounts.isEmpty)

        candidate.1.setNativeAssemblyChainingEnabled(false)
        let before = candidate.1.nativeAssemblyStatistics["chainSteps"]
        _ = try candidate.0.run(maxSteps: 4096)
        XCTAssertEqual(candidate.1.nativeAssemblyStatistics["chainSteps"], before)
        XCTAssertEqual(candidate.1.nativeAssemblyStatistics["chainEnabled"], 0)
    }

    func testAssemblyEligibilityPreservesSuperblockExecution() throws {
        let reference = try makeVM(assembly: false)
        let candidate = try makeVM(assembly: true)
        guard candidate.1.nativeAssemblyStatistics["enabled"] == 1 else {
            throw XCTSkip("Precompiled assembly requires Darwin arm64")
        }
        // Every block is assembly-eligible, so eligibility must not prevent
        // observed successors from becoming a native C superblock.
        for vm in [reference.0, candidate.0] {
            XCTAssertTrue(try vm.writeGuestRAMFast(vm.cpu.pc + 8, width: .word,
                                                  value: 0x91000442)) // add x2, x2, #1
        }
        for budget in [4096, 1, 31, 4096, 3, 8192] {
            let expected = try reference.0.run(maxSteps: budget)
            let actual = try candidate.0.run(maxSteps: budget)
            XCTAssertEqual(actual.steps, expected.steps)
            XCTAssertEqual(actual.stopReason, expected.stopReason)
            XCTAssertEqual(candidate.0.cpu.x, reference.0.cpu.x)
            XCTAssertEqual(candidate.0.cpu.pc, reference.0.cpu.pc)
            XCTAssertEqual(candidate.0.cpu.pstate, reference.0.cpu.pstate)
        }
        XCTAssertGreaterThan(reference.1.nativeSuperblockDispatches, 0)
        XCTAssertGreaterThan(candidate.1.nativeSuperblockDispatches, 0)
        XCTAssertEqual(candidate.1.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertTrue(candidate.1.unsupportedInstructionCounts.isEmpty)
    }

    func testCacheDiagnosticsPublicationAndDisablePreserveExecution() throws {
        let (vm, backend) = try makeVM(assembly: true)
        let compiled = backend.nativeAssemblyCacheDiagnostics["compiled"] == 1
        XCTAssertEqual(backend.configureAssemblyCacheDiagnostics(enabled: true, timing: true), compiled)
        let initial = backend.nativeAssemblyCacheDiagnostics
        _ = try vm.run(maxSteps: 4096)
        backend.publishAssemblyCacheDiagnostics(force: true)
        let active = backend.nativeAssemblyCacheDiagnostics
        XCTAssertEqual(active["enabled"], compiled ? 1 : 0)
        XCTAssertGreaterThan(active["capacity", default: 0], 256)
        XCTAssertGreaterThan(active["programByteBudget", default: 0], 0)
        XCTAssertLessThanOrEqual(active["ownedProgramBytes", default: 0],
                                 active["programByteBudget", default: 0])
        XCTAssertLessThanOrEqual(active["protectedProgramBytes", default: 0],
                                 active["protectedByteBudget", default: 0])
        XCTAssertLessThanOrEqual(active["peakAdmissionRetirements", default: 0],
                                 active["maxRetirementsPerAdmission", default: 0])
        XCTAssertGreaterThanOrEqual(active["publishedHostNanoseconds", default: 0],
                                    initial["publishedHostNanoseconds", default: 0])
        if compiled && backend.nativeAssemblyStatistics["enabled"] == 1 {
            XCTAssertGreaterThan(active["hits", default: 0], 0)
            XCTAssertGreaterThan(active["preparations", default: 0], 0)
            XCTAssertEqual(active["evictionsWithFreeSlots"], 0)
        } else {
            XCTAssertEqual(active["requests"], 0)
        }
        let owned = active["ownedPrograms"]
        backend.configureAssemblyCacheDiagnostics(enabled: false)
        XCTAssertEqual(backend.nativeAssemblyCacheDiagnostics["ownedPrograms"], owned)
        XCTAssertEqual(backend.nativeAssemblyCacheDiagnostics["enabled"], 0)
        _ = try vm.run(maxSteps: 4096)
        backend.publishAssemblyCacheDiagnostics(force: true)
        XCTAssertEqual(backend.nativeAssemblyCacheDiagnostics["requests"], 0)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    func testMixedAssemblyAndNativeCRemainNativeOnly() throws {
        let reference = try makeVM(assembly: false)
        let candidate = try makeVM(assembly: true)
        candidate.1.setNativeAssemblyChainingEnabled(true)
        guard candidate.1.nativeAssemblyStatistics["enabled"] == 1 else {
            throw XCTSkip("Precompiled assembly requires Darwin arm64")
        }
        for budget in [1, 2, 3, 31, 32, 33, 4096] {
            let expected = try reference.0.run(maxSteps: budget)
            let actual = try candidate.0.run(maxSteps: budget)
            XCTAssertEqual(actual.steps, expected.steps)
            XCTAssertEqual(actual.stopReason, expected.stopReason)
            XCTAssertEqual(candidate.0.cpu.x, reference.0.cpu.x)
            XCTAssertEqual(candidate.0.cpu.pc, reference.0.cpu.pc)
            XCTAssertEqual(candidate.0.cpu.pstate, reference.0.cpu.pstate)
        }
        XCTAssertGreaterThan(candidate.1.nativeAssemblyStatistics["steps", default: 0], 0)
        XCTAssertEqual(candidate.1.swiftFallbackSingleInstructionSteps, 0)
        XCTAssertEqual(candidate.1.decodedBasicBlockSteps, 0)
        XCTAssertEqual(candidate.1.nativeThreadedPrototypeStatistics["steps"], 0)
        XCTAssertTrue(candidate.1.unsupportedInstructionCounts.isEmpty)
        XCTAssertGreaterThan(candidate.1.nativeSuperblockDispatches, 0)

        let before = candidate.1.nativeAssemblyStatistics["steps"]
        candidate.1.setNativeAssemblyExecutorEnabled(false)
        _ = try candidate.0.run(maxSteps: 128)
        XCTAssertEqual(candidate.1.nativeAssemblyStatistics["steps"], before)
        XCTAssertEqual(candidate.1.swiftFallbackSingleInstructionSteps, 0)
    }

    func testCodeWriteInvalidatesAssemblySnapshot() throws {
        let (vm, backend) = try makeVM(assembly: true)
        guard backend.nativeAssemblyStatistics["enabled"] == 1 else {
            throw XCTSkip("Precompiled assembly requires Darwin arm64")
        }
        let base = vm.cpu.pc
        _ = try vm.run(maxSteps: 4)
        XCTAssertEqual(vm.cpu.x[0], 1)
        XCTAssertTrue(try vm.writeGuestRAMFast(base, width: .word, value: 0x91000800))
        _ = try vm.run(maxSteps: 4)
        XCTAssertEqual(vm.cpu.x[0], 3)
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
    }

    private func makeVM(assembly: Bool) throws -> (VirtualMachine, SoftwareARM64Backend) {
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        backend.setNativeThreadedPrototypeEnabled(false)
        backend.setNativeAssemblyExecutorEnabled(assembly)
        backend.setNativeAssemblyChainingEnabled(false)
        backend.setNativeAssemblyBoundedEnabled(false)
        let base = ARM64VizMachineLayout.ramBase
        let memory = PhysicalMemory(base: base, size: 64 * 1024)
        let vm = VirtualMachine(memory: memory, backend: backend)
        let code = base + 0x8000
        try memory.write64((base + 0x2000) | 3, at: base + 0x1000)
        try memory.write64((base + 0x3000) | 3, at: base + 0x2000)
        try memory.write64((base + 0x4000) | 3, at: base + 0x3000)
        try memory.write64(code | 0x403, at: base + 0x4008)
        let words: [UInt32] = [
            0x91000400, // add x0, x0, #1 (assembly)
            0x14000001, // b next block
            0x9b007c02, // mul x2, x0, x0 (established native C)
            0x17fffffd, // b start
        ]
        for (index, word) in words.enumerated() {
            try memory.write32(word, at: code + UInt64(index * 4))
        }
        vm.reset(entryPoint: 0x1000)
        vm.cpu.pstate = ARM64PState.el1h
        vm.writeSystemRegister(ARM64SystemRegister.ttbr0EL1, value: base + 0x1000)
        vm.writeSystemRegister(ARM64SystemRegister.tcrEL1, value: 16)
        vm.writeSystemRegister(ARM64SystemRegister.sctlrEL1, value: 1)
        vm.disableInstructionTrace()
        vm.enableMMIOTrace(capacity: 0)
        vm.enableGuestMemoryTrace(capacity: 0)
        vm.systemRegisterTraceCapacity = 0
        vm.systemRegisterReadTraceCapacity = 0
        vm.timerCyclesPerInstruction = 0
        return (vm, backend)
    }
}
