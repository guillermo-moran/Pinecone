import ARM64VizNative
import Darwin
import XCTest

final class ARM64FramebufferNativeTests: XCTestCase {
    func testFramebufferSurfaceIsPageAlignedStableAndClearable() {
        let logicalByteCount = 480 * 800 * 4
        guard let surface = avz_framebuffer_surface_create(logicalByteCount) else {
            return XCTFail("surface allocation failed")
        }
        defer { avz_framebuffer_surface_destroy(surface) }
        guard let bytes = avz_framebuffer_surface_bytes(surface) else {
            return XCTFail("surface has no storage")
        }

        let allocationByteCount = Int(
            avz_framebuffer_surface_allocation_size(surface)
        )
        XCTAssertEqual(
            Int(avz_framebuffer_surface_byte_count(surface)),
            logicalByteCount
        )
        XCTAssertGreaterThanOrEqual(allocationByteCount, logicalByteCount)
        XCTAssertEqual(allocationByteCount % Int(getpagesize()), 0)
        XCTAssertEqual(Int(bitPattern: bytes) % Int(getpagesize()), 0)

        bytes[logicalByteCount - 1] = 0xff
        avz_framebuffer_surface_clear(surface)
        XCTAssertEqual(bytes[logicalByteCount - 1], 0)
    }

