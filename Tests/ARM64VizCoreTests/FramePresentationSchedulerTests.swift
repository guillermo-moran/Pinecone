import Foundation
import XCTest
@testable import ARM64VizCore

final class FramePresentationSchedulerTests: XCTestCase {
    private let fullDamage = VirtualFramebufferDamage(x: 0, y: 0, width: 4, height: 4)

    private func metadata(
        _ generation: UInt64,
        time: UInt64? = nil,
        width: Int = 4,
        damage: [VirtualFramebufferDamage]? = nil
    ) -> VirtualFramebufferFrameMetadata {
        VirtualFramebufferFrameMetadata(
            width: width, height: 4, stride: width * 4, bytesPerPixel: 4,
            generation: generation, commitTimestampNanoseconds: time ?? generation,
            damage: damage ?? [VirtualFramebufferDamage(x: 0, y: 0, width: width, height: 4)],
            hasStableStorage: true
        )
    }

    private final class Pixels {
        let pointer: UnsafeMutableRawPointer
        init() {
            pointer = .allocate(byteCount: 256, alignment: 16)
            pointer.initializeMemory(as: UInt8.self, repeating: 0x7f, count: 256)
        }
        deinit { pointer.deallocate() }
    }

    private final class ReleaseCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private func lease(
        _ metadata: VirtualFramebufferFrameMetadata,
        release: ReleaseCount? = nil
    ) -> VirtualFramebufferFrameLease {
        let pixels = Pixels()
        return VirtualFramebufferFrameLease(
            metadata: metadata, storageOwner: pixels,
            baseAddress: UnsafeRawPointer(pixels.pointer), byteCount: 256,
            releaseHandler: { release?.increment() }
        )
    }

    @discardableResult
    private func present(
        _ metadata: VirtualFramebufferFrameMetadata,
        with scheduler: FramePresentationScheduler
    ) throws -> FramePresentationScheduler.Ticket {
        scheduler.receive(metadata)
        let upload = try XCTUnwrap(scheduler.beginRefresh { _ in lease(metadata) })
        XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
        XCTAssertTrue(scheduler.markQueued(upload.ticket))
        XCTAssertTrue(scheduler.complete(upload.ticket, succeeded: true))
        return upload.ticket
    }

    func testNotificationsCoalesceWithoutAcquiringAndDamageUsesActualUpload() throws {
        let scheduler = FramePresentationScheduler()
        try present(metadata(1), with: scheduler)
        let first = VirtualFramebufferDamage(x: 0, y: 0, width: 1, height: 1)
        let second = VirtualFramebufferDamage(x: 3, y: 3, width: 1, height: 1)
        scheduler.receive(metadata(2, damage: [first]))
        scheduler.receive(metadata(3, damage: [second]))
        XCTAssertEqual(scheduler.uploadedGeneration, 1)
        XCTAssertEqual(scheduler.displayedGeneration, 1)
        XCTAssertFalse(scheduler.isBusy)
        var acquisitions = 0
        let upload = try XCTUnwrap(scheduler.beginRefresh { previous in
            acquisitions += 1
            XCTAssertEqual(previous, 1)
            // The unchanged frame-lease API supplies damage accumulated since 1.
            return lease(metadata(3, damage: [first, second]))
        })
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(upload.lease.metadata.damage, [first, second])
        XCTAssertEqual(upload.lease.metadata.generation, 3)
        XCTAssertEqual(scheduler.uploadedGeneration, 1)
        XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
        XCTAssertEqual(scheduler.uploadedGeneration, 3)
        XCTAssertNil(scheduler.queuedGeneration)
        XCTAssertTrue(scheduler.markQueued(upload.ticket))
        XCTAssertEqual(scheduler.queuedGeneration, 3)
        XCTAssertEqual(scheduler.displayedGeneration, 1)
        XCTAssertTrue(scheduler.complete(upload.ticket, succeeded: true))
        XCTAssertEqual(scheduler.displayedGeneration, 3)
        XCTAssertNil(scheduler.queuedGeneration)
        XCTAssertFalse(scheduler.needsRefresh)
    }

