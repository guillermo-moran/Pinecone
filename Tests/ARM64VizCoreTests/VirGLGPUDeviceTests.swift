import ARM64VizNative
import XCTest
@testable import ARM64VizCore

final class VirGLGPUDeviceTests: XCTestCase {
    private final class Renderer: VirGLRenderer {
        let name = "deterministic test renderer"
        var capsets = [VirGLCapset(id: 1, version: 1, size: 4)]
        var events: [String] = []
        var pixels = [UInt8](repeating: 0, count: 16)
        var backing: [UInt8] = []
        var onSubmit: (() -> Void)?
        func reset() throws { events.append("reset") }
        func finish() throws { events.append("fence-complete") }
        func caps(id: UInt32, version: UInt32) throws -> [UInt8] {
            guard id == 1, version <= 1 else { throw VirGLGPUError.invalidParameter }
            return [1, 2, 3, 4]
        }
        func createContext(id: UInt32, name: [UInt8]) throws { events.append("context+\(id)") }
        func destroyContext(id: UInt32) throws { events.append("context-\(id)") }
        func createResource(_ descriptor: AVZVirGLResource) throws { events.append("resource+\(descriptor.handle)") }
        func unrefResource(id: UInt32) throws { events.append("resource-\(id)") }
        func contextResource(context: UInt32, resource: UInt32, attach: Bool) throws { events.append("attach:\(attach)") }
        func attachBacking(resource: UInt32, size: Int) throws { backing = .init(repeating: 0, count: size); events.append("backing+") }
        func detachBacking(resource: UInt32) throws { backing = []; events.append("backing-") }
        func copyBacking(resource: UInt32, offset: Int, bytes: inout [UInt8], toHost: Bool) throws {
            if toHost { backing.replaceSubrange(offset..<(offset + bytes.count), with: bytes) }
            else { bytes = Array(backing[offset..<(offset + bytes.count)]) }
        }
        func transfer(_ descriptor: AVZVirGLTransfer, toHost: Bool) throws {
            let count = Int(descriptor.width * descriptor.height * 4)
            if toHost { pixels.replaceSubrange(0..<count, with: backing.prefix(count)) }
            else { backing.replaceSubrange(0..<count, with: pixels.prefix(count)) }
            events.append("transfer:\(toHost)")
        }
        func submit(context: UInt32, words: [UInt32]) throws {
            onSubmit?()
            pixels = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 255]
            events.append("gpu-complete")
        }
        func readPixels(resource: UInt32, width: Int, height: Int) throws -> [UInt8] { events.append("readback"); return pixels }
    }
    private func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { word in withUnsafeBytes(of: word.littleEndian) { Array($0) } }
    }
    private func command(_ opcode: UInt32, context: UInt32 = 0, body: [UInt32] = [], fence: UInt64 = 0) -> [UInt8] {
        bytes([opcode, fence == 0 ? 0 : 1, UInt32(truncatingIfNeeded: fence), UInt32(fence >> 32), context, 0] + body)
    }
    private func value(_ bytes: [UInt8], _ offset: Int = 0) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private func context(_ id: UInt32 = 1) -> [UInt8] {
        command(0x0200, context: id, body: [0, 0] + [UInt32](repeating: 0, count: 16))
    }
    private func resource(_ id: UInt32 = 7) -> [UInt8] {
        command(0x0204, body: [id, 2, 1, 10, 2, 2, 1, 1, 0, 0, 1, 0])
    }
    private func makeReady(_ gpu: VirtIOGPUDevice, _ memory: PhysicalMemory) {
        XCTAssertEqual(value(gpu.process(request: context(), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: resource(), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0202, context: 1, body: [7, 0]), memory: memory)), 0x1100)
    }

    func testFrameLeaseReleaseDoesNotWaitForGuestGPUCompletion() throws {
        // Model Metal's shared completion queue: releasing the display's final
        // frame owner must complete before the guest renderer can finish.
        final class FrameOwner: @unchecked Sendable {
            var lease: VirtualFramebufferFrameLease?
            init(_ lease: VirtualFramebufferFrameLease) { self.lease = lease }
        }
        let renderer = Renderer(), gpu = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: renderer)
        let memory = PhysicalMemory(base: 0x1000, size: 0x4000)
        makeReady(gpu, memory)
        let submission = command(0x0207, context: 1, body: [4, 0, 0])
        _ = gpu.process(request: submission, memory: memory)
        _ = gpu.process(request: command(0x0103, body: [0, 0, 2, 2, 0, 7]), memory: memory)
        _ = gpu.process(request: command(0x0104, body: [0, 0, 2, 2, 7, 0]), memory: memory)
        let owner = FrameOwner(try XCTUnwrap(gpu.frameLease(afterGeneration: nil)))
        let entered = DispatchSemaphore(value: 0), mayFinish = DispatchSemaphore(value: 0)
        renderer.onSubmit = {
            entered.signal()
            _ = mayFinish.wait(timeout: .now() + 5)
        }
        let submitted = expectation(description: "guest GPU submission completes")
        DispatchQueue.global().async {
            _ = gpu.process(request: submission, memory: memory)
            submitted.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let released = expectation(description: "display completion releases its frame without device lock")
        DispatchQueue.global().async {
            owner.lease = nil
            released.fulfill()
        }
        wait(for: [released], timeout: 1)
        mayFinish.signal()
        wait(for: [submitted], timeout: 2)
    }

    func testEmbeddedTransfersRefreshReusedGuestBackingAndPublishReadbacks() throws {
        for opcode: UInt32 in [43, 45] {
            for fromHost in [false, true] {
                let renderer = Renderer(), gpu = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: renderer)
                let memory = PhysicalMemory(base: 0x1000, size: 0x4000)
                makeReady(gpu, memory)
                _ = gpu.process(request: command(0x0106, body: [7, 1, 0x2000, 0, 16, 0]), memory: memory)
                for frame in 0..<2 {
                    let pattern = (0..<16).map { UInt8(32 + frame * 32 + $0) }
                    try memory.writeBytes(pattern, at: 0x2000)
                    renderer.onSubmit = {
                        XCTAssertEqual(renderer.backing, pattern, "embedded transfer must see current guest writes")
                        renderer.backing.replaceSubrange(0..<4, with: [201, 202, 203, 204])
                    }
                    let common: [UInt32] = [7, 0, 10, 8, 16, 0, 0, 0, 2, 2, 1]
                    let payload = common + (opcode == 43 ? [0, fromHost ? 2 : 1] : [7, 0, fromHost ? 2 : 0])
                    let stream = [UInt32(payload.count) << 16 | opcode] + payload
                    let response = gpu.process(request: command(0x0207, context: 1,
                        body: [UInt32(stream.count * 4), 0] + stream), memory: memory)
                    XCTAssertEqual(value(response), 0x1100)
                    let expected = fromHost ? [201, 202, 203, 204] + Array(pattern.dropFirst(4)) : pattern
                    XCTAssertEqual(try memory.readBytes(at: 0x2000, count: 16), expected)
                }
            }
        }
    }

    func testMalformedEmbeddedTransfersAreRejectedBeforeSubmission() throws {
        let renderer = Renderer(), gpu = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: renderer)
        let memory = PhysicalMemory(base: 0x1000, size: 0x4000)
        makeReady(gpu, memory)
        func submit(_ stream: [UInt32]) -> UInt32 {
            value(gpu.process(request: command(0x0207, context: 1,
                body: [UInt32(stream.count * 4), 0] + stream), memory: memory))
        }
        XCTAssertEqual(submit([13 << 16 | 43, 7]), 0x1205) // Truncated packet.
        let common: [UInt32] = [7, 0, 10, 8, 16, 0, 0, 0, 2, 2, 1]
        XCTAssertEqual(submit([13 << 16 | 43] + common + [0, 9]), 0x1205) // Invalid direction.
        XCTAssertEqual(submit([13 << 16 | 43] + common + [0, 1]), 0x1205) // Missing backing.
        XCTAssertEqual(submit([14 << 16 | 45] + common + [99, 0, 0]), 0x1203) // Unknown source.
        XCTAssertFalse(renderer.events.contains("gpu-complete"))
    }

    func testCapabilitiesContextsSubmissionFencesAndExistingDisplaySurface() throws {
        let renderer = Renderer(), gpu = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: renderer)
        let memory = PhysicalMemory(base: 0x1000, size: 0x4000)
        XCTAssertTrue(gpu.supportsVirGL)
        XCTAssertEqual(gpu.virglCapsetCount, 1)
        let info = gpu.process(request: command(0x0108, body: [0, 0]), memory: memory)
        XCTAssertEqual(value(info), 0x1102)
        XCTAssertEqual([value(info, 24), value(info, 28), value(info, 32)], [1, 1, 4])
        XCTAssertEqual(gpu.process(request: command(0x0109, body: [1, 1]), memory: memory).suffix(4), [1, 2, 3, 4])
        XCTAssertEqual(value(gpu.process(request: command(0x0108, body: [1, 0]), memory: memory)), 0x1205)
        makeReady(gpu, memory)
        let submission = command(0x0207, context: 1, body: [4, 0, 0], fence: 0x1234567887654321)
        let response = gpu.process(request: submission, memory: memory)
        XCTAssertEqual(renderer.events.suffix(2), ["gpu-complete", "fence-complete"])
        XCTAssertEqual(value(response), 0x1100)
        XCTAssertEqual([value(response, 4), value(response, 8), value(response, 12), value(response, 16)],
                       [1, 0x87654321, 0x12345678, 1])
        XCTAssertEqual(value(gpu.process(request: command(0x0103, body: [0, 0, 2, 2, 0, 7]), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0104, body: [0, 0, 2, 2, 7, 0]), memory: memory)), 0x1100)
        let frame = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))
        XCTAssertEqual(Array(frame.pixels.prefix(8)), Array(renderer.pixels.prefix(8)))
        XCTAssertEqual(Array(frame.pixels[frame.stride..<(frame.stride + 8)]), Array(renderer.pixels.suffix(8)))
        XCTAssertEqual(renderer.events.last, "readback")
        gpu.reset()
        XCTAssertEqual(renderer.events.last, "reset")
        XCTAssertEqual(value(gpu.process(request: submission, memory: memory)), 0x1204)
        makeReady(gpu, memory) // Context/resource IDs are reusable after reset.
    }

    func testTransfersUseValidatedBackingAndPublishGuestWrites() throws {
        let renderer = Renderer(), gpu = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: renderer)
        let memory = PhysicalMemory(base: 0x1000, size: 0x4000)
        makeReady(gpu, memory)
        let invalid = command(0x0106, body: [7, 1, 0xfffffff0, 0xffffffff, 16, 0])
        XCTAssertEqual(value(gpu.process(request: invalid, memory: memory)), 0x1205)
        XCTAssertFalse(renderer.events.contains("backing+"))
        XCTAssertEqual(value(gpu.process(request: command(0x0106, body: [7, 1, 0x2000, 0, 16, 0]), memory: memory)), 0x1100)
        let pattern = (0..<16).map(UInt8.init)
        try memory.writeBytes(pattern, at: 0x2000)
        let body: [UInt32] = [0, 0, 0, 2, 2, 1, 0, 0, 7, 0, 8, 16]
        XCTAssertEqual(value(gpu.process(request: command(0x0205, context: 1, body: body), memory: memory)), 0x1100)
        XCTAssertEqual(renderer.pixels, pattern)
        renderer.pixels = [UInt8](repeating: 0xab, count: 16)
        XCTAssertEqual(value(gpu.process(request: command(0x0206, context: 1, body: body), memory: memory)), 0x1100)
        XCTAssertEqual(try memory.readBytes(at: 0x2000, count: 16), renderer.pixels)
        try memory.writeBytes(pattern, at: 0x2000)
        var partial = body
        partial[3] = 1; partial[4] = 1
        XCTAssertEqual(value(gpu.process(request: command(0x0206, context: 1, body: partial), memory: memory)), 0x1100)
        XCTAssertEqual(try memory.readBytes(at: 0x2000, count: 16), [UInt8](repeating: 0xab, count: 4) + Array(pattern.dropFirst(4)))
        XCTAssertEqual(value(gpu.process(request: command(0x0107, body: [7, 0]), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0205, context: 1, body: body), memory: memory)), 0x1205)
    }

    func testMalformedRequestsDoNotCallRendererAnd2DRemainsAvailable() {
        let renderer = Renderer(), gpu = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: renderer)
        let memory = PhysicalMemory(base: 0x1000, size: 0x4000)
        makeReady(gpu, memory)
        let before = renderer.events
        for request in [command(0x0207, context: 1, body: [3, 0, 0]),
                        command(0x0207, context: 1, body: [0xfffffff0, 0]),
                        command(0x0204, body: [8, 2, 1, 10, .max, .max, 1, 1, 0, 0, 0, 0])] {
            XCTAssertNotEqual(value(gpu.process(request: request, memory: memory)), 0x1100)
        }
        XCTAssertEqual(renderer.events, before)
        let disabled = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: nil)
        XCTAssertFalse(disabled.supportsVirGL)
        XCTAssertEqual(value(disabled.process(request: command(0x0108, body: [0, 0]), memory: memory)), 0x1200)
        XCTAssertEqual(value(disabled.process(request: command(0x0101, body: [1, 2, 2, 2]), memory: memory)), 0x1100)
    }

    func testRealMetalCommandsReachExistingGuestDisplaySurface() throws {
        guard let frameworks = ProcessInfo.processInfo.environment["PINECONE_VIRGL_TEST_FRAMEWORKS"] else {
            throw XCTSkip("Set PINECONE_VIRGL_TEST_FRAMEWORKS to run the real Metal integration")
        }
        // Reproduce selecting Alpine after an Android run in the same host
        // process: the Android opt-in remains set, but the default VM must keep
        // its 2D features and must not even claim the singleton renderer.
        let previousEnabled = ProcessInfo.processInfo.environment["PINECONE_VIRGL"]
        let previousDirectory = ProcessInfo.processInfo.environment["PINECONE_VIRGL_LIBRARY_DIRECTORY"]
        setenv("PINECONE_VIRGL", "1", 1)
        setenv("PINECONE_VIRGL_LIBRARY_DIRECTORY", frameworks, 1)
        defer {
            if let previousEnabled { setenv("PINECONE_VIRGL", previousEnabled, 1) }
            else { unsetenv("PINECONE_VIRGL") }
            if let previousDirectory { setenv("PINECONE_VIRGL_LIBRARY_DIRECTORY", previousDirectory, 1) }
            else { unsetenv("PINECONE_VIRGL_LIBRARY_DIRECTORY") }
        }
        let alpine = try MachineFactory.makeResearchMachine()
        XCTAssertEqual(try alpine.virtioDisplay.read(offset: 0x10, width: .word) & 1, 0)
        XCTAssertEqual(try alpine.virtioDisplay.read(offset: 0x10c, width: .word), 0)
        let renderer = try NativeVirGLRenderer(frameworkDirectory: frameworks)
        XCTAssertTrue(renderer.name.contains("Metal"))
        let gpu = VirtIOGPUDevice(width: 2, height: 2, virglRenderer: renderer)
        let memory = PhysicalMemory(base: 0x1000, size: 0x4000)
        makeReady(gpu, memory)
        let stream: [UInt32] = [0x00050801, 1, 7, 1, 0, 0,
                               0x00030005, 1, 0, 1,
                               0x00080007, 4, 0x3f800000, 0, 0, 0x3f800000, 0, 0, 0]
        XCTAssertEqual(value(gpu.process(request: command(0x0207, context: 1, body: [UInt32(stream.count * 4), 0] + stream), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0103, body: [0, 0, 2, 2, 0, 7]), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0104, body: [0, 0, 2, 2, 7, 0]), memory: memory)), 0x1100)
        let frame = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))
        XCTAssertEqual(Array(frame.pixels.prefix(8)), [0, 0, 255, 255, 0, 0, 255, 255])

        // Upload vertices after attaching backing, using the embedded transfer
        // Mesa uses in Android. Without refreshing the shadow iovec these stay
        // zero and the triangle has no area, leaving the red clear unchanged.
        XCTAssertEqual(value(gpu.process(request: command(0x0204,
            body: [8, 0, 64, 16, 48, 1, 1, 1, 0, 0, 0, 0]), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0202, context: 1, body: [8, 0]), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0106, body: [8, 1, 0x2000, 0, 48, 0]), memory: memory)), 0x1100)
        let vertices: [Float] = [-1, -1, 0, 1, 3, -1, 0, 1, -1, 3, 0, 1]
        try memory.writeBytes(vertices.withUnsafeBytes { Array($0) }, at: 0x2000)
        var drawing: [UInt32] = []
        func emit(_ opcode: UInt32, _ object: UInt32, _ payload: [UInt32]) {
            drawing.append(UInt32(payload.count) << 16 | object << 8 | opcode)
            drawing += payload
        }
        func shader(_ handle: UInt32, _ stage: UInt32, _ text: String) {
            var encoded = Array(text.utf8) + [0]
            let length = encoded.count
            while encoded.count & 3 != 0 { encoded.append(0) }
            emit(1, 4, [handle, stage, UInt32(length), 300, 0] +
                 stride(from: 0, to: encoded.count, by: 4).map { value(encoded, $0) })
            emit(31, 0, [handle, stage])
        }
        emit(43, 0, [8, 0, 10, 0, 0, 0, 0, 0, 48, 1, 1, 0, 1])
        emit(44, 0, [])
        shader(2, 0, "VERT\nDCL IN[0]\nDCL OUT[0], POSITION\n0: MOV OUT[0], IN[0]\n1: END\n")
        shader(3, 1, "FRAG\nDCL OUT[0], COLOR\nIMM[0] FLT32 {0.0, 1.0, 0.0, 1.0}\n0: MOV OUT[0], IMM[0]\n1: END\n")
        emit(1, 1, [4, 0, 0, 15 << 27, 0, 0, 0, 0, 0, 0, 0])
        emit(2, 1, [4])
        emit(1, 3, [5, 0, 0, 0, 0])
        emit(2, 3, [5])
        emit(1, 2, [6, 0x60000002, 0x3f800000, 0, 0, 0x3f800000, 0, 0, 0])
        emit(2, 2, [6])
        emit(1, 5, [7, 0, 0, 0, 31]) // One float4 position attribute.
        emit(2, 5, [7])
        emit(6, 0, [16, 0, 8])
        emit(4, 0, [0, 0x3f800000, 0x3f800000, 0x3f000000, 0x3f800000, 0x3f800000, 0x3f000000])
        emit(8, 0, [0, 3, 4, 0, 1, 0, 0, 0, 0, 0, 2, 0])
        XCTAssertEqual(value(gpu.process(request: command(0x0207, context: 1,
            body: [UInt32(drawing.count * 4), 0] + drawing), memory: memory)), 0x1100)
        XCTAssertEqual(value(gpu.process(request: command(0x0104, body: [0, 0, 2, 2, 7, 0]), memory: memory)), 0x1100)
        let drawn = try XCTUnwrap(gpu.snapshot(afterGeneration: frame.generation))
        XCTAssertEqual(drawn.pixels, [0, 255, 0, 255, 0, 255, 0, 255,
                                     0, 255, 0, 255, 0, 255, 0, 255])
    }
}
