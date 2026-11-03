import ARM64VizNative
import XCTest
@testable import ARM64VizCore

final class ParallelVCPUClockTests: XCTestCase {
    func testRateChangePreservesEpochAndRecomputesDeadlines() {
        let clock = ParallelVCPUClock(ticksPerHostSecond: 6_000_000)
        let oldEpoch = clock.nativeConfiguration
        let before = clock.currentTicks
        clock.setTicksPerHostSecond(24_000_000)
        let newEpoch = clock.nativeConfiguration
        XCTAssertEqual(oldEpoch.frequency, 6_000_000)
        XCTAssertEqual(newEpoch.frequency, 24_000_000)
        XCTAssertGreaterThanOrEqual(newEpoch.counter_anchor, before)
        XCTAssertGreaterThanOrEqual(clock.currentTicks, newEpoch.counter_anchor)
        XCTAssertEqual(clock.nanosecondsUntil(deadlineTicks: before), 0)
        let future = clock.currentTicks + 24_000_000
        XCTAssertGreaterThan(clock.nanosecondsUntil(deadlineTicks: future), 0)
        XCTAssertLessThanOrEqual(clock.nanosecondsUntil(deadlineTicks: future), 1_000_000_000)
        clock.reset()
        XCTAssertEqual(clock.nativeConfiguration.frequency, 6_000_000)
        XCTAssertEqual(clock.nativeConfiguration.counter_anchor, 0)
    }

    func testClusterResetRestoresBootClockAndLeavesCNTFRQUnchanged() throws {
        let machine = try MachineFactory.makeResearchMachine(virtualCPUCount: 2,
            parallelVCPUExecution: true, parallelCounterTicksPerHostSecond: 1_000_000,
            parallelActiveCounterTicksPerHostSecond: 6_000_000)
        let cluster = try XCTUnwrap(machine.parallelVCPUCluster)
        defer { cluster.stop() }
        let interactiveRate = LinuxGuestProfile.lineageOS.recommendedInteractiveCounterTicksPerHostSecond
        cluster.setCounterTicksPerHostSecond(interactiveRate)
        XCTAssertEqual(cluster.counterTicksPerHostSecond, 12_000_000)
        XCTAssertEqual(machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.cntfrqEL0), 24_000_000)
        cluster.setCounterTicksPerHostSecond(0)
        XCTAssertEqual(cluster.counterTicksPerHostSecond, 12_000_000)
        machine.vm.reset(entryPoint: ARM64VizMachineLayout.toyEntryPoint)
        XCTAssertEqual(cluster.counterTicksPerHostSecond, 1_000_000)
    }
}
