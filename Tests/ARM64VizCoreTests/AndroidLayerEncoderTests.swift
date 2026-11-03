import Foundation
import XCTest
@testable import ARM64VizCore

final class AndroidLayerEncoderTests: XCTestCase {
    func testDRMTransportFenceAndSubmissionContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = root.appendingPathComponent("scripts/android-graphics")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinecone-transport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let binary = scratch.appendingPathComponent("transport")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compiler.arguments = ["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L",
            "-Wall", "-Wextra", "-Werror",
            source.appendingPathComponent("pinecone_drm_transport.c").path,
            source.appendingPathComponent("transport_fixture.c").path,
            "-o", binary.path]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            XCTFail("Android DRM transport fixture failed to compile")
            return
        }
        let fixture = Process()
        fixture.executableURL = binary
        try fixture.run()
        fixture.waitUntilExit()
        XCTAssertEqual(fixture.terminationStatus, 0)
    }

    func testPortableGuestEncoderComposesThroughExistingHostProtocol() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pinecone-layer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let binary = scratch.appendingPathComponent("encoder")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compiler.arguments = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
            root.appendingPathComponent("scripts/android-graphics/encoder_fixture.c").path,
            "-o", binary.path]
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let fixture = Process(), pipe = Pipe()
        fixture.executableURL = binary; fixture.standardOutput = pipe
        try fixture.run()
        let payload = Array(pipe.fileHandleForReading.readDataToEndOfFile())
        fixture.waitUntilExit()
        XCTAssertEqual(fixture.terminationStatus, 0)
        XCTAssertEqual(payload.count, 64)

        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        func le(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
        func request(_ type: UInt32, _ words: [UInt32]) -> [UInt8] {
            le(type) + [UInt8](repeating: 0, count: 20) + words.flatMap(le)
        }
        func ok(_ response: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(Array(response.prefix(4)), le(0x1100), file: file, line: line)
        }
        for (id, height) in [(UInt32(1), UInt32(1)), (2, 2)] {
            let address = memory.base + UInt64(id) * 0x1000
            ok(gpu.process(request: request(0x101, [id, 1, 2, height]), memory: memory))
            ok(gpu.process(request: request(0x106,
                [id, 1, UInt32(address), 0, 8 * height, 0]), memory: memory))
        }
        try memory.writeBytes([0, 0, 255, 255, 255, 0, 0, 255], at: memory.base + 0x1000)
        let submit = request(0x207, [UInt32(payload.count), 0]) + payload
        ok(gpu.process(request: submit, memory: memory))
        XCTAssertEqual(try memory.readBytes(at: memory.base + 0x2000, count: 16),
            Array(repeating: [UInt8](arrayLiteral: 0, 0, 128, 128, 128, 0, 0, 128), count: 2).flatMap { $0 })
    }
}
