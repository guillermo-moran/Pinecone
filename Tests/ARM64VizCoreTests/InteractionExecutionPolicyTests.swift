import XCTest
@testable import ARM64VizCore

@available(macOS 12.0, iOS 15.0, *)
final class InteractionExecutionPolicyTests: XCTestCase {
    func testPacingWakeBetweenEligibilityCheckAndWaitIsNotLost() async {
        let wake = HostWakeSignal()
        let generationBeforeDecision = wake.currentGeneration
        // Mirrors input arriving after pacing was approved, before suspension.
        wake.signal()
        let resumed = expectation(description: "stale generation skips pacing")
        let task = Task {
            await wake.wait(after: generationBeforeDecision, timeoutNanoseconds: 60_000_000_000)
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 1)
        task.cancel()
        await task.value
        XCTAssertNotEqual(wake.currentGeneration, generationBeforeDecision)
    }

    func testConcurrentWakeAndRegistrationResumeAllWaiters() async {
        let wake = HostWakeSignal()
        let generation = wake.currentGeneration
        let resumed = expectation(description: "all pacing waiters resume once")
        resumed.expectedFulfillmentCount = 32
        resumed.assertForOverFulfill = true
        let tasks = (0..<32).map { _ in
            Task {
                await wake.wait(after: generation, timeoutNanoseconds: 60_000_000_000)
                resumed.fulfill()
            }
        }
        let producer = Task {
            for _ in 0..<32 {
                await Task.yield()
                wake.signal()
            }
        }
        await fulfillment(of: [resumed], timeout: 1)
        await producer.value
        for task in tasks {
            task.cancel()
            await task.value
        }
    }

    func testPacingWaitStillTimesOutWithoutActivity() async {
        let wake = HostWakeSignal()
        let generation = wake.currentGeneration
        let resumed = expectation(description: "pacing deadline fires")
        let task = Task {
            await wake.wait(after: generation, timeoutNanoseconds: 1_000_000)
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 1)
        task.cancel()
        await task.value
        XCTAssertEqual(wake.currentGeneration, generation)
    }

    func testCancelledPacingWaitDoesNotWaitForDeadline() async {
        for cancelBeforeWait in [true, false] {
            let wake = HostWakeSignal()
            let generation = wake.currentGeneration
            let resumed = expectation(description: "cancelled pacing wait resumes")
            let task = Task {
                if cancelBeforeWait {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                await wake.wait(after: generation, timeoutNanoseconds: 60_000_000_000)
                resumed.fulfill()
            }
            if !cancelBeforeWait {
                await Task.yield()
                task.cancel()
            }
            await fulfillment(of: [resumed], timeout: 1)
            task.cancel()
            await task.value
            XCTAssertEqual(wake.currentGeneration, generation)
        }
    }

    func testZeroPacingDelayReturnsWithoutActivity() async {
        let wake = HostWakeSignal()
        let resumed = expectation(description: "zero delay does not register a timer")
        let task = Task {
            await wake.wait(after: wake.currentGeneration, timeoutNanoseconds: 0)
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 1)
        task.cancel()
        await task.value
        XCTAssertEqual(wake.currentGeneration, 0)
    }

    func testFrameQuietPeriodAndWatchdogRemainIndependent() {
        var policy = InteractionExecutionPolicy(watchdogNanoseconds: 5_000, settleNanoseconds: 250)
        policy.input(at: 100, isDown: false)
        policy.frame(at: 110)
        XCTAssertTrue(policy.isLatencySensitive(at: 359))
        XCTAssertFalse(policy.isLatencySensitive(at: 360))
        // A late frame cannot revive a settled interaction or restart its timer.
        policy.frame(at: 400)
        XCTAssertFalse(policy.isLatencySensitive(at: 400))
        policy.input(at: 500, isDown: false)
        XCTAssertTrue(policy.isLatencySensitive(at: 5_499))
        XCTAssertFalse(policy.isLatencySensitive(at: 5_500))
    }

    func testControlMessagesAreHiddenWithoutDelayingShellPrompt() {
        var filter = GuestControlConsoleFilter()
        XCTAssertEqual(String(decoding: filter.append(Array("root # ".utf8)), as: UTF8.self), "root # ")
        XCTAssertEqual(filter.append(Array("\n\u{1e}PINECONE_APP_PRE".utf8)), [10])
        XCTAssertEqual(filter.append(Array("SENTED org.gnome.Settings\r\n".utf8)), [])
        XCTAssertEqual(String(decoding: filter.append(Array("Phosh ready\n".utf8)), as: UTF8.self), "Phosh ready\n")
        XCTAssertEqual(String(decoding: filter.append(Array("P".utf8)), as: UTF8.self), "P")
        XCTAssertEqual(filter.append(Array("\u{1e}PINECONE_APP_PRESENTED org.gnome.Settings\n".utf8)), [])
    }
    func testFirstFrameDoesNotEndGestureOrAnimation() {
        var policy = InteractionExecutionPolicy(watchdogNanoseconds: 5_000, settleNanoseconds: 250)
        policy.input(at: 100, isDown: true)
        policy.frame(at: 110)
        XCTAssertTrue(policy.isLatencySensitive(at: 500))
        policy.input(at: 510, isDown: false)
        policy.frame(at: 520)
        XCTAssertTrue(policy.isLatencySensitive(at: 521))
        policy.frame(at: 700)
        XCTAssertTrue(policy.isLatencySensitive(at: 940))
        XCTAssertFalse(policy.isLatencySensitive(at: 951))
    }

    func testUnrelatedFramesCannotRenewWatchdogForever() {
        var policy = InteractionExecutionPolicy(watchdogNanoseconds: 500, settleNanoseconds: 250)
        policy.input(at: 100, isDown: false)
        policy.frame(at: 550)
        XCTAssertFalse(policy.isLatencySensitive(at: 600))
        policy.frame(at: 601)
        XCTAssertFalse(policy.isLatencySensitive(at: 602))
        policy.input(at: 700, isDown: true)
        XCTAssertTrue(policy.isLatencySensitive(at: 701))
    }

    func testMissingFramesAndClockBoundaries() {
        var policy = InteractionExecutionPolicy(watchdogNanoseconds: 500)
        XCTAssertFalse(policy.isLatencySensitive(at: 0))
        policy.input(at: UInt64.max - 400, isDown: false)
        XCTAssertTrue(policy.isLatencySensitive(at: UInt64.max))
        XCTAssertFalse(policy.isLatencySensitive(at: 0))
    }

    func testControlPresentationIsIndependentOfTraceAndPreservesOrder() {
        var decoder = GuestGraphicsTraceDecoder()
        XCTAssertTrue(decoder.appendRecords(Array("\u{1e}PINECONE_APP_PRE".utf8)).isEmpty)
        let records = decoder.appendRecords(Array(("SENTED org.gnome.Settings\r\n" +
            "Pinecone app launch requested: settings\n" +
            "\u{1e}PINECONE_APP_PRESENTED org.gnome.Settings\n").utf8))
        XCTAssertEqual(records, [.applicationPresented("org.gnome.Settings"),
            .applicationLaunch("settings"), .applicationPresented("org.gnome.Settings")])
        XCTAssertTrue(decoder.appendRecords(Array("\u{1e}PINECONE_APP_PRESENTED invalid app\n".utf8)).isEmpty)
        XCTAssertTrue(decoder.appendRecords(Array("\u{1e}PINECONE_APP_PRESENTED \n".utf8)).isEmpty)
    }
}