    func testNativeCopyAndSourceOverMatchFramebufferSemantics() {
        let width = 4
        let stride = width * 4
        var source = [UInt8](repeating: 0, count: stride * 2)
        var destination = [UInt8](repeating: 0, count: stride * 2)
        setPixel([100, 50, 25, 128], x: 1, y: 0, stride: stride, in: &source)
        setPixel([20, 40, 60, 255], x: 2, y: 1, stride: stride, in: &destination)

        let copied = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_copy_bgra8(
                    sourceBytes.baseAddress,
                    stride,
                    1,
                    0,
                    destinationBytes.baseAddress,
                    stride,
                    0,
                    1,
                    1,
                    1
                )
            }
        }
        XCTAssertEqual(copied, 1)
        XCTAssertEqual(Array(destination[(stride)..<(stride + 4)]), [100, 50, 25, 128])

        let blended = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_source_over_bgra8(
                    sourceBytes.baseAddress,
                    stride,
                    1,
                    0,
                    destinationBytes.baseAddress,
                    stride,
                    2,
                    1,
                    1,
                    1
                )
            }
        }
        XCTAssertEqual(blended, 1)
        XCTAssertEqual(Array(destination[(stride + 8)..<(stride + 12)]), [110, 70, 55, 255])
    }

    func testNativeScaledCopyAndSourceOverUseNearestSampling() {
        let sourceStride = 8
        let destinationStride = 16
        let source: [UInt8] = [
            10, 20, 30, 255,
            40, 50, 60, 128
        ]
        var copied = [UInt8](repeating: 0, count: destinationStride)
        var blended = [UInt8](repeating: 20, count: destinationStride)

        let copyResult = source.withUnsafeBytes { sourceBytes in
            copied.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_scale_copy_bgra8(
                    sourceBytes.baseAddress, sourceStride, 0, 0, 2, 1,
                    destinationBytes.baseAddress, destinationStride, 0, 0, 4, 1
                )
            }
        }
        XCTAssertEqual(copyResult, 1)
        XCTAssertEqual(copied, [
            10, 20, 30, 255, 10, 20, 30, 255,
            40, 50, 60, 128, 40, 50, 60, 128
        ])

        let blendResult = source.withUnsafeBytes { sourceBytes in
            blended.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_scale_source_over_bgra8(
                    sourceBytes.baseAddress, sourceStride, 0, 0, 2, 1,
                    destinationBytes.baseAddress, destinationStride, 0, 0, 4, 1
                )
            }
        }
        XCTAssertEqual(blendResult, 1)
        XCTAssertEqual(Array(blended.prefix(8)), [10, 20, 30, 255, 10, 20, 30, 255])
        XCTAssertEqual(Array(blended.suffix(8)), [50, 60, 70, 138, 50, 60, 70, 138])
    }

    func testBilinearScaledCopyInterpolatesPixelCenters() {
        let source: [UInt8] = [
            0, 0, 0, 255,
            100, 200, 240, 255
        ]
        var destination = [UInt8](repeating: 0, count: 12)
        let result = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                avz_framebuffer_bilinear_scale_copy_bgra8(
                    sourceBytes.baseAddress, 8, 0, 0, 2, 1,
                    destinationBytes.baseAddress, 12, 0, 0, 3, 1
                )
            }
        }
        XCTAssertEqual(result, 1)
        XCTAssertEqual(destination, [
            0, 0, 0, 255,
            50, 100, 120, 255,
            100, 200, 240, 255
        ])
    }

    func testNormalizeBGRA8SupportsEveryVirtIO2DPixelFormat() {
        let source: [UInt8] = [0x10, 0x20, 0x30, 0x40]
        let expectations: [(format: UInt32, expected: [UInt8])] = [
            (1, [0x10, 0x20, 0x30, 0x40]),
            (2, [0x10, 0x20, 0x30, 0xff]),
            (3, [0x40, 0x30, 0x20, 0x10]),
            (4, [0x40, 0x30, 0x20, 0xff]),
            (67, [0x30, 0x20, 0x10, 0x40]),
            (68, [0x20, 0x30, 0x40, 0xff]),
            (121, [0x20, 0x30, 0x40, 0x10]),
            (134, [0x30, 0x20, 0x10, 0xff])
        ]

        for expectation in expectations {
            var pixels = source
            let result = pixels.withUnsafeMutableBytes { bytes in
                avz_framebuffer_normalize_bgra8(
                    bytes.baseAddress,
                    4,
                    1,
                    1,
                    expectation.format
                )
            }
            XCTAssertEqual(result, 1, "format \(expectation.format)")
            XCTAssertEqual(pixels, expectation.expected, "format \(expectation.format)")
        }
    }

    func testDirtyTileCommitFindsExactDamageAndSuppressesUnchangedFrames() {
        let width = 64
        let height = 64
        let stride = width * 4
        var source = [UInt8](repeating: 0, count: stride * height)
        var destination = source
        setPixel([0x10, 0x20, 0x30, 0xff], x: 3, y: 4, stride: stride, in: &source)
        setPixel([0x40, 0x50, 0x60, 0xff], x: 40, y: 35, stride: stride, in: &source)

        let first = commitDirtyTiles(
            source: &source,
            destination: &destination,
            width: width,
            height: height
        )
        assertDamage(first.damage, equals: [
            (3, 4, 1, 1),
            (40, 35, 1, 1)
        ])
        XCTAssertEqual(first.changedByteCount, 8)
        XCTAssertEqual(destination, source)

        let second = commitDirtyTiles(
            source: &source,
            destination: &destination,
            width: width,
            height: height
        )
        XCTAssertTrue(second.damage.isEmpty)
        XCTAssertEqual(second.changedByteCount, 0)
    }

    func testDirtyTileCommitCoalescesFullFrameDamage() {
        let width = 64
        let height = 64
        var source = [UInt8](repeating: 0xff, count: width * height * 4)
        var destination = [UInt8](repeating: 0, count: source.count)

        let result = commitDirtyTiles(
            source: &source,
            destination: &destination,
            width: width,
            height: height
        )
        assertDamage(result.damage, equals: [
            (0, 0, UInt32(width), UInt32(height))
        ])
        XCTAssertEqual(result.changedByteCount, source.count)
        XCTAssertEqual(destination, source)
    }

    private func commitDirtyTiles(
        source: inout [UInt8],
        destination: inout [UInt8],
        width: Int,
        height: Int
    ) -> (damage: [AVZFramebufferDamageRect], changedByteCount: Int) {
        let capacity = Int(AVZ_FRAMEBUFFER_MAX_DAMAGE_RECTS)
        var damage = [AVZFramebufferDamageRect](
            repeating: AVZFramebufferDamageRect(x: 0, y: 0, width: 0, height: 0),
            count: capacity
        )
        var changedByteCount = 0
        let count = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                damage.withUnsafeMutableBufferPointer { damageBuffer in
                    avz_framebuffer_commit_dirty_tiles(
                        sourceBytes.baseAddress,
                        width * 4,
                        0,
                        0,
                        destinationBytes.baseAddress,
                        width * 4,
                        0,
                        0,
                        width,
                        height,
                        32,
                        32,
                        damageBuffer.baseAddress,
                        capacity,
                        &changedByteCount
                    )
                }
            }
        }
        return (Array(damage.prefix(count)), changedByteCount)
    }

    private func setPixel(
        _ pixel: [UInt8],
        x: Int,
        y: Int,
        stride: Int,
        in pixels: inout [UInt8]
    ) {
        let offset = y * stride + x * 4
        pixels.replaceSubrange(offset..<(offset + 4), with: pixel)
    }

    private func assertDamage(
        _ actual: [AVZFramebufferDamageRect],
        equals expected: [(UInt32, UInt32, UInt32, UInt32)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (rectangle, expectedRectangle) in zip(actual, expected) {
            XCTAssertEqual(rectangle.x, expectedRectangle.0, file: file, line: line)
            XCTAssertEqual(rectangle.y, expectedRectangle.1, file: file, line: line)
            XCTAssertEqual(rectangle.width, expectedRectangle.2, file: file, line: line)
            XCTAssertEqual(rectangle.height, expectedRectangle.3, file: file, line: line)
        }
    }
}
