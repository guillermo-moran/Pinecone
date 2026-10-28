import Foundation
import XCTest
@testable import ARM64VizCore

final class LegacyTouchRoutingTests: XCTestCase {
    func testLinuxRuntimeRoutesTouchesOnlyToVirtIO() throws {
        // The iOS runtime is outside this package. This is a source contract,
        // not a substitute for the host's Linux runtime integration smoke test.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Apps/iOS/MobileOSHost/Sources/MobileOSHostModel.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private final class LinuxConsoleRuntime:"))
        let runtime = String(source[start.lowerBound...])
        XCTAssertNotNil(runtime.range(
            of: #"machine\s*\.\s*virtioInput\s*\.\s*enqueueTouches\s*\(\s*touches\s*\)"#,
            options: .regularExpression))
        XCTAssertNil(runtime.range(of: #"machine\s*\.\s*touch\s*\.\s*enqueue\s*\("#,
                                   options: .regularExpression),
                     "Linux must not retain a second, unconsumed legacy touch queue")
    }

    func testGenericMMIOStatusAndAcknowledgementLatchLifecycle() throws {
        let device = VirtualTouchInput(base: 0x1000)
        let bus = MMIOBus()
        try bus.register(device)
        let base = device.range.start
        let idle = TouchEvent(x: 0, y: 0, isDown: false)
        XCTAssertEqual(try latched(device), idle)
        XCTAssertEqual(try bus.read(address: base + 0x0c, width: .word), 0)
        try bus.write(address: base + 0x0c, width: .word, value: 1)
        XCTAssertEqual(try latched(device), idle)

        let samples = [
            TouchEvent(x: 10, y: 20, isDown: true),
            TouchEvent(x: 30, y: 40, isDown: true),
            TouchEvent(x: 30, y: 40, isDown: false)
        ]
        samples.forEach(device.enqueue)
        for _ in 0..<3 {
            XCTAssertEqual(try bus.read(address: base + 0x0c, width: .word), 1)
            XCTAssertEqual(try latched(device), idle)
            XCTAssertEqual(device.pendingEventCount, 3)
        }
        for offset: UInt64 in [0x00, 0x04, 0x08, 0x10] {
            try bus.write(address: base + offset, width: .word, value: 1)
        }
        for value: UInt64 in [0, 2, UInt64.max] {
            try bus.write(address: base + 0x0c, width: .word, value: value)
        }
        XCTAssertEqual(device.pendingEventCount, 3)
        XCTAssertEqual(try bus.read(address: base + 0x10, width: .word), 0)
        XCTAssertEqual(try latched(device), idle)

        for (index, sample) in samples.enumerated() {
            try bus.write(address: base + 0x0c, width: .word, value: 1)
            XCTAssertEqual(try bus.read(address: base, width: .word), UInt64(sample.x))
            XCTAssertEqual(try bus.read(address: base + 0x04, width: .word), UInt64(sample.y))
            XCTAssertEqual(try bus.read(address: base + 0x08, width: .word), sample.isDown ? 1 : 0)
            XCTAssertEqual(try bus.read(address: base + 0x0c, width: .word), index == 2 ? 0 : 1)
            XCTAssertEqual(device.pendingEventCount, samples.count - index - 1)
        }
        try bus.write(address: base + 0x0c, width: .word, value: 1)
        XCTAssertEqual(try latched(device), samples.last)
        XCTAssertEqual(device.pendingEventCount, 0)
    }

    func testHighRateSwipeBoundsPendingSamplesAndRetainsFinalMotionAndRelease() throws {
        for termination: TouchPhase in [.up, .cancel] {
            for acknowledgeDown in [false, true] {
                let device = VirtualTouchInput(base: 0)
                device.enqueue(sample(.down, x: 1))
                if acknowledgeDown { try acknowledge(device) }
                let initialLatch = try latched(device)
                for x in 2...10_000 {
                    device.enqueue(sample(.move, x: UInt32(x)))
                    XCTAssertLessThanOrEqual(device.pendingEventCount,
                                             VirtualTouchInput.maximumPendingEvents - 2)
                }
                device.enqueue(sample(termination, x: 10_001))
                XCTAssertLessThanOrEqual(device.pendingEventCount, VirtualTouchInput.maximumPendingEvents)
                XCTAssertEqual(try latched(device), initialLatch)
                let delivered = try drain(device)
                XCTAssertGreaterThan(delivered.count, 2)
                if !acknowledgeDown {
                    XCTAssertEqual(delivered.first, TouchEvent(x: 1, y: 2, isDown: true))
                }
                XCTAssertTrue(delivered.dropLast().allSatisfy(\.isDown))
                XCTAssertEqual(delivered[delivered.count - 2], TouchEvent(x: 10_001, y: 10_002, isDown: true))
                XCTAssertEqual(delivered.last, TouchEvent(x: 10_001, y: 10_002, isDown: false))
                XCTAssertEqual(device.pendingEventCount, 0)
                XCTAssertEqual(try device.read(offset: 0x08, width: .word), 0)
            }
        }
    }

