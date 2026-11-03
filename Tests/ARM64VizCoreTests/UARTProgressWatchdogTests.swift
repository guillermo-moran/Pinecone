import XCTest
@testable import ARM64VizCore

final class UARTProgressWatchdogTests: XCTestCase {
    private func feed(
        _ text: String,
        to watchdog: UARTProgressWatchdog,
        startingAt timestamp: UInt64
    ) {
        for (offset, byte) in text.utf8.enumerated() {
            watchdog.observe(byte: byte, atNanoseconds: timestamp + UInt64(offset))
        }
    }

    func testArbitraryUARTTrafficDoesNotRenewDeadline() {
        let watchdog = UARTProgressWatchdog(
            timeoutNanoseconds: 100,
            milestones: ["kernel-ready"],
            startedAtNanoseconds: 1_000
        )
        feed("repeated warning\nrepeated warning\n", to: watchdog, startingAt: 1_050)

        let snapshot = watchdog.snapshot(atNanoseconds: 1_100)

        XCTAssertTrue(snapshot.timedOut)
        XCTAssertEqual(snapshot.reachedMilestones, [])
        XCTAssertEqual(snapshot.nextMilestone, "kernel-ready")
        XCTAssertEqual(snapshot.remainingNanoseconds, 0)
        XCTAssertFalse(snapshot.completed)
    }

    func testSplitMilestoneRenewsDeadlineAtFinalByte() {
        let watchdog = UARTProgressWatchdog(
            timeoutNanoseconds: 100,
            milestones: ["Linux version "],
            startedAtNanoseconds: 500
        )
        feed("Linux ver", to: watchdog, startingAt: 550)
        XCTAssertTrue(watchdog.snapshot(atNanoseconds: 600).timedOut)

        feed("sion ", to: watchdog, startingAt: 601)
        let snapshot = watchdog.snapshot(atNanoseconds: 650)

        XCTAssertFalse(snapshot.timedOut)
        XCTAssertEqual(snapshot.reachedMilestones, ["Linux version "])
        XCTAssertNil(snapshot.nextMilestone)
        XCTAssertGreaterThan(snapshot.remainingNanoseconds, 0)
        XCTAssertTrue(snapshot.completed)
    }

    func testLaterMilestoneAdvancesWhenEarlierLogLinesAreAbsent() {
        let watchdog = UARTProgressWatchdog(
            timeoutNanoseconds: 1_000,
            milestones: ["Booting Linux", "Run /init as init process", "SurfaceFlinger"],
            startedAtNanoseconds: 10
        )

        feed("log: SurfaceFlinger starting", to: watchdog, startingAt: 100)
        let snapshot = watchdog.snapshot(atNanoseconds: 200)

        XCTAssertEqual(
            snapshot.reachedMilestones,
            ["Booting Linux", "Run /init as init process", "SurfaceFlinger"]
        )
        XCTAssertNil(snapshot.nextMilestone)
        XCTAssertFalse(snapshot.timedOut)
        XCTAssertFalse(watchdog.snapshot(atNanoseconds: 10_000).timedOut)
    }

    func testRepeatedMilestoneDoesNotRenewAfterItWasReached() {
        let watchdog = UARTProgressWatchdog(
            timeoutNanoseconds: 100,
            milestones: ["init-ready", "launcher-ready"],
            startedAtNanoseconds: 0
        )
        feed("init-ready", to: watchdog, startingAt: 10)
        feed("init-ready", to: watchdog, startingAt: 80)

        XCTAssertTrue(watchdog.snapshot(atNanoseconds: 120).timedOut)
        XCTAssertEqual(watchdog.snapshot(atNanoseconds: 120).nextMilestone, "launcher-ready")
    }

    func testIncidentalAndroidComponentNamesDoNotCompleteBuiltInMilestones() {
        let watchdog = UARTProgressWatchdog(
            timeoutNanoseconds: 1_000,
            startedAtNanoseconds: 0
        )

        feed(
            "monitoring for sys.boot_completed=1\n" +
                "android.permission.RECEIVE_BOOT_COMPLETED\n" +
                "/product/overlay/SystemUI-overlay.apk\n" +
                "serviceName: SurfaceFlinger\n",
            to: watchdog,
            startingAt: 10
        )

        let snapshot = watchdog.snapshot(atNanoseconds: 500)
        XCTAssertFalse(snapshot.completed)
        XCTAssertEqual(snapshot.reachedMilestones, [])
        XCTAssertEqual(snapshot.nextMilestone, "Booting Linux")
    }

    func testActualBootCompletedInitActionCompletesWatchdog() {
        let watchdog = UARTProgressWatchdog(timeoutNanoseconds: 1_000, startedAtNanoseconds: 0)
        feed("init: processing action (sys.boot_completed=1) from (/system/etc/init/hw/init.rc:1)\n",
             to: watchdog, startingAt: 10)
        XCTAssertTrue(watchdog.snapshot(atNanoseconds: 500).completed)
    }
}