    func testOneSlotBoundsBacklogAndFencesGPUReads() throws {
        let scheduler = FramePresentationScheduler()
        scheduler.receive(metadata(1))
        let upload = try XCTUnwrap(scheduler.beginRefresh { _ in lease(metadata(1)) })
        for generation in 2...100 {
            scheduler.receive(metadata(UInt64(generation)))
            XCTAssertNil(scheduler.beginRefresh { _ in XCTFail("worker already active"); return nil })
        }
        XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
        XCTAssertTrue(scheduler.markQueued(upload.ticket))
        XCTAssertTrue(scheduler.complete(upload.ticket, succeeded: true))
        let latest = try XCTUnwrap(scheduler.beginRefresh { previous in
            XCTAssertEqual(previous, 1)
            return lease(metadata(100))
        })
        XCTAssertEqual(scheduler.finishUpload(latest.ticket, succeeded: true), .ready)
        XCTAssertTrue(scheduler.markQueued(latest.ticket))
        scheduler.receive(metadata(101))
        XCTAssertNil(scheduler.beginRefresh { _ in XCTFail("GPU still reading slot"); return nil })
        XCTAssertFalse(scheduler.needsRefresh)
        XCTAssertTrue(scheduler.complete(latest.ticket, succeeded: true))
        XCTAssertTrue(scheduler.needsRefresh)
        XCTAssertNotNil(scheduler.beginRefresh { previous in
            XCTAssertEqual(previous, 100)
            return lease(metadata(101))
        })
    }

    func testContinuousArrivalsCannotStarveAnAcquiredRefresh() throws {
        let scheduler = FramePresentationScheduler()
        var generation: UInt64 = 1
        scheduler.receive(metadata(generation))
        for _ in 0..<100 {
            let acquiredGeneration = generation
            let upload = try XCTUnwrap(scheduler.beginRefresh { _ in lease(metadata(acquiredGeneration)) })
            generation += 1
            scheduler.receive(metadata(generation))
            XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
            // Even arrivals after upload completion must not discard a ready frame.
            generation += 1
            scheduler.receive(metadata(generation))
            XCTAssertEqual(scheduler.readyUpload?.ticket, upload.ticket)
            XCTAssertTrue(scheduler.markQueued(upload.ticket))
            generation += 1
            scheduler.receive(metadata(generation))
            XCTAssertTrue(scheduler.complete(upload.ticket, succeeded: true))
            XCTAssertEqual(scheduler.displayedGeneration, acquiredGeneration)
            XCTAssertEqual(scheduler.uploadedGeneration, acquiredGeneration)
            XCTAssertTrue(scheduler.needsRefresh)
        }
    }

    func testUnavailableDrawableKeepsReadyFrameWithoutAnotherUpload() throws {
        let scheduler = FramePresentationScheduler()
        scheduler.receive(metadata(1))
        let upload = try XCTUnwrap(scheduler.beginRefresh { _ in lease(metadata(1)) })
        XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
        for _ in 0..<10 {
            XCTAssertTrue(scheduler.needsRefresh)
            XCTAssertEqual(scheduler.readyUpload?.ticket, upload.ticket)
            XCTAssertNil(scheduler.beginRefresh { _ in XCTFail("ready slot already uploaded"); return nil })
        }
        XCTAssertNil(scheduler.queuedGeneration)
        scheduler.receive(metadata(2))
        XCTAssertEqual(scheduler.readyUpload?.ticket, upload.ticket)
        XCTAssertTrue(scheduler.markQueued(upload.ticket))
        XCTAssertTrue(scheduler.complete(upload.ticket, succeeded: true))
        XCTAssertNotNil(scheduler.beginRefresh { previous in
            XCTAssertEqual(previous, 1)
            return lease(metadata(2))
        })
    }

