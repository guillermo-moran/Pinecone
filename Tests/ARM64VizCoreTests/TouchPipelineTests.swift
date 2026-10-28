import Foundation
import XCTest
@testable import ARM64VizCore

final class TouchPipelineTests: XCTestCase {
    private func sample(_ phase: TouchPhase, _ x: UInt32, _ time: UInt64) -> TimestampedTouchEvent {
        TimestampedTouchEvent(x: x, y: 50, phase: phase, timestampNanoseconds: time)
    }

    func testLegacyDecodeAndTimestampRoundTrip() throws {
        let legacy = try JSONDecoder().decode(TimestampedTouchEvent.self,
            from: Data(#"{"x":2,"y":3,"isDown":true}"#.utf8))
        XCTAssertEqual(legacy, TimestampedTouchEvent(x: 2, y: 3, isDown: true))
        let event = sample(.cancel, 20, 123_456_789)
        XCTAssertEqual(try JSONDecoder().decode(TimestampedTouchEvent.self,
            from: JSONEncoder().encode(event)), event)
    }

    func testMalformedOptionalTimesStillRelease() throws {
        for time in ["-1", "1.5", "null", #""NaN""#, "18446744073709551616", "{}"] {
            let event = try JSONDecoder().decode(TimestampedTouchEvent.self,
                from: Data("{\"x\":2,\"y\":3,\"isDown\":false,\"timestampNanoseconds\":\(time)}".utf8))
            XCTAssertNil(event.timestampNanoseconds)
            var queue = TouchMotionQueue()
            queue.enqueue(sample(.down, 1, 100), nowNanoseconds: 100)
            XCTAssertTrue(queue.enqueue(event, nowNanoseconds: 200))
            XCTAssertEqual(queue.drain().last?.phase, .up)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(TimestampedTouchEvent.self,
            from: Data(#"{"x":2,"y":3,"isDown":false,"phase":"move"}"#.utf8)))
    }

    func testFastSwipeRetainsHistoryAndVelocityUnderDelayedDrain() {
        var queue = TouchMotionQueue(capacity: 32)
        let start: UInt64 = 1_000_000_000
        queue.enqueue(sample(.down, 0, start), nowNanoseconds: start)
        for index in 1...100 {
            queue.enqueue(sample(.move, UInt32(index), start + UInt64(index) * 1_000_000),
                          nowNanoseconds: start + UInt64(index) * 1_000_000)
            XCTAssertLessThanOrEqual(queue.count, 32)
        }
        queue.enqueue(sample(.up, 101, start + 101_000_000), nowNanoseconds: start + 101_000_000)
        let samples = queue.drain()
        XCTAssertEqual(samples.first?.phase, .down)
        XCTAssertEqual(samples.last?.phase, .up)
        XCTAssertEqual(samples[samples.count - 2].x, 101)
        XCTAssertGreaterThan(samples.filter { $0.phase == .move }.count, 20)
        var clock = TouchGuestClockMapping(hostAnchorNanoseconds: start + 500_000_000,
                                           guestAnchorNanoseconds: 10_000_000_000)
        let times = samples.map { clock.map($0.timestampNanoseconds!, guestNowNanoseconds: 10_000_000_000) }
        XCTAssertEqual(times.last! - times.first!, 101_000_000)
        XCTAssertEqual(times[2] - times[1], UInt64(samples[2].x - samples[1].x) * 1_000_000)
    }

    func testOverflowRetainsEveryAdmittedEdgeAndFinalMove() {
        var queue = TouchMotionQueue(capacity: 8)
        for x: UInt32 in [0, 10] {
            XCTAssertTrue(queue.enqueue(sample(.down, x, 10), nowNanoseconds: 10))
            XCTAssertTrue(queue.enqueue(sample(.move, x + 1, 20), nowNanoseconds: 20))
            XCTAssertTrue(queue.enqueue(sample(.cancel, x + 2, 30), nowNanoseconds: 30))
        }
        XCTAssertFalse(queue.enqueue(sample(.down, 50, 40), nowNanoseconds: 40))
        XCTAssertFalse(queue.enqueue(sample(.move, 51, 50), nowNanoseconds: 50))
        XCTAssertFalse(queue.enqueue(sample(.up, 52, 60), nowNanoseconds: 60))
        XCTAssertEqual(queue.rejectedGestureCount, 1)
        let events = queue.drain()
        XCTAssertLessThanOrEqual(events.count, 8)
        XCTAssertEqual(events.filter { $0.phase != .move }.map(\.phase), [.down, .cancel, .down, .cancel])
        for index in events.indices where events[index].phase == .cancel {
            XCTAssertEqual(events[index - 1].phase, .move)
            XCTAssertEqual(events[index - 1].x, events[index].x)
        }
        XCTAssertTrue(queue.enqueue(sample(.down, 80, 70), nowNanoseconds: 70))
    }

    func testDrainingAnActiveContactDoesNotLoseItsReleaseReservation() {
        var queue = TouchMotionQueue(capacity: 4)
        queue.enqueue(sample(.down, 0, 10), nowNanoseconds: 10)
        XCTAssertEqual(queue.popFirst()?.phase, .down)
        for x in 1...1_000 {
            queue.enqueue(sample(.move, UInt32(x), UInt64(x) + 10), nowNanoseconds: UInt64(x) + 10)
            XCTAssertLessThanOrEqual(queue.count, 2)
        }
        XCTAssertTrue(queue.enqueue(sample(.up, 1_001, 2_000), nowNanoseconds: 2_000))
        XCTAssertEqual(queue.drain().map(\.phase), [.move, .move, .move, .up])
        XCTAssertFalse(queue.contactActive)
    }

    func testCoalescingKeepsTheSelectedSamplesTimestamp() {
        var queue = TouchMotionQueue(capacity: 4)
        queue.enqueue(sample(.down, 0, 10), nowNanoseconds: 10)
        queue.enqueue(sample(.move, 1, 20), nowNanoseconds: 20)
        queue.enqueue(sample(.move, 2, 30), nowNanoseconds: 30)
        queue.enqueue(sample(.up, 2, 40), nowNanoseconds: 40)
        XCTAssertEqual(queue.drain().map(\.timestampNanoseconds), [10, 30, 40])
    }

    func testHostHistoryRetainsRecentSamplesEdgesAndDistinctFinalCancelPoint() {
        var queue = TouchMotionQueue(maximumPendingMotionSamplesPerGesture: 2)
        for gesture in 0..<2 {
            let x = UInt32(gesture * 200)
            let time = UInt64(gesture * 200 + 100)
            XCTAssertTrue(queue.enqueue(sample(.down, x, time), nowNanoseconds: 1_000))
            for index in 1...96 {
                XCTAssertTrue(queue.enqueue(sample(.move, x + UInt32(index), time + UInt64(index)),
                                             nowNanoseconds: 1_000))
                XCTAssertLessThanOrEqual(queue.count, gesture * 4 + 3)
            }
            let end = sample(gesture == 0 ? .up : .cancel, x + (gesture == 0 ? 96 : 97), time + 97)
            XCTAssertTrue(queue.enqueue(end, nowNanoseconds: 1_000))
        }
        XCTAssertEqual(queue.drain(), [
            sample(.down, 0, 100), sample(.move, 95, 195), sample(.move, 96, 196), sample(.up, 96, 197),
            sample(.down, 200, 300), sample(.move, 295, 395), sample(.move, 296, 396),
            sample(.move, 297, 397), sample(.cancel, 297, 397)
        ])
        XCTAssertEqual(queue.discardedMotionCount, 188)
        XCTAssertEqual(queue.rejectedGestureCount, 0)
    }

    func testHostHistoryDoesNotDropMotionWhenConsumerKeepsUp() {
        var queue = TouchMotionQueue(maximumPendingMotionSamplesPerGesture: 2)
        var expected = [sample(.down, 0, 100)]
        expected += (1...96).map { sample(.move, UInt32($0), UInt64($0) + 100) }
        expected.append(sample(.up, 96, 197))
        var delivered: [TimestampedTouchEvent] = []
        for event in expected {
            XCTAssertTrue(queue.enqueue(event, nowNanoseconds: 1_000))
            delivered += queue.drain()
        }
        XCTAssertEqual(delivered, expected)
        XCTAssertEqual(queue.discardedMotionCount, 0)
    }

    func testHostHistoryRespectsCapacityAndNeverEvictsAdmittedEdgesOrFinalPoints() {
        for capacity in [4, 8, 16] {
            var queue = TouchMotionQueue(capacity: capacity, maximumPendingMotionSamplesPerGesture: 2)
            var acceptedEdges: [TimestampedTouchEvent] = []
            for gesture in 0..<100 {
                let x = UInt32(gesture * 100)
                let time = UInt64(gesture * 100 + 1)
                let down = sample(.down, x, time)
                let admitted = queue.enqueue(down, nowNanoseconds: 100_000)
                if admitted { acceptedEdges.append(down) }
                for index in 1...96 {
                    queue.enqueue(sample(.move, x + UInt32(index), time + UInt64(index)),
                                  nowNanoseconds: 100_000)
                    XCTAssertLessThanOrEqual(queue.count, capacity)
                }
                let end = sample(gesture % 2 == 0 ? .up : .cancel, x + 97, time + 97)
                XCTAssertEqual(queue.enqueue(end, nowNanoseconds: 100_000), admitted)
                if admitted { acceptedEdges.append(end) }
                XCTAssertLessThanOrEqual(queue.count, capacity)
            }
            let delivered = queue.drain()
            XCTAssertEqual(delivered.filter { $0.phase != .move }, acceptedEdges)
            XCTAssertGreaterThan(queue.rejectedGestureCount, 0)
            for index in delivered.indices where delivered[index].isDown == false {
                XCTAssertEqual(delivered[index - 1], sample(.move, delivered[index].x,
                                                          delivered[index].timestampNanoseconds!))
            }
        }
    }

    func testHostHistoryResetRetainsPolicyAndLegacyTimeSanitization() {
        var queue = TouchMotionQueue(maximumPendingMotionSamplesPerGesture: 2)
        queue.enqueue(sample(.down, 0, 100), nowNanoseconds: 100)
        queue.enqueue(sample(.move, 1, 101), nowNanoseconds: 101)
        queue.removeAll()
        XCTAssertEqual(queue.maximumPendingMotionSamplesPerGesture, 2)
        XCTAssertEqual(queue.discardedMotionCount, 0)
        XCTAssertFalse(queue.contactActive)
        for x in 0...10 {
            let capture: UInt64? = x == 9 ? .max : (x == 10 ? 0 : nil)
            queue.enqueue(TimestampedTouchEvent(x: UInt32(x), y: 50, isDown: true,
                                               timestampNanoseconds: capture),
                          nowNanoseconds: UInt64(x) + 10)
        }
        queue.enqueue(TimestampedTouchEvent(x: 10, y: 50, isDown: false), nowNanoseconds: 21)
        XCTAssertEqual(queue.drain(), [sample(.down, 0, 10), sample(.move, 9, 19),
                                      sample(.move, 10, 19), sample(.up, 10, 21)])
        XCTAssertEqual(queue.discardedMotionCount, 8)
    }

    func testTimestampSanitizationAndUptimeClockPair() {
        XCTAssertEqual(TouchTimestamp.capture(9.75, uptime: 10, nowNanoseconds: 50_000_000_000), 49_750_000_000)
        for invalid in [Double.nan, .infinity, -.infinity, -1, 11, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(TouchTimestamp.capture(invalid, uptime: 10, nowNanoseconds: 123), 123)
        }
        var queue = TouchMotionQueue()
        queue.enqueue(sample(.down, 0, 100), nowNanoseconds: 100)
        queue.enqueue(sample(.move, 1, 50), nowNanoseconds: 110)
        queue.enqueue(sample(.move, 2, .max), nowNanoseconds: 120)
        queue.enqueue(sample(.up, 2, 90), nowNanoseconds: 130)
        XCTAssertEqual(queue.drain().map(\.timestampNanoseconds), [100, 100, 120, 120])
    }

    func testGuestMappingHandlesEpochsWrapUnderflowAndMalformedValues() {
        var clock = TouchGuestClockMapping(hostAnchorNanoseconds: 9_000_000_000_000,
                                           guestAnchorNanoseconds: 5_000_000_000)
        XCTAssertEqual(clock.map(8_999_900_000_000, guestNowNanoseconds: 5_000_000_000), 4_900_000_000)
        XCTAssertEqual(clock.map(9_000_100_000_000, guestNowNanoseconds: 5_200_000_000), 5_100_000_000)
        XCTAssertEqual(clock.map(1, guestNowNanoseconds: 5_200_000_000), 5_100_000_000)
        XCTAssertEqual(clock.map(.max, guestNowNanoseconds: 5_200_000_000), 5_200_000_000)
        var earlyBoot = TouchGuestClockMapping(hostAnchorNanoseconds: 100, guestAnchorNanoseconds: 5)
        XCTAssertEqual(earlyBoot.map(1, guestNowNanoseconds: 6), 1)
        for value: UInt64 in [0, 0xffff_ffff, 0x1_0000_0000, UInt64.max] {
            let words = TouchTimestampWire.words(value)
            XCTAssertEqual(UInt64(UInt32(bitPattern: words.low)) | UInt64(UInt32(bitPattern: words.high)) << 32, value)
        }
    }

    func testGuestClockReanchorsOnlyBetweenGesturesAfterIdleDrift() {
        var clock = TouchGuestClockMapping(hostAnchorNanoseconds: 100_000_000_000,
                                           guestAnchorNanoseconds: 10_000_000_000)
        XCTAssertEqual(clock.map(99_900_000_000, guestNowNanoseconds: 10_000_000_000), 9_900_000_000)
        XCTAssertEqual(clock.map(99_950_000_000, guestNowNanoseconds: 10_000_000_000), 9_950_000_000)
        clock.beginGesture(hostAnchorNanoseconds: 200_000_000_000, guestAnchorNanoseconds: 50_000_000_000)
        let down = clock.map(199_900_000_000, guestNowNanoseconds: 50_000_000_000)
        let move = clock.map(199_950_000_000, guestNowNanoseconds: 50_000_000_000)
        XCTAssertEqual(down, 49_900_000_000)
        XCTAssertEqual(move - down, 50_000_000)
        clock.beginGesture(hostAnchorNanoseconds: 200_000_000_000, guestAnchorNanoseconds: 1)
        XCTAssertEqual(clock.map(0, guestNowNanoseconds: 50_000_000_000), move)
        var reset = TouchGuestClockMapping(hostAnchorNanoseconds: 200, guestAnchorNanoseconds: 10)
        XCTAssertEqual(reset.map(199, guestNowNanoseconds: 10), 9)
    }

    func testLegacyInferenceStrayMovesAndBoundedRepeatedGestures() {
        var queue = TouchMotionQueue(capacity: 16)
        XCTAssertFalse(queue.enqueue(sample(.move, 1, 1), nowNanoseconds: 1))
        for index in 0..<10_000 {
            queue.enqueue(TimestampedTouchEvent(x: UInt32(index), y: 0, isDown: true), nowNanoseconds: UInt64(index))
            queue.enqueue(TimestampedTouchEvent(x: UInt32(index), y: 0, isDown: false), nowNanoseconds: UInt64(index))
            XCTAssertLessThanOrEqual(queue.count, 16)
        }
        let events = queue.drain()
        XCTAssertEqual(events.count % 2, 0)
        for index in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[index].phase, .down)
            XCTAssertEqual(events[index + 1].phase, .up)
        }
    }

    func testTwoStageBackpressurePreservesAdmittedEdgesWithoutSecondCoalescing() {
        var runtime = TouchMotionQueue(capacity: 16)
        var device = TouchMotionQueue(capacity: 8)
        var acceptedEdges: [TimestampedTouchEvent] = []
        var delivered: [TimestampedTouchEvent] = []
        for index in 0..<1_000 {
            let phase: TouchPhase = index % 5 == 0 ? .down : (index % 5 == 4 ? .up : .move)
            let event = sample(phase, UInt32(index), UInt64(index + 1))
            if runtime.enqueue(event, nowNanoseconds: UInt64(index + 1)), phase != .move {
                acceptedEdges.append(event)
            }
            for event in runtime.drain(maxCount: max(0, device.capacity - device.count - 2)) {
                XCTAssertTrue(device.enqueue(event, nowNanoseconds: UInt64(index + 1)))
            }
            if index % 29 == 0 { delivered += device.drain(maxCount: 3) }
            XCTAssertLessThanOrEqual(runtime.count + device.count, 24)
        }
        while !runtime.isEmpty || !device.isEmpty {
            for event in runtime.drain(maxCount: max(0, device.capacity - device.count - 2)) {
                XCTAssertTrue(device.enqueue(event, nowNanoseconds: 2_000))
            }
            delivered += device.drain(maxCount: 3)
        }
        XCTAssertEqual(delivered.filter { $0.phase != .move }, acceptedEdges)
        XCTAssertEqual(device.discardedMotionCount, 0)
        XCTAssertEqual(device.rejectedGestureCount, 0)
    }

    func testVirtIOPreservesCaptureTimesAndFinalMoveAcrossEightEntryRefills() throws {
        let ring = try InputRing()
        let start = DispatchTime.now().uptimeNanoseconds - 100_000_000
        ring.device.enqueueTouches([
            sample(.down, 0, start), sample(.move, 10, start + 10_000_000),
            sample(.move, 20, start + 20_000_000), sample(.cancel, 30, start + 30_000_000)
        ])
        XCTAssertEqual(ring.device.inputFrameDeliveryProgress.target, 5)
        XCTAssertEqual(ring.device.pendingInputEventCount, 10)
        var events = try ring.refill(1)
        XCTAssertEqual(events.first?.code, TouchTimestampWire.lowCode)
        XCTAssertEqual(ring.device.deliveredInputFrameCount, 0)
        events += try ring.drain()
        let frames = splitFrames(events)
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames.map(timestamp), [start, start + 10_000_000, start + 20_000_000,
                                              start + 30_000_000, start + 30_000_000])
        XCTAssertEqual(frames.dropLast().map { frame in frame.first { $0.type == 3 && $0.code == 53 }?.value },
                       [0, 10, 20, 30])
        XCTAssertEqual(frames.first?[2], VirtIOInputEvent(type: 1, code: 330, value: 1))
        XCTAssertEqual(frames.last?[2], VirtIOInputEvent(type: 1, code: 330, value: 0))
        XCTAssertTrue(frames.last!.contains(VirtIOInputEvent(type: 3, code: 57, value: -1)))
        XCTAssertEqual(ring.device.inputFrameDeliveryProgress.delivered, 5)
        XCTAssertEqual(ring.device.inputFrameDeliveryProgress.target, 5)
    }

    func testVirtIOOverloadNeverRewritesPartiallyPublishedFrameOrLosesRelease() throws {
        let ring = try InputRing()
        let start = DispatchTime.now().uptimeNanoseconds - 100_000_000
        ring.device.enqueueTouches([sample(.down, 0, start)])
        var events = try ring.refill(1)
        for index in 1...2_000 {
            ring.device.enqueueTouches([sample(.move, UInt32(index), start + UInt64(index) * 1_000)])
            XCTAssertLessThanOrEqual(ring.device.inputFrameDeliveryProgress.target, 257)
            XCTAssertLessThanOrEqual(ring.device.pendingInputEventCount, 10)
        }
        ring.device.enqueueTouches([sample(.up, 2_001, start + 3_000_000)])
        XCTAssertLessThanOrEqual(ring.device.inputFrameDeliveryProgress.target, 257)
        events += try ring.drain()
        let frames = splitFrames(events)
        XCTAssertEqual(timestamp(frames.first!), start)
        XCTAssertEqual(frames.first?[2], VirtIOInputEvent(type: 1, code: 330, value: 1))
        XCTAssertEqual(frames[frames.count - 2].first { $0.type == 3 && $0.code == 53 }?.value, 2_001)
        XCTAssertEqual(frames.last?[2], VirtIOInputEvent(type: 1, code: 330, value: 0))
        let times = frames.map(timestamp)
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(frames.count, 200)
        XCTAssertEqual(ring.device.availableTouchSampleCapacity, 254)
    }

    func testVirtIOLegacySamplesInferPhasesAndTimestampAtEnqueue() throws {
        let ring = try InputRing()
        let before = DispatchTime.now().uptimeNanoseconds
        ring.device.enqueueTouches([
            TouchEvent(x: 0, y: 0, isDown: true), TouchEvent(x: 10, y: 0, isDown: true),
            TouchEvent(x: 10, y: 0, isDown: false)
        ])
        let after = DispatchTime.now().uptimeNanoseconds
        let frames = splitFrames(try ring.drain())
        XCTAssertEqual(frames.count, 3)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(timestamp(frame), before)
            XCTAssertLessThanOrEqual(timestamp(frame), after)
        }
        ring.device.reset()
        XCTAssertEqual(ring.device.pendingInputEventCount, 0)
        XCTAssertEqual(ring.device.availableTouchSampleCapacity, 254)
    }

    func testVirtIOClockSnapshotIsLatchedAndVersionGated() throws {
        let device = try InputRing().device
        try device.write(offset: 0x100, width: .byte, value: 3)
        XCTAssertEqual(try device.read(offset: 0x10e, width: .halfword), 2)
        let before = DispatchTime.now().uptimeNanoseconds
        try device.write(offset: 0x100, width: .byte, value: UInt64(TouchTimestampWire.configSelect))
        try device.write(offset: 0x101, width: .byte, value: 0)
        let after = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(try device.read(offset: 0x102, width: .byte), 8)
        let snapshot = try device.read(offset: 0x108, width: .doubleword)
        var bytes: UInt64 = 0
        for index in 0..<8 {
            bytes |= try device.read(offset: 0x108 + UInt64(index), width: .byte) << (index * 8)
        }
        XCTAssertEqual(bytes, snapshot)
        XCTAssertGreaterThanOrEqual(snapshot, before)
        XCTAssertLessThanOrEqual(snapshot, after)
        XCTAssertEqual(try device.read(offset: 0x108, width: .doubleword), snapshot)
        let keyboard = VirtualVirtIODevice(name: "keyboard", kind: .input, base: 0x1000, inputRole: .keyboard)
        try keyboard.write(offset: 0x100, width: .byte, value: 3)
        XCTAssertEqual(try keyboard.read(offset: 0x10e, width: .halfword), 1)
        try keyboard.write(offset: 0x100, width: .byte, value: UInt64(TouchTimestampWire.configSelect))
        XCTAssertEqual(try keyboard.read(offset: 0x102, width: .byte), 0)
    }

    func testDelayedAccessibleSwipeDoesNotReplayNinetySixStaleMoves() throws {
        let start = DispatchTime.now().uptimeNanoseconds - 3_000_000_000
        for limit: Int? in [nil, 2] {
            let ring = try InputRing()
            var host = TouchMotionQueue(maximumPendingMotionSamplesPerGesture: limit)
            host.enqueue(sample(.down, 0, start))
            for index in 1...96 {
                host.enqueue(sample(.move, UInt32(index), start + UInt64(index) * 20_000_000))
            }
            host.enqueue(sample(.up, 96, start + 1_940_000_000))
            XCTAssertEqual(host.count, limit == nil ? 98 : 4)
            XCTAssertEqual(host.discardedMotionCount, limit == nil ? 0 : 94)
            XCTAssertEqual(ring.device.inputFrameDeliveryProgress.target, 0)
            ring.device.enqueueTouches(host.drain(maxCount: ring.device.availableTouchSampleCapacity))
            XCTAssertTrue(host.isEmpty)
            let targetBeforeDrain = ring.device.inputFrameDeliveryProgress.target
            let events = try ring.drain()
            let frames = splitFrames(events)
            print("Delayed 96-move swipe: hostLimit=\(String(describing: limit)) target=\(targetBeforeDrain) frames=\(frames.count) wireEvents=\(events.count)")
            XCTAssertEqual(frames.count, limit == nil ? 98 : 4)
            XCTAssertEqual(events.count, limit == nil ? 784 : 32)
            XCTAssertEqual(ring.device.inputFrameDeliveryProgress.delivered, targetBeforeDrain)
            XCTAssertNotNil(ring.device.inputFrameDeliveryTimestamp(for: targetBeforeDrain))
            XCTAssertEqual(frames.first?[2], VirtIOInputEvent(type: 1, code: 330, value: 1))
            XCTAssertEqual(frames.last?[2], VirtIOInputEvent(type: 1, code: 330, value: 0))
            XCTAssertEqual(frames[frames.count - 2].first { $0.type == 3 && $0.code == 53 }?.value, 96)
            XCTAssertEqual(timestamp(frames.last!) - timestamp(frames.first!), 1_940_000_000)
            if limit != nil {
                XCTAssertEqual(frames.map(timestamp), [start, start + 1_900_000_000,
                                                       start + 1_920_000_000, start + 1_940_000_000])
                XCTAssertEqual(frames.dropLast().map { $0.first { $0.type == 3 && $0.code == 53 }?.value },
                               [0, 95, 96])
            }
        }
    }

    func testHostCompactionDoesNotInvalidatePreviouslyAssignedDeviceFrameTargets() throws {
        let ring = try InputRing()
        var host = TouchMotionQueue(maximumPendingMotionSamplesPerGesture: 2)
        let start = DispatchTime.now().uptimeNanoseconds - 3_000_000_000
        host.enqueue(sample(.down, 0, start))
        host.enqueue(sample(.move, 1, start + 20_000_000))
        host.enqueue(sample(.move, 2, start + 40_000_000))
        ring.device.enqueueTouches(host.drain(maxCount: ring.device.availableTouchSampleCapacity))
        let firstTarget = ring.device.inputFrameDeliveryProgress.target
        XCTAssertEqual(firstTarget, 3)
        var events = try ring.refill(1)
        XCTAssertEqual(ring.device.deliveredInputFrameCount, 0)
        for index in 3...96 {
            host.enqueue(sample(.move, UInt32(index), start + UInt64(index) * 20_000_000))
        }
        host.enqueue(sample(.cancel, 97, start + 1_940_000_000))
        XCTAssertEqual(host.count, 4)
        XCTAssertEqual(ring.device.inputFrameDeliveryProgress.target, firstTarget)
        ring.device.enqueueTouches(host.drain(maxCount: ring.device.availableTouchSampleCapacity))
        let finalTarget = ring.device.inputFrameDeliveryProgress.target
        XCTAssertEqual(finalTarget, 7)
        events += try ring.drain()
        let frames = splitFrames(events)
        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(frames.dropLast().map { $0.first { $0.type == 3 && $0.code == 53 }?.value },
                       [0, 1, 2, 95, 96, 97])
        XCTAssertEqual(frames.map(timestamp), [start, start + 20_000_000, start + 40_000_000,
                                              start + 1_900_000_000, start + 1_920_000_000,
                                              start + 1_940_000_000, start + 1_940_000_000])
        XCTAssertEqual(frames.last?[2], VirtIOInputEvent(type: 1, code: 330, value: 0))
        XCTAssertEqual(ring.device.inputFrameDeliveryProgress.delivered, finalTarget)
        XCTAssertNotNil(ring.device.inputFrameDeliveryTimestamp(for: firstTarget))
        XCTAssertNotNil(ring.device.inputFrameDeliveryTimestamp(for: finalTarget))
    }

    private func splitFrames(_ events: [VirtIOInputEvent]) -> [[VirtIOInputEvent]] {
        var frames: [[VirtIOInputEvent]] = []
        var frame: [VirtIOInputEvent] = []
        for event in events {
            frame.append(event)
            if event.type == 0 && event.code == 0 {
                frames.append(frame)
                frame.removeAll(keepingCapacity: true)
            }
        }
        XCTAssertTrue(frame.isEmpty)
        return frames
    }

    private func timestamp(_ frame: [VirtIOInputEvent]) -> UInt64 {
        XCTAssertGreaterThanOrEqual(frame.count, 2)
        guard frame.count >= 2 else { return 0 }
        XCTAssertEqual(frame[0].type, 4)
        XCTAssertEqual(frame[0].code, TouchTimestampWire.lowCode)
        XCTAssertEqual(frame[1].type, 4)
        XCTAssertEqual(frame[1].code, TouchTimestampWire.highCode)
        return UInt64(UInt32(bitPattern: frame[0].value)) | UInt64(UInt32(bitPattern: frame[1].value)) << 32
    }

    private final class InputRing {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x10000)
        let device: VirtualVirtIODevice
        private let descriptors: GuestAddress = 0x4000_1000
        private let available: GuestAddress = 0x4000_2000
        private let used: GuestAddress = 0x4000_3000
        private let buffers: GuestAddress = 0x4000_4000
        private var producer: UInt16 = 0

        init() throws {
            device = VirtualVirtIODevice(name: "test-touch", kind: .input, base: 0x1000,
                                         memory: memory, inputMaximumX: 10_000, inputMaximumY: 10_000)
            for (offset, value): (UInt64, UInt64) in [
                (0x30, 0), (0x38, 8), (0x80, descriptors), (0x90, available),
                (0xa0, used), (0x44, 1), (0x70, 0xf)
            ] {
                try device.write(offset: offset, width: .word, value: value)
            }
        }

        func refill(_ count: Int) throws -> [VirtIOInputEvent] {
            precondition((1...8).contains(count))
            for index in 0..<count {
                let descriptor = descriptors + UInt64(index * 16)
                try memory.write64(buffers + UInt64(index * 8), at: descriptor)
                try memory.write32(8, at: descriptor + 8)
                try memory.write16(2, at: descriptor + 12)
                try memory.write16(0, at: descriptor + 14)
                let slot = (Int(producer) + index) % 8
                try memory.write16(UInt16(index), at: available + 4 + UInt64(slot * 2))
            }
            producer &+= UInt16(count)
            try memory.write16(producer, at: available + 2)
            try device.write(offset: 0x50, width: .word, value: 0)
            XCTAssertEqual(try memory.read16(at: used + 2), producer)
            return try (0..<count).map { index in
                let address = buffers + UInt64(index * 8)
                return VirtIOInputEvent(type: try memory.read16(at: address),
                    code: try memory.read16(at: address + 2),
                    value: Int32(bitPattern: try memory.read32(at: address + 4)))
            }
        }

        func drain() throws -> [VirtIOInputEvent] {
            var events: [VirtIOInputEvent] = []
            for _ in 0..<1_000 {
                let pending = device.pendingInputEventCount
                if pending == 0 { break }
                events += try refill(min(8, pending))
            }
            XCTAssertEqual(device.pendingInputEventCount, 0)
            return events
        }
    }
}
