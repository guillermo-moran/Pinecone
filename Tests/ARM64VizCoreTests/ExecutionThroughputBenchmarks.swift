import Foundation
import XCTest
@testable import ARM64VizCore

final class ExecutionThroughputBenchmarks: XCTestCase {
    func testCheckpointLoopThroughput() throws {
        guard ProcessInfo.processInfo.environment["PINECONE_BENCHMARK_CHECKPOINT"] == "1" else {
            throw XCTSkip("Opt-in release throughput benchmark")
        }
        let backend = SoftwareARM64Backend()
        backend.fallbackInterpreterPolicy = .nativeOnly
        let machine = try MachineFactory.makeResearchMachine(backend: backend)
        let entry = ARM64VizMachineLayout.toyEntryPoint
        let words: [UInt32] = [0x91000400, 0x17ffffff] // add x0,x0,#1; b .-4
        try machine.vm.loadBinary(words.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { Array($0) }
        }, at: entry)
        machine.vm.reset(entryPoint: entry)
        machine.vm.disableInstructionTrace()
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.vm.enableGuestMemoryTrace(capacity: 0)
        machine.vm.timerCyclesPerInstruction = 0
        machine.vm.nativeCheckpointBlockInterval = UInt64(
            ProcessInfo.processInfo.environment["PINECONE_BENCHMARK_CHECKPOINT_INTERVAL"] ?? "4096"
        ) ?? 4096
        let steps = 40_000_000
        _ = try machine.vm.run(maxSteps: 100_000)
        var times: [UInt64] = []
        for _ in 0..<7 {
            let before = machine.vm.cpu.x[0]
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try machine.vm.run(maxSteps: steps)
            times.append(DispatchTime.now().uptimeNanoseconds - start)
            XCTAssertEqual(machine.vm.cpu.x[0] - before, UInt64(steps / 2))
        }
        XCTAssertEqual(backend.swiftFallbackSingleInstructionSteps, 0)
        print("checkpoint-loop median_ns=\(times.sorted()[3]) samples_ns=\(times)")
    }
}
