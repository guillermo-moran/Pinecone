import XCTest
@testable import ARM64VizCore

final class GraphicsCostTelemetryTests: XCTestCase {
    private final class Accelerator: PineconeGraphicsAccelerator {
        var eligible = false
        var succeeds = false
        func acceptsBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool { eligible }
        func execute(_ command: PineconeGraphicsCommand, source: PineconeGraphicsSurface?,
                     mask: PineconeGraphicsSurface?, destination: PineconeGraphicsSurface) -> Bool {
            succeeds
        }
    }

    func testNativeReasonPixelsBytesAndPhaseCostsForSynchronousAndDeferredRoutes() throws {
        for deferred in [false, true] {
            for reason in ["unavailable", "ineligible", "submissionDeclined"] {
                let (gpu, memory) = try device()
                let accelerator = Accelerator()
                if reason != "unavailable" {
                    accelerator.eligible = reason == "submissionDeclined"
                    gpu.setGraphicsAccelerator(accelerator)
                }
                let command = submission(packedA8: false)
                if deferred {
                    guard case let .completed(response) = gpu.processDeferred(
                        request: command, memory: memory, completion: { _ in XCTFail("unexpected async completion") }
                    ) else { return XCTFail("expected native raster") }
                    assertOK(response)
                } else {
                    assertOK(gpu.process(request: command, memory: memory))
                }
                let cost = gpu.performanceCounters()
                XCTAssertEqual(cost["hostNative.reason.\(reason).commands"], 1)
                XCTAssertEqual(cost["hostNative.reason.\(reason).pixels"], 4)
                XCTAssertEqual(cost["hostNative.reason.\(reason).destinationBytes"], 16)
                XCTAssertEqual(cost["hostNative.operator.1.commands"], 1)
                XCTAssertGreaterThan(try XCTUnwrap(cost["hostNative.reason.\(reason).milliseconds"]), 0)
                XCTAssertEqual(cost["hostNative.reason.\(reason).milliseconds"], cost["hostNative.operator.1.milliseconds"])
                XCTAssertEqual(cost["hostPhase.native.calls"], 1)
                XCTAssertGreaterThan(try XCTUnwrap(cost["hostPhase.native.milliseconds"]), 0)
                XCTAssertEqual(cost["paravirtualAcceleratedCommands"], 0)
                withExtendedLifetime(accelerator) {}
            }
        }
    }

    func testPackedDestinationBytesAndResetAreExact() throws {
        let (gpu, memory) = try device()
        assertOK(gpu.process(request: submission(packedA8: true), memory: memory))
        let cost = gpu.performanceCounters()
        XCTAssertEqual(cost["hostNative.reason.unavailable.pixels"], 4)
        XCTAssertEqual(cost["hostNative.reason.unavailable.destinationBytes"], 4)
        gpu.reset()
        let cleared = gpu.performanceCounters().filter {
            $0.key.hasPrefix("hostNative.") || $0.key.hasPrefix("hostPhase.")
        }
        XCTAssertFalse(cleared.isEmpty)
        XCTAssertTrue(cleared.values.allSatisfy { $0 == 0 })
    }

    func testSuccessfulAcceleratorDoesNotCountNativeRaster() throws {
        let (gpu, memory) = try device()
        let accelerator = Accelerator()
        accelerator.eligible = true
        accelerator.succeeds = true
        gpu.setGraphicsAccelerator(accelerator)
        assertOK(gpu.process(request: submission(packedA8: false), memory: memory))
        let cost = gpu.performanceCounters()
        XCTAssertEqual(cost["paravirtualAcceleratedCommands"], 1)
        XCTAssertEqual(cost["hostPhase.native.calls"], 0)
        XCTAssertTrue(cost.filter { $0.key.hasPrefix("hostNative.") }.values.allSatisfy { $0 == 0 })
        withExtendedLifetime(accelerator) {}
    }

    func testSolidA8OverSignatureCostCountsOnlyMatchingRasterWork() throws {
        let (gpu, memory) = try device()
        assertOK(gpu.process(request: packet(0x0101, [2, 1, 2, 2]), memory: memory))
        assertOK(gpu.process(request: packet(0x0106, [2, 1, 0x4001_0010, 0, 16, 0]), memory: memory))
        try memory.writeBytes(Array(repeating: UInt8(128), count: 16), at: 0x4001_0010)
        assertOK(gpu.process(request: submission(packedA8: false, glyph: true), memory: memory))
        let glyph = gpu.performanceCounters()
        XCTAssertEqual(glyph["hostNative.solidA8Over.commands"], 1)
        XCTAssertEqual(glyph["hostNative.solidA8Over.pixels"], 4)
        XCTAssertEqual(glyph["hostNative.solidA8Over.destinationBytes"], 16)
        XCTAssertGreaterThan(try XCTUnwrap(glyph["hostNative.solidA8Over.milliseconds"]), 0)
        assertOK(gpu.process(request: submission(packedA8: false), memory: memory))
        XCTAssertEqual(gpu.performanceCounters()["hostNative.solidA8Over.commands"], 1)
    }

    private func device() throws -> (VirtIOGPUDevice, PhysicalMemory) {
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        assertOK(gpu.process(request: packet(0x0101, [1, 1, 2, 2]), memory: memory))
        assertOK(gpu.process(request: packet(0x0106, [1, 1, 0x4001_0000, 0, 16, 0]), memory: memory))
        return (gpu, memory)
    }

    private func submission(packedA8: Bool, glyph: Bool = false) -> [UInt8] {
        let flags = PineconeGraphicsProtocol.solidSourceFlag |
            (packedA8 ? PineconeGraphicsProtocol.packedA8DestinationFlag : 0) |
            (glyph ? PineconeGraphicsProtocol.hasMaskFlag | PineconeGraphicsProtocol.packedA8MaskFlag : 0)
        return packet(0x0207, [
            64, 0, PineconeGraphicsProtocol.magic,
            UInt32(PineconeGraphicsProtocol.exactCompositeVersion) | (glyph ? 3 : 1) << 16,
            flags, 0, 1, 0, 0, 0, 0, 2, 2, 0x80402010, 0, 0, glyph ? 2 : 0, 0,
        ])
    }

    private func packet(_ type: UInt32, _ words: [UInt32]) -> [UInt8] {
        ([type, 0, 0, 0, 0, 0] + words).flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }

    private func assertOK(_ response: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(response.prefix(4)), [0, 0x11, 0, 0], file: file, line: line)
    }
}