    func testFailedPartialUploadForcesFullRetryWithoutAdvancingGenerations() throws {
        let scheduler = FramePresentationScheduler()
        try present(metadata(1), with: scheduler)
        scheduler.receive(metadata(2))
        let upload = try XCTUnwrap(scheduler.beginRefresh { _ in lease(metadata(2)) })
        XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: false), .discarded)
        XCTAssertNil(scheduler.uploadedGeneration)
        XCTAssertNil(scheduler.queuedGeneration)
        XCTAssertEqual(scheduler.displayedGeneration, 1)
        XCTAssertTrue(scheduler.needsRefresh)
        XCTAssertNotNil(scheduler.beginRefresh { previous in
            XCTAssertNil(previous)
            return lease(metadata(2))
        })
    }

    func testFailedSubmissionAndGPUCompletionRetryThroughSameCPUStateMachine() throws {
        for wasSubmitted in [false, true] {
            let scheduler = FramePresentationScheduler()
            try present(metadata(1), with: scheduler)
            scheduler.receive(metadata(2))
            let upload = try XCTUnwrap(scheduler.beginRefresh { _ in lease(metadata(2)) })
            XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
            if wasSubmitted { XCTAssertTrue(scheduler.markQueued(upload.ticket)) }
            XCTAssertFalse(scheduler.complete(upload.ticket, succeeded: false))
            XCTAssertNil(scheduler.uploadedGeneration)
            XCTAssertNil(scheduler.queuedGeneration)
            XCTAssertEqual(scheduler.displayedGeneration, 1)
            // A CPU image uses the same success path without requiring a Metal device.
            let fallback = try XCTUnwrap(scheduler.beginRefresh { previous in
                XCTAssertNil(previous)
                return lease(metadata(2))
            })
            XCTAssertEqual(scheduler.finishUpload(fallback.ticket, succeeded: true), .ready)
            XCTAssertTrue(scheduler.markQueued(fallback.ticket))
            XCTAssertTrue(scheduler.complete(fallback.ticket, succeeded: true))
            XCTAssertEqual(scheduler.displayedGeneration, 2)
        }
    }

    func testEmptySourceNoChangeAndEmptyDamageHaveDistinctSemantics() throws {
        let scheduler = FramePresentationScheduler()
        XCTAssertFalse(scheduler.needsRefresh)
        XCTAssertNil(scheduler.beginRefresh { _ in XCTFail("no metadata"); return nil })
        scheduler.receive(metadata(1))
        XCTAssertNil(scheduler.beginRefresh { _ in nil })
        XCTAssertTrue(scheduler.needsRefresh)
        try present(metadata(1), with: scheduler)
        scheduler.receive(metadata(1))
        XCTAssertNil(scheduler.beginRefresh { _ in XCTFail("unchanged frame"); return nil })
        let emptyDamage = metadata(2, damage: [])
        XCTAssertEqual(FramePresentationUploadPlan(metadata: emptyDamage, requiresFullUpload: false)?.damage, [])
        try present(emptyDamage, with: scheduler)
        XCTAssertEqual(scheduler.displayedGeneration, 2)
    }

    func testLeaseCanBeNewerThanNotificationAndOldNotificationsAreIgnored() throws {
        let scheduler = FramePresentationScheduler()
        scheduler.receive(metadata(1))
        let upload = try XCTUnwrap(scheduler.beginRefresh { _ in lease(metadata(3)) })
        scheduler.receive(metadata(2))
        XCTAssertEqual(scheduler.latestGeneration, 3)
        XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
        XCTAssertTrue(scheduler.markQueued(upload.ticket))
        XCTAssertTrue(scheduler.complete(upload.ticket, succeeded: true))
        XCTAssertFalse(scheduler.needsRefresh)
    }

    func testResetRetainsWorkerLeaseAndRejectsItsResult() throws {
        let scheduler = FramePresentationScheduler()
        let releases = ReleaseCount()
        scheduler.receive(metadata(7))
        var upload = scheduler.beginRefresh { _ in lease(metadata(7), release: releases) }
        let ticket = try XCTUnwrap(upload?.ticket)
        weak var retainedLease = upload?.lease
        upload = nil
        scheduler.reset()
        scheduler.receive(metadata(7, time: 8))
        XCTAssertNotNil(retainedLease)
        XCTAssertEqual(releases.value, 0)
        XCTAssertNil(scheduler.beginRefresh { _ in XCTFail("old worker has slot"); return nil })
        XCTAssertEqual(scheduler.finishUpload(ticket, succeeded: true), .discarded)
        XCTAssertNil(retainedLease)
        XCTAssertEqual(releases.value, 1)
        XCTAssertNil(scheduler.uploadedGeneration)
        XCTAssertNil(scheduler.displayedGeneration)
        XCTAssertNotNil(scheduler.beginRefresh { previous in
            XCTAssertNil(previous)
            return lease(metadata(7, time: 8))
        })
    }

    func testResetRetainsGPULeaseUntilCompletionAndRejectsOldCompletions() throws {
        let scheduler = FramePresentationScheduler()
        let releases = ReleaseCount()
        scheduler.receive(metadata(9))
        var upload = scheduler.beginRefresh { _ in lease(metadata(9), release: releases) }
        let ticket = try XCTUnwrap(upload?.ticket)
        weak var retainedLease = upload?.lease
        upload = nil
        XCTAssertEqual(scheduler.finishUpload(ticket, succeeded: true), .ready)
        XCTAssertTrue(scheduler.markQueued(ticket))
        scheduler.reset()
        scheduler.reset()
        scheduler.receive(metadata(1, time: 10))
        XCTAssertNotNil(retainedLease)
        retainedLease?.withUnsafeBytes { XCTAssertEqual($0[0], 0x7f) }
        XCTAssertFalse(scheduler.isCurrent(ticket))
        XCTAssertNil(scheduler.queuedGeneration)
        XCTAssertNil(scheduler.beginRefresh { _ in XCTFail("old GPU has slot"); return nil })
        XCTAssertFalse(scheduler.complete(ticket, succeeded: true))
        XCTAssertNil(retainedLease)
        XCTAssertEqual(releases.value, 1)
        try present(metadata(1, time: 10), with: scheduler)
        XCTAssertFalse(scheduler.complete(ticket, succeeded: true))
        XCTAssertEqual(scheduler.finishUpload(ticket, succeeded: false), .discarded)
        XCTAssertEqual(scheduler.displayedGeneration, 1)
        XCTAssertEqual(scheduler.uploadedGeneration, 1)
    }

    func testResetDropsUnsubmittedReadyLeaseImmediately() throws {
        let scheduler = FramePresentationScheduler()
        scheduler.receive(metadata(1))
        var upload = scheduler.beginRefresh { _ in lease(metadata(1)) }
        let ticket = try XCTUnwrap(upload?.ticket)
        weak var retainedLease = upload?.lease
        upload = nil
        XCTAssertEqual(scheduler.finishUpload(ticket, succeeded: true), .ready)
        scheduler.reset()
        XCTAssertNil(retainedLease)
        XCTAssertFalse(scheduler.markQueued(ticket))
        XCTAssertFalse(scheduler.isBusy)
        XCTAssertFalse(scheduler.needsRefresh)
    }

    func testWrapAndSourceWrappingAfterNotificationRequestFullDamage() throws {
        for sourceWrapsLate in [false, true] {
            let scheduler = FramePresentationScheduler()
            try present(metadata(.max - 1, time: 1), with: scheduler)
            scheduler.receive(metadata(sourceWrapsLate ? .max : 0, time: 2))
            var requests: [UInt64?] = []
            let upload = try XCTUnwrap(scheduler.beginRefresh { previous in
                requests.append(previous)
                return lease(metadata(0, time: 3))
            })
            if sourceWrapsLate {
                XCTAssertEqual(requests.count, 2)
                XCTAssertEqual(requests[0], .max - 1)
                XCTAssertNil(requests[1])
            } else {
                XCTAssertEqual(requests.count, 1)
                XCTAssertNil(requests[0])
            }
            XCTAssertEqual(scheduler.finishUpload(upload.ticket, succeeded: true), .ready)
            XCTAssertTrue(scheduler.markQueued(upload.ticket))
            XCTAssertTrue(scheduler.complete(upload.ticket, succeeded: true))
            XCTAssertEqual(scheduler.displayedGeneration, 0)
        }
    }

    func testLayoutChangeAndRedrawReacquireFullFrame() throws {
        let scheduler = FramePresentationScheduler()
        try present(metadata(1), with: scheduler)
        scheduler.requestRedraw()
        let redraw = try XCTUnwrap(scheduler.beginRefresh { previous in
            XCTAssertNil(previous)
            return lease(metadata(1))
        })
        XCTAssertEqual(scheduler.finishUpload(redraw.ticket, succeeded: true), .ready)
        XCTAssertTrue(scheduler.markQueued(redraw.ticket))
        XCTAssertTrue(scheduler.complete(redraw.ticket, succeeded: true))
        scheduler.receive(metadata(2, width: 8))
        XCTAssertNotNil(scheduler.beginRefresh { previous in
            XCTAssertNil(previous)
            return lease(metadata(2, width: 8))
        })
    }

    func testUploadPlanValidatesFullEmptyAndMalformedDamage() {
        let empty = metadata(1, damage: [])
        let full = FramePresentationUploadPlan(metadata: empty, requiresFullUpload: true)
        XCTAssertEqual(full?.byteCount, 64)
        XCTAssertEqual(full?.damage, [fullDamage])
        let invalid = metadata(1, damage: [VirtualFramebufferDamage(x: 3, y: 3, width: 2, height: 1)])
        XCTAssertNil(FramePresentationUploadPlan(metadata: invalid, requiresFullUpload: false))
        for (width, height, stride, bytesPerPixel) in [
            (0, 4, 16, 4), (4, 0, 16, 4), (4, 4, 15, 4),
            (4, 4, 16, 3), (Int.max, 1, Int.max, 4), (4, Int.max, 16, 4)
        ] {
            let invalid = VirtualFramebufferFrameMetadata(
                width: width, height: height, stride: stride, bytesPerPixel: bytesPerPixel,
                generation: 1, commitTimestampNanoseconds: 1, damage: []
            )
            XCTAssertNil(FramePresentationUploadPlan(metadata: invalid, requiresFullUpload: true))
        }
    }
}
