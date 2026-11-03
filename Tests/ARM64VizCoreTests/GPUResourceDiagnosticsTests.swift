import XCTest
@testable import ARM64VizCore

final class GPUResourceDiagnosticsTests: XCTestCase {
    func testFirstPartialFlushPublishesWholeSelectedScanout() throws {
        let memory = PhysicalMemory(base: 0x2000_0000, size: 0x10_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let backing = memory.base + 0x1000
        let pixels: [UInt8] = [
            1, 2, 3, 0, 4, 5, 6, 0,
            7, 8, 9, 0, 10, 11, 12, 0,
        ]
        assertOK(gpu.process(request: create(id: 1, format: 2), memory: memory))
        assertOK(gpu.process(request: attach(id: 1, address: backing), memory: memory))
        try memory.writeBytes(pixels, at: backing)
        assertOK(gpu.process(request: transfer(id: 1), memory: memory))
        assertOK(gpu.process(request: setScanout(id: 1), memory: memory))

        assertOK(gpu.process(request: flush(id: 1, x: 0, y: 0, width: 1, height: 1), memory: memory))
        let frame = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))
        XCTAssertEqual(Array(frame.pixels[0..<8]), [1, 2, 3, 0xff, 4, 5, 6, 0xff])
        XCTAssertEqual(
            Array(frame.pixels[frame.stride..<(frame.stride + 8)]),
            [7, 8, 9, 0xff, 10, 11, 12, 0xff]
        )
        XCTAssertEqual(frame.damage, [
            VirtualFramebufferDamage(x: 0, y: 0, width: 2, height: 2),
        ])
    }

    func testPageFlipPartialFlushPublishesWholeNewScanout() throws {
        let memory = PhysicalMemory(base: 0x2800_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let aBacking = memory.base + 0x1000
        let bBacking = memory.base + 0x2000
        let aPixel: [UInt8] = [0x11, 0x22, 0x33, 0]
        let bPixels: [UInt8] = [
            1, 2, 3, 0, 4, 5, 6, 0,
            7, 8, 9, 0, 10, 11, 12, 0,
        ]
        assertOK(gpu.process(request: create(id: 1, format: 2), memory: memory))
        assertOK(gpu.process(request: create(id: 2, format: 2), memory: memory))
        assertOK(gpu.process(request: attach(id: 1, address: aBacking), memory: memory))
        assertOK(gpu.process(request: attach(id: 2, address: bBacking), memory: memory))
        try memory.writeBytes(Array(repeating: aPixel, count: 4).flatMap { $0 }, at: aBacking)
        try memory.writeBytes(bPixels, at: bBacking)

        assertOK(gpu.process(request: transfer(id: 2), memory: memory))
        assertOK(gpu.process(request: setScanout(id: 2), memory: memory))
        assertOK(gpu.process(request: flush(id: 2), memory: memory))
        let firstB = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))
        assertOK(gpu.process(request: transfer(id: 1), memory: memory))
        assertOK(gpu.process(request: setScanout(id: 1), memory: memory))
        assertOK(gpu.process(request: flush(id: 1), memory: memory))
        let aFrame = try XCTUnwrap(gpu.snapshot(afterGeneration: firstB.generation))
        let heldA = try XCTUnwrap(gpu.frameLease(afterGeneration: firstB.generation))

        assertOK(gpu.process(request: setScanout(id: 2), memory: memory))
        assertOK(gpu.process(request: flush(id: 2, x: 0, y: 0, width: 1, height: 1), memory: memory))
        let republishedB = try XCTUnwrap(gpu.snapshot(afterGeneration: aFrame.generation))
        XCTAssertEqual(Array(republishedB.pixels[0..<8]), [1, 2, 3, 0xff, 4, 5, 6, 0xff])
        XCTAssertEqual(
            Array(republishedB.pixels[republishedB.stride..<(republishedB.stride + 8)]),
            [7, 8, 9, 0xff, 10, 11, 12, 0xff]
        )
        XCTAssertEqual(republishedB.damage, [
            VirtualFramebufferDamage(x: 0, y: 0, width: 2, height: 2),
        ])
        XCTAssertEqual(
            heldA.withUnsafeBytes { Array($0[0..<4]) },
            [0x11, 0x22, 0x33, 0xff]
        )
        XCTAssertEqual(gpu.resourceDiagnostics(memory: memory).committedScanoutResourceID, 2)
    }

    func testReselectingPreviouslyFlushedResourceRepublishesItsPixels() throws {
        let memory = PhysicalMemory(base: 0x3000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let aBacking = memory.base + 0x1000
        let bBacking = memory.base + 0x2000
        let aPixel: [UInt8] = [0x11, 0x22, 0x33, 0]
        let bPixel: [UInt8] = [0xaa, 0xbb, 0xcc, 0]

        assertOK(gpu.process(request: create(id: 1, format: 2), memory: memory))
        assertOK(gpu.process(request: create(id: 2, format: 2), memory: memory))
        assertOK(gpu.process(request: attach(id: 1, address: aBacking), memory: memory))
        assertOK(gpu.process(request: attach(id: 2, address: bBacking), memory: memory))
        try memory.writeBytes(Array(repeating: aPixel, count: 4).flatMap { $0 }, at: aBacking)
        try memory.writeBytes(Array(repeating: bPixel, count: 4).flatMap { $0 }, at: bBacking)

        assertOK(gpu.process(request: transfer(id: 2), memory: memory))
        assertOK(gpu.process(request: setScanout(id: 2), memory: memory))
        assertOK(gpu.process(request: flush(id: 2), memory: memory))
        let bFrame = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))
        XCTAssertEqual(Array(bFrame.pixels[0..<4]), [0xaa, 0xbb, 0xcc, 0xff])

        assertOK(gpu.process(request: transfer(id: 1), memory: memory))
        assertOK(gpu.process(request: setScanout(id: 1), memory: memory))
        assertOK(gpu.process(request: flush(id: 1), memory: memory))
        let aFrame = try XCTUnwrap(gpu.snapshot(afterGeneration: bFrame.generation))
        let heldA = try XCTUnwrap(gpu.frameLease(afterGeneration: bFrame.generation))
        XCTAssertEqual(Array(aFrame.pixels[0..<4]), [0x11, 0x22, 0x33, 0xff])

        // Resource 2 has no pending transfer: selecting it is itself the reason
        // the next flush must rebuild the published frame.
        assertOK(gpu.process(request: setScanout(id: 2), memory: memory))
        assertOK(gpu.process(request: flush(id: 2), memory: memory))
        let republishedB = try XCTUnwrap(gpu.snapshot(afterGeneration: aFrame.generation))
        XCTAssertEqual(Array(republishedB.pixels[0..<4]), [0xaa, 0xbb, 0xcc, 0xff])
        XCTAssertEqual(republishedB.damage, [
            VirtualFramebufferDamage(x: 0, y: 0, width: 2, height: 2),
        ])
        XCTAssertGreaterThan(republishedB.generation, aFrame.generation)
        XCTAssertEqual(
            heldA.withUnsafeBytes { Array($0[0..<4]) },
            [0x11, 0x22, 0x33, 0xff]
        )
        let diagnostics = gpu.resourceDiagnostics(memory: memory)
        XCTAssertEqual(diagnostics.activeScanoutResourceID, 2)
        XCTAssertEqual(diagnostics.committedScanoutResourceID, 2)
        XCTAssertEqual(
            diagnostics.resources.first { $0.resourceID == 2 }?.pendingTransferRectangleCount,
            0
        )
    }

    func testDiagnosticsDistinguishNonselectedResourceAndUntransferredScanoutBacking() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let blackBacking = memory.base + 0x1000
        let coloredBacking = memory.base + 0x2000

        assertOK(gpu.process(request: create(id: 1, format: 2), memory: memory))
        assertOK(gpu.process(request: create(id: 2, format: 2), memory: memory))
        assertOK(gpu.process(request: attach(id: 1, address: blackBacking), memory: memory))
        assertOK(gpu.process(request: attach(id: 2, address: coloredBacking), memory: memory))
        try memory.writeBytes([UInt8](repeating: 0, count: 16), at: blackBacking)
        try memory.writeBytes([
            1, 2, 3, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 4, 5, 6, 0,
        ], at: coloredBacking)
        assertOK(gpu.process(request: transfer(id: 2), memory: memory))
        assertOK(gpu.process(request: setScanout(id: 1), memory: memory))

        let first = gpu.resourceDiagnostics(memory: memory)
        XCTAssertEqual(first.activeScanoutResourceID, 1)
        XCTAssertNil(first.committedScanoutResourceID)
        let selected = try XCTUnwrap(first.resources.first { $0.resourceID == 1 })
        XCTAssertTrue(selected.isActiveScanout)
        XCTAssertEqual(selected.hostNonBlackRGBPixelCount, 0)
        XCTAssertEqual(selected.backingNonBlackRGBPixelCount, 0)
        XCTAssertFalse(selected.hasCompleteHostContents)
        let nonselected = try XCTUnwrap(first.resources.first { $0.resourceID == 2 })
        XCTAssertFalse(nonselected.isActiveScanout)
        XCTAssertEqual(nonselected.hostNonBlackRGBPixelCount, 2)
        XCTAssertEqual(nonselected.backingNonBlackRGBPixelCount, 2)
        XCTAssertEqual(nonselected.pendingTransferRectangleCount, 1)

        try memory.writeBytes([
            7, 8, 9, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
        ], at: blackBacking)
        let untransferred = gpu.resourceDiagnostics(memory: memory)
        let active = try XCTUnwrap(untransferred.resources.first { $0.resourceID == 1 })
        XCTAssertEqual(active.hostNonBlackRGBPixelCount, 0)
        XCTAssertEqual(active.backingNonBlackRGBPixelCount, 1)
        XCTAssertNil(active.backingReadError)

        assertOK(gpu.process(request: transfer(id: 1), memory: memory))
        assertOK(gpu.process(request: flush(id: 1), memory: memory))
        let committed = gpu.resourceDiagnostics(memory: memory)
        XCTAssertEqual(committed.activeScanoutResourceID, 1)
        XCTAssertEqual(committed.committedScanoutResourceID, 1)
        XCTAssertTrue(try XCTUnwrap(
            committed.resources.first { $0.resourceID == 1 }
        ).isCommittedScanout)
    }

    func testAlphaOnlyPixelsAreNotCountedAsNonBlackRGBForBGRAAndRGBA() throws {
        let memory = PhysicalMemory(base: 0x5000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let bgraBacking = memory.base + 0x1000
        let rgbaBacking = memory.base + 0x2000
        assertOK(gpu.process(request: create(id: 1, format: 1), memory: memory))
        assertOK(gpu.process(request: create(id: 2, format: 67), memory: memory))
        assertOK(gpu.process(request: attach(id: 1, address: bgraBacking), memory: memory))
        assertOK(gpu.process(request: attach(id: 2, address: rgbaBacking), memory: memory))
        try memory.writeBytes([0, 0, 0, 0xff] + [UInt8](repeating: 0, count: 12), at: bgraBacking)
        try memory.writeBytes([0, 0, 0, 0xff] + [UInt8](repeating: 0, count: 12), at: rgbaBacking)
        assertOK(gpu.process(request: transfer(id: 1), memory: memory))
        assertOK(gpu.process(request: transfer(id: 2), memory: memory))

        let snapshot = gpu.resourceDiagnostics(memory: memory)
        XCTAssertEqual(snapshot.resources.map(\.hostNonBlackRGBPixelCount), [0, 0])
        XCTAssertEqual(snapshot.resources.map(\.backingNonBlackRGBPixelCount), [0, 0])
        XCTAssertEqual(snapshot.resources.map(\.backingReadError), [nil, nil])
    }

    func testUnattachedBackingIsReportedAsErrorRatherThanBlack() throws {
        let memory = PhysicalMemory(base: 0x6000_0000, size: 0x10_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        assertOK(gpu.process(request: create(id: 7, format: 2), memory: memory))

        let resource = try XCTUnwrap(
            gpu.resourceDiagnostics(memory: memory).resources.first
        )
        XCTAssertEqual(resource.resourceID, 7)
        XCTAssertEqual(resource.hostNonBlackRGBPixelCount, 0)
        XCTAssertNil(resource.backingNonBlackRGBPixelCount)
        XCTAssertEqual(resource.backingReadError, "notAttached")
    }

    func testUnreadableBackingIsReportedAsErrorRatherThanBlack() throws {
        let attachedMemory = PhysicalMemory(base: 0x7000_0000, size: 0x10_000)
        let unrelatedMemory = PhysicalMemory(base: 0x7100_0000, size: 0x10_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        assertOK(gpu.process(request: create(id: 8, format: 2), memory: attachedMemory))
        assertOK(gpu.process(
            request: attach(id: 8, address: attachedMemory.base + 0x1000),
            memory: attachedMemory
        ))

        let resource = try XCTUnwrap(
            gpu.resourceDiagnostics(memory: unrelatedMemory).resources.first
        )
        XCTAssertNil(resource.backingNonBlackRGBPixelCount)
        XCTAssertEqual(resource.backingReadError, "readFailed")
    }

    private func create(id: UInt32, format: UInt32) -> [UInt8] {
        packet(type: 0x0101, words: [id, format, 2, 2])
    }

    private func attach(id: UInt32, address: UInt64) -> [UInt8] {
        packet(type: 0x0106, words: [
            id, 1,
            UInt32(truncatingIfNeeded: address), UInt32(address >> 32), 16, 0,
        ])
    }

    private func setScanout(id: UInt32) -> [UInt8] {
        packet(type: 0x0103, words: [0, 0, 2, 2, 0, id])
    }

    private func transfer(id: UInt32) -> [UInt8] {
        packet(type: 0x0105, words: [0, 0, 2, 2, 0, 0, id, 0])
    }

    private func flush(
        id: UInt32,
        x: UInt32 = 0,
        y: UInt32 = 0,
        width: UInt32 = 2,
        height: UInt32 = 2
    ) -> [UInt8] {
        packet(type: 0x0104, words: [x, y, width, height, id, 0])
    }

    private func packet(type: UInt32, words: [UInt32]) -> [UInt8] {
        var bytes: [UInt8] = []
        write(type, to: &bytes)
        bytes += [UInt8](repeating: 0, count: 20)
        for word in words { write(word, to: &bytes) }
        return bytes
    }

    private func write(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func assertOK(
        _ response: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let type = UInt32(response[0]) |
            (UInt32(response[1]) << 8) |
            (UInt32(response[2]) << 16) |
            (UInt32(response[3]) << 24)
        XCTAssertEqual(type, 0x1100, file: file, line: line)
    }
}