    func testOverloadRejectsWholeGesturesWithoutEvictingAcceptedEdgesOrFinalMotion() throws {
        let device = VirtualTouchInput(base: 0)
        var expected: [TouchEvent] = []
        for gesture in 0..<5_000 {
            let x = UInt32(gesture * 3)
            let before = device.pendingEventCount
            device.enqueue(TouchEvent(x: x, y: 0, isDown: true))
            let accepted = device.pendingEventCount > before
            device.enqueue(TouchEvent(x: x + 1, y: 0, isDown: true))
            device.enqueue(TouchEvent(x: x + 1, y: 0, isDown: false))
            if accepted {
                expected += [TouchEvent(x: x, y: 0, isDown: true),
                             TouchEvent(x: x + 1, y: 0, isDown: true),
                             TouchEvent(x: x + 1, y: 0, isDown: false)]
            }
            XCTAssertLessThanOrEqual(device.pendingEventCount, VirtualTouchInput.maximumPendingEvents)
        }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertLessThan(expected.count, 5_000 * 3)
        XCTAssertEqual(try drain(device), expected)
        device.enqueue(TouchEvent(x: 50_000, y: 0, isDown: true))
        device.enqueue(TouchEvent(x: 50_000, y: 0, isDown: false))
        XCTAssertEqual(try drain(device).map(\.isDown), [true, false])
    }

    func testRejectedGestureStaysRejectedAfterGuestDrainsUntilRelease() throws {
        let device = VirtualTouchInput(base: 0)
        fillWithCompletedTaps(device)
        let before = device.pendingEventCount
        device.enqueue(sample(.down, x: 10_000))
        XCTAssertEqual(device.pendingEventCount, before)
        let delivered = try drain(device)
        XCTAssertEqual(delivered.count, before)
        XCTAssertFalse(try latched(device).isDown)

        for x in 10_001...12_000 {
            device.enqueue(sample(.move, x: UInt32(x)))
        }
        device.enqueue(sample(.cancel, x: 12_001))
        XCTAssertEqual(device.pendingEventCount, 0)
        device.enqueue(sample(.down, x: 13_000))
        device.enqueue(sample(.up, x: 13_000))
        XCTAssertEqual(try drain(device).map(\.isDown), [true, false])
    }

    func testResetClearsLatchQueueActiveContactAndRejectedGesture() throws {
        for rejected in [false, true] {
            let device = VirtualTouchInput(base: 0)
            if rejected {
                fillWithCompletedTaps(device)
                device.enqueue(sample(.down, x: 10_000))
            } else {
                device.enqueue(sample(.down, x: 1))
            }
            try acknowledge(device)
            XCTAssertTrue(try latched(device).isDown)
            device.reset()
            XCTAssertEqual(device.pendingEventCount, 0)
            XCTAssertEqual(try device.read(offset: 0x0c, width: .word), 0)
            XCTAssertEqual(try latched(device), TouchEvent(x: 0, y: 0, isDown: false))
            device.enqueue(sample(.down, x: 20_000))
            device.enqueue(sample(.up, x: 20_000))
            XCTAssertEqual(try drain(device).map(\.isDown), [true, false])
        }
    }

    private func sample(_ phase: TouchPhase, x: UInt32) -> TouchEvent {
        TouchEvent(x: x, y: x + 1, phase: phase, timestampNanoseconds: UInt64(x))
    }

    private func fillWithCompletedTaps(_ device: VirtualTouchInput) {
        for x in 0..<VirtualTouchInput.maximumPendingEvents {
            device.enqueue(TouchEvent(x: UInt32(x), y: 0, isDown: true))
            device.enqueue(TouchEvent(x: UInt32(x), y: 0, isDown: false))
        }
    }

    private func latched(_ device: VirtualTouchInput) throws -> TouchEvent {
        TouchEvent(x: UInt32(try device.read(offset: 0x00, width: .word)),
                   y: UInt32(try device.read(offset: 0x04, width: .word)),
                   isDown: try device.read(offset: 0x08, width: .word) != 0)
    }

    private func acknowledge(_ device: VirtualTouchInput) throws {
        try device.write(offset: 0x0c, width: .word, value: 1)
    }

    private func drain(_ device: VirtualTouchInput) throws -> [TouchEvent] {
        var events: [TouchEvent] = []
        while try device.read(offset: 0x0c, width: .word) != 0 {
            guard events.count < VirtualTouchInput.maximumPendingEvents else {
                XCTFail("Legacy queue exceeded its bound or ACK failed to advance it")
                break
            }
            try acknowledge(device)
            events.append(try latched(device))
        }
        return events
    }
}
