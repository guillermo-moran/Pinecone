import Foundation
import XCTest
@testable import ARM64VizCore

final class GraphicsIdentityTests: XCTestCase {
    private let base: UInt64 = 0x4000_0000
    private let width: UInt32 = 17
    private let height: UInt32 = 4

    func testIdentityBilinearFencePixelsAndRetainedFrame() throws {
        for fragmented in [false, true] {
            for over in [false, true] {
                let memory = PhysicalMemory(base: base, size: 0x10_0000)
                let gpu = VirtIOGPUDevice(width: Int(width), height: Int(height))
                let source = pixels(seed: 53), initial = pixels(seed: 97)
                try create(1, pixels: source, fragmented: fragmented, gpu: gpu, memory: memory)
                try create(2, pixels: initial, fragmented: fragmented, gpu: gpu, memory: memory)
                publish(gpu, memory)
                let lease = try XCTUnwrap(gpu.frameLease(afterGeneration: nil))
                let held = lease.withUnsafeBytes { Array($0) }
                let generation = gpu.generation
                let result = gpu.processDeferred(request: submission(over: over), memory: memory) { _ in
                    XCTFail("native completion must be synchronous")
                }
                guard case let .completed(response) = result else {
                    return XCTFail("unexpected deferred native operation")
                }
                checkResponse(response, type: 0x1100)
                var expected = initial
                for y in 0..<3 {
                    for x in 0..<15 {
                        let s = (y * Int(width) + x + 1) * 4
                        let d = ((y + 1) * Int(width) + x + 2) * 4
                        for c in 0..<4 {
                            let value = Int(source[s + c]) + (over
                                ? multiply(Int(initial[d + c]), 255 - Int(source[s + 3])) : 0)
                            expected[d + c] = UInt8(min(255, value))
                        }
                    }
                }
                XCTAssertEqual(try read(2, fragmented: fragmented, memory: memory), expected)
                XCTAssertEqual(try read(1, fragmented: fragmented, memory: memory), source)
                XCTAssertEqual(gpu.generation, generation, "submission must not publish scanout")
                publish(gpu, memory)
                XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels, expected)
                XCTAssertEqual(lease.withUnsafeBytes { Array($0) }, held)
                checkResponse(gpu.process(request: packet(0x0102, [2, 0]), memory: memory), type: 0x1100)
                gpu.reset()
                try create(2, pixels: initial, fragmented: fragmented, gpu: gpu, memory: memory)
                publish(gpu, memory)
                XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels, initial)
                XCTAssertEqual(lease.withUnsafeBytes { Array($0) }, held, "reuse changed a retained frame")
            }
        }
    }

    func testInvalidIdentityRequestPreservesBackingAndFence() throws {
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        let gpu = VirtIOGPUDevice(width: Int(width), height: Int(height))
        let initial = pixels(seed: 97)
        try create(1, pixels: pixels(seed: 53), fragmented: false, gpu: gpu, memory: memory)
        try create(2, pixels: initial, fragmented: false, gpu: gpu, memory: memory)
        checkResponse(gpu.process(request: submission(over: true, sourceID: 2), memory: memory), type: 0x1205)
        XCTAssertEqual(try read(2, fragmented: false, memory: memory), initial)
        checkResponse(gpu.process(request: submission(over: true), memory: memory), type: 0x1100)
        XCTAssertNotEqual(try read(2, fragmented: false, memory: memory), initial)
    }

    private func multiply(_ value: Int, _ alpha: Int) -> Int {
        let product = value * alpha + 128
        return (product + (product >> 8)) >> 8
    }

    private func pixels(seed: Int) -> [UInt8] {
        (0..<Int(width * height)).flatMap { i -> [UInt8] in
            let alpha = (i * seed) % 256
            return [UInt8(alpha / 3), UInt8(alpha / 2), UInt8(alpha), UInt8(alpha)]
        }
    }

    private func address(_ id: UInt32) -> UInt64 { base + UInt64(id) * 0x2_0000 }

    private func create(_ id: UInt32, pixels: [UInt8], fragmented: Bool,
                        gpu: VirtIOGPUDevice, memory: PhysicalMemory) throws {
        let count = width * height * 4
        let half = pixels.count / 2
        if fragmented {
            try memory.writeBytes(Array(pixels[..<half]), at: address(id))
            try memory.writeBytes(Array(pixels[half...]), at: address(id) + 0x1_0000)
        } else { try memory.writeBytes(pixels, at: address(id)) }
        checkResponse(gpu.process(request: packet(0x0101, [id, 1, width, height]), memory: memory), type: 0x1100)
        let entries: [(UInt64, UInt32)] = fragmented
            ? [(address(id), count / 2), (address(id) + 0x1_0000, count / 2)] : [(address(id), count)]
        var payload: [UInt32] = [id, UInt32(entries.count)]
        for (address, length) in entries {
            payload += [UInt32(truncatingIfNeeded: address), UInt32(address >> 32), length, 0]
        }
        checkResponse(gpu.process(request: packet(0x0106, payload), memory: memory), type: 0x1100)
    }

    private func read(_ id: UInt32, fragmented: Bool, memory: PhysicalMemory) throws -> [UInt8] {
        let count = Int(width * height * 4)
        if fragmented {
            return try memory.readBytes(at: address(id), count: count / 2) +
                memory.readBytes(at: address(id) + 0x1_0000, count: count / 2)
        }
        return try memory.readBytes(at: address(id), count: count)
    }

    private func publish(_ gpu: VirtIOGPUDevice, _ memory: PhysicalMemory) {
        for request in [packet(0x0105, [0, 0, width, height, 0, 0, 2, 0]),
                        packet(0x0103, [0, 0, width, height, 0, 2]),
                        packet(0x0104, [0, 0, width, height, 2, 0])] {
            checkResponse(gpu.process(request: request, memory: memory), type: 0x1100)
        }
    }

    private func submission(over: Bool, sourceID: UInt32 = 1) -> [UInt8] {
        packet(0x0207, [64, 0, PineconeGraphicsProtocol.magic,
            UInt32(PineconeGraphicsProtocol.exactCompositeVersion) | ((over ? 3 : 1) << 16),
            PineconeGraphicsProtocol.bilinearFilterFlag | PineconeGraphicsProtocol.sourceContainsAlphaFlag,
            sourceID, 2, 1, 0, 2, 1, 15, 3, 0, 15, 3, 0, 0])
    }

    private func packet(_ type: UInt32, _ payload: [UInt32]) -> [UInt8] {
        ([type, 1, 0x7654_3210, 0xfedc_ba98, 7, 0] + payload).flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
    }

    private func checkResponse(_ response: [UInt8], type: UInt32,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response, packet(type, []), file: file, line: line)
    }
}
