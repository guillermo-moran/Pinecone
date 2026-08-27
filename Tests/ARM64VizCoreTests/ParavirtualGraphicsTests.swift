import XCTest
@testable import ARM64VizCore

final class ParavirtualGraphicsTests: XCTestCase {
    func testDeferredParavirtualCompletionPublishesOnlyAfterAcceleratorFence() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let backing: GuestAddress = 0x4001_0000
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let accelerator = DeferredRecordingGraphicsAccelerator()
        gpu.setGraphicsAccelerator(accelerator)
        try createResource(
            id: 1,
            backing: backing,
            pixels: [UInt8](repeating: 0, count: 16),
            width: 2,
            height: 2,
            gpu: gpu,
            memory: memory
        )
        let command = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 2,
            height: 2,
            color: 0xff00_0000
        )
        let response = DeferredResponseBox()

        XCTAssertTrue(gpu.processDeferred(
            request: command,
            memory: memory,
            completion: { response.store($0) }
        ))
        XCTAssertNil(response.value)
        XCTAssertEqual(
            try memory.readBytes(at: backing, count: 16),
            [UInt8](repeating: 0, count: 16)
        )

        accelerator.complete(success: true)

        XCTAssertEqual(response.value.map(responseType), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: backing, count: 16),
            [UInt8](repeating: 0x7a, count: 16)
        )
        XCTAssertTrue(gpu.diagnosticsSummary().contains("pv2d=1/1:4"))
    }

    func testParavirtualFillUsesSharedGuestBacking() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let backing: GuestAddress = 0x4001_0000
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        let accelerator = RecordingGraphicsAccelerator(color: 0x8040_2010)
        gpu.setGraphicsAccelerator(accelerator)

        XCTAssertEqual(responseType(gpu.process(
            request: gpuRequest(type: 0x0101, words: [1, 1, 2, 2]),
            memory: memory
        )), 0x1100)

        var attach = gpuRequest(type: 0x0106, words: [1, 1])
        appendLE64(backing, to: &attach)
        appendLE32(16, to: &attach)
        appendLE32(0, to: &attach)
        XCTAssertEqual(responseType(gpu.process(request: attach, memory: memory)), 0x1100)

        let command = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 2,
            height: 2,
            color: 0x8040_2010
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(accelerator.commands.count, 1)
        XCTAssertEqual(
            try memory.readBytes(at: backing, count: 16),
            [UInt8](repeating: 0x7a, count: 16)
        )
        XCTAssertTrue(gpu.diagnosticsSummary().contains("pv2d=1/1:4"))
        XCTAssertTrue(gpu.diagnosticsSummary().contains("/b0/m1"))
    }

    func testAcceleratedGuestWriteTransfersExactDamageWithoutPageReadback() throws {
        let width = 64
        let height = 32
        let byteCount = width * height * 4
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let backing: GuestAddress = 0x4001_0000
        let gpu = VirtIOGPUDevice(width: width, height: height)
        let accelerator = RectangleGraphicsAccelerator()
        gpu.setGraphicsAccelerator(accelerator)
        try createResource(
            id: 1,
            backing: backing,
            pixels: [UInt8](repeating: 0, count: byteCount),
            width: UInt32(width),
            height: UInt32(height),
            gpu: gpu,
            memory: memory
        )

        let fullRectangle = [UInt32(0), 0, UInt32(width), UInt32(height)]
        XCTAssertEqual(responseType(gpu.process(
            request: gpuRequest(type: 0x0103, words: fullRectangle + [0, 1]),
            memory: memory
        )), 0x1100)
        let transfer = gpuRequest(
            type: 0x0105,
            words: fullRectangle + [0, 0, 1, 0]
        )
        let flush = gpuRequest(type: 0x0104, words: fullRectangle + [1, 0])
        XCTAssertEqual(responseType(gpu.process(request: transfer, memory: memory)), 0x1100)
        XCTAssertEqual(responseType(gpu.process(request: flush, memory: memory)), 0x1100)
        let firstFrame = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))

        let x: UInt32 = 7
        let y: UInt32 = 20
        XCTAssertEqual(responseType(gpu.process(
            request: paravirtualRequest(
                operation: 3,
                sourceResourceID: 0,
                destinationResourceID: 1,
                sourceX: 0,
                sourceY: 0,
                destinationX: Int32(x),
                destinationY: Int32(y),
                width: 1,
                height: 1,
                color: 0xff30_2010
            ),
            memory: memory
        )), 0x1100)
        XCTAssertEqual(responseType(gpu.process(request: transfer, memory: memory)), 0x1100)
        XCTAssertEqual(responseType(gpu.process(request: flush, memory: memory)), 0x1100)

        let frame = try XCTUnwrap(gpu.snapshot(afterGeneration: firstFrame.generation))
        let offset = (Int(y) * width + Int(x)) * 4
        XCTAssertEqual(Array(frame.pixels[offset..<(offset + 4)]), [0x10, 0x20, 0x30, 0xff])
        XCTAssertEqual(frame.damage, [
            VirtualFramebufferDamage(x: Int(x), y: Int(y), width: 1, height: 1)
        ])
        let diagnostics = gpu.diagnosticsSummary()
        XCTAssertTrue(diagnostics.contains("pages=1/0:\(byteCount + 4)"), diagnostics)
        XCTAssertTrue(diagnostics.contains("exact=1/4"), diagnostics)
    }

    func testParavirtualCompletionPreservesVirtIOFence() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1,
            backing: 0x4001_0000,
            pixels: [UInt8](repeating: 0, count: 4),
            gpu: gpu,
            memory: memory
        )
        var request = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0xff12_3456
        )
        overwriteLE32(1, in: &request, at: 4)
        overwriteLE64(0x1234_5678_9abc_def0, in: &request, at: 8)
        overwriteLE32(42, in: &request, at: 16)
        request[20] = 3

        let response = gpu.process(request: request, memory: memory)

        XCTAssertEqual(responseType(response), 0x1100)
        XCTAssertEqual(readLE32(response, at: 4), 1)
        XCTAssertEqual(readLE64(response, at: 8), 0x1234_5678_9abc_def0)
        XCTAssertEqual(readLE32(response, at: 16), 42)
        XCTAssertEqual(response[20], 3)
    }

    func testParavirtualCommandRejectsReservedFieldsAndInvalidGeometry() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        var request = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 2,
            height: 2,
            color: 0
        )
        request[88] = 1
        XCTAssertEqual(responseType(gpu.process(request: request, memory: memory)), 0x1205)
    }

    func testNativeFallbackScalesNearestNeighbor() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let sourceBacking: GuestAddress = 0x4001_0000
        let destinationBacking: GuestAddress = 0x4001_1000
        let gpu = VirtIOGPUDevice(width: 4, height: 1)

        try createResource(
            id: 1,
            backing: sourceBacking,
            pixels: [1, 2, 3, 255, 5, 6, 7, 255],
            width: 2,
            gpu: gpu,
            memory: memory
        )
        try createResource(
            id: 2,
            backing: destinationBacking,
            pixels: [UInt8](repeating: 0, count: 16),
            width: 4,
            gpu: gpu,
            memory: memory
        )

        let command = paravirtualRequest(
            operation: 1,
            sourceResourceID: 1,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            sourceWidth: 2,
            sourceHeight: 1,
            destinationX: 0,
            destinationY: 0,
            width: 4,
            height: 1,
            color: 0
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: destinationBacking, count: 16),
            [1, 2, 3, 255, 1, 2, 3, 255, 5, 6, 7, 255, 5, 6, 7, 255]
        )
    }

    func testNativeFallbackScalesBilinearlyWhenRequested() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let sourceBacking: GuestAddress = 0x4001_0000
        let destinationBacking: GuestAddress = 0x4001_1000
        let gpu = VirtIOGPUDevice(width: 3, height: 1)

        try createResource(
            id: 1,
            backing: sourceBacking,
            pixels: [0, 0, 0, 255, 100, 200, 240, 255],
            width: 2,
            gpu: gpu,
            memory: memory
        )
        try createResource(
            id: 2,
            backing: destinationBacking,
            pixels: [UInt8](repeating: 0, count: 12),
            width: 3,
            gpu: gpu,
            memory: memory
        )

        let command = paravirtualRequest(
            operation: 1,
            flags: PineconeGraphicsProtocol.bilinearFilterFlag,
            sourceResourceID: 1,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            sourceWidth: 2,
            sourceHeight: 1,
            destinationX: 0,
            destinationY: 0,
            width: 3,
            height: 1,
            color: 0
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: destinationBacking, count: 12),
            [0, 0, 0, 255, 50, 100, 120, 255, 100, 200, 240, 255]
        )
    }

    func testParavirtualFlagsAndFillSourceDimensionsAreStrict() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        try createResource(
            id: 1,
            backing: 0x4001_0000,
            pixels: [UInt8](repeating: 0, count: 16),
            width: 2,
            gpu: gpu,
            memory: memory
        )
        let unsupportedFlag = paravirtualRequest(
            operation: 3,
            flags: 4,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 2,
            height: 2,
            color: 0
        )
        XCTAssertEqual(
            responseType(gpu.process(request: unsupportedFlag, memory: memory)),
            0x1205
        )

        let fillWithSourceDimensions = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            sourceWidth: 1,
            sourceHeight: 1,
            destinationX: 0,
            destinationY: 0,
            width: 2,
            height: 2,
            color: 0
        )
        XCTAssertEqual(
            responseType(gpu.process(request: fillWithSourceDimensions, memory: memory)),
            0x1205
        )
    }

    func testNativeFallbackCompositesPremultipliedSourceOver() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let sourceBacking: GuestAddress = 0x4001_0000
        let destinationBacking: GuestAddress = 0x4001_1000
        let gpu = VirtIOGPUDevice(width: 1, height: 1)

        try createResource(
            id: 1,
            backing: sourceBacking,
            pixels: [20, 40, 60, 128],
            gpu: gpu,
            memory: memory
        )
        try createResource(
            id: 2,
            backing: destinationBacking,
            pixels: [100, 80, 40, 128],
            gpu: gpu,
            memory: memory
        )

        let command = paravirtualRequest(
            operation: 2,
            sourceResourceID: 1,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: destinationBacking, count: 4),
            [70, 80, 80, 192]
        )
        XCTAssertTrue(gpu.diagnosticsSummary().contains("pv2d=1/0:1"))
    }

    func testNativeFallbackAppliesImageMaskToSourceOver() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [20, 40, 60, 128], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [100, 80, 40, 128], gpu: gpu, memory: memory
        )
        try createResource(
            id: 3, backing: 0x4001_2000,
            pixels: [0, 0, 0, 128], gpu: gpu, memory: memory
        )

        let command = paravirtualRequest(
            operation: 2,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag |
                PineconeGraphicsProtocol.hasMaskFlag,
            sourceResourceID: 1,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0,
            maskResourceID: 3
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: 0x4001_1000, count: 4),
            [85, 80, 60, 160]
        )
    }

    func testNativeFallbackAppliesSolidMaskToSource() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [20, 40, 60, 128], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [100, 80, 40, 128], gpu: gpu, memory: memory
        )

        let command = paravirtualRequest(
            operation: 1,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag |
                PineconeGraphicsProtocol.hasMaskFlag |
                PineconeGraphicsProtocol.solidMaskFlag,
            sourceResourceID: 1,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0,
            maskAlpha: 128
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: 0x4001_1000, count: 4),
            [10, 20, 30, 64]
        )
    }

    func testParavirtualMaskFlagsRequireConsistentPayload() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        let command = paravirtualRequest(
            operation: 3,
            flags: PineconeGraphicsProtocol.solidMaskFlag,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0,
            maskAlpha: 128
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1205)
    }

    func testExactCompositeAppliesPackedA8Mask() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [20, 40, 60, 128], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [0, 0, 0, 0], gpu: gpu, memory: memory
        )
        try createResource(
            id: 3, backing: 0x4001_2000,
            pixels: [128, 0, 0, 0], gpu: gpu, memory: memory
        )

        let command = paravirtualRequest(
            version: PineconeGraphicsProtocol.exactCompositeVersion,
            operation: PineconeGraphicsBlendOperator.source.rawValue,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag |
                PineconeGraphicsProtocol.hasMaskFlag |
                PineconeGraphicsProtocol.packedA8MaskFlag,
            sourceResourceID: 1, destinationResourceID: 2,
            sourceX: 0, sourceY: 0, destinationX: 0, destinationY: 0,
            width: 1, height: 1, color: 0, maskResourceID: 3
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: 0x4001_1000, count: 4),
            [10, 20, 30, 64]
        )
    }

    func testExactCompositeCopiesAndFillsPackedA8Surfaces() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let sourceBacking: GuestAddress = 0x4001_0000
        let destinationBacking: GuestAddress = 0x4001_1000
        let gpu = VirtIOGPUDevice(width: 2, height: 2)
        try createResource(
            id: 1,
            backing: sourceBacking,
            pixels: [64, 128, 9, 9, 9, 9, 9, 9, 192, 255, 9, 9, 9, 9, 9, 9],
            width: 2,
            height: 2,
            gpu: gpu,
            memory: memory
        )
        try createResource(
            id: 2,
            backing: destinationBacking,
            pixels: [UInt8](repeating: 7, count: 16),
            width: 2,
            height: 2,
            gpu: gpu,
            memory: memory
        )

        let copy = paravirtualRequest(
            version: PineconeGraphicsProtocol.exactCompositeVersion,
            operation: PineconeGraphicsBlendOperator.source.rawValue,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag |
                PineconeGraphicsProtocol.packedA8SourceFlag |
                PineconeGraphicsProtocol.packedA8DestinationFlag,
            sourceResourceID: 1,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 2,
            height: 2,
            color: 0
        )
        XCTAssertEqual(responseType(gpu.process(request: copy, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: destinationBacking, count: 16),
            [64, 128, 7, 7, 7, 7, 7, 7, 192, 255, 7, 7, 7, 7, 7, 7]
        )

        let fill = paravirtualRequest(
            version: PineconeGraphicsProtocol.exactCompositeVersion,
            operation: PineconeGraphicsBlendOperator.source.rawValue,
            flags: PineconeGraphicsProtocol.solidSourceFlag |
                PineconeGraphicsProtocol.packedA8DestinationFlag,
            sourceResourceID: 0,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            destinationX: 1,
            destinationY: 0,
            width: 1,
            height: 2,
            color: 0x8000_0000
        )
        XCTAssertEqual(responseType(gpu.process(request: fill, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: destinationBacking, count: 16),
            [64, 128, 7, 7, 7, 7, 7, 7, 192, 128, 7, 7, 7, 7, 7, 7]
        )
    }

    func testPackedA8ExactCompositeIsValidInsideBatchEnvelope() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x40_000)
        let gpu = VirtIOGPUDevice(width: 64, height: 64)
        try createResource(
            id: 11, backing: 0x4001_0000,
            pixels: [UInt8](repeating: 0, count: 64 * 64 * 4),
            width: 64, height: 64, gpu: gpu, memory: memory
        )
        try createResource(
            id: 12, backing: 0x4002_0000,
            pixels: [UInt8](repeating: 128, count: 64 * 64 * 4),
            width: 64, height: 64, gpu: gpu, memory: memory
        )
        let command = paravirtualRequest(
            version: PineconeGraphicsProtocol.exactCompositeVersion,
            operation: PineconeGraphicsBlendOperator.source.rawValue,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag |
                PineconeGraphicsProtocol.packedA8SourceFlag |
                PineconeGraphicsProtocol.packedA8DestinationFlag,
            sourceResourceID: 12,
            destinationResourceID: 11,
            sourceX: 0,
            sourceY: 0,
            sourceWidth: 23,
            sourceHeight: 30,
            destinationX: 0,
            destinationY: 0,
            width: 23,
            height: 30,
            color: 0
        )
        let batch = paravirtualBatchRequest([command])
        XCTAssertEqual(responseType(gpu.process(request: batch, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: 0x4001_0000, count: 23),
            [UInt8](repeating: 128, count: 23)
        )
    }

    func testPackedA8SourceRequiresAlphaSemanticsAndNearestFiltering() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [128, 0, 0, 0], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [0, 0, 0, 0], gpu: gpu, memory: memory
        )

        for invalidFlags in [
            PineconeGraphicsProtocol.packedA8SourceFlag,
            PineconeGraphicsProtocol.packedA8SourceFlag |
                PineconeGraphicsProtocol.sourceContainsAlphaFlag |
                PineconeGraphicsProtocol.bilinearFilterFlag
        ] {
            let command = paravirtualRequest(
                version: PineconeGraphicsProtocol.exactCompositeVersion,
                operation: PineconeGraphicsBlendOperator.source.rawValue,
                flags: invalidFlags,
                sourceResourceID: 1,
                destinationResourceID: 2,
                sourceX: 0,
                sourceY: 0,
                destinationX: 0,
                destinationY: 0,
                width: 1,
                height: 1,
                color: 0
            )
            XCTAssertEqual(
                responseType(gpu.process(request: command, memory: memory)),
                0x1205
            )
        }
    }

    func testExactCompositeAppliesComponentAlphaSourceOver() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [20, 40, 60, 128], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [100, 80, 40, 128], gpu: gpu, memory: memory
        )
        try createResource(
            id: 3, backing: 0x4001_2000,
            pixels: [255, 128, 0, 255], gpu: gpu, memory: memory
        )

        let command = paravirtualRequest(
            version: PineconeGraphicsProtocol.exactCompositeVersion,
            operation: PineconeGraphicsBlendOperator.sourceOver.rawValue,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag |
                PineconeGraphicsProtocol.hasMaskFlag |
                PineconeGraphicsProtocol.componentAlphaMaskFlag,
            sourceResourceID: 1, destinationResourceID: 2,
            sourceX: 0, sourceY: 0, destinationX: 0, destinationY: 0,
            width: 1, height: 1, color: 0, maskResourceID: 3
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: 0x4001_1000, count: 4),
            [70, 80, 40, 192]
        )
    }

    func testExactCompositeAddSaturatesChannels() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [200, 20, 250, 100], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [100, 40, 10, 200], gpu: gpu, memory: memory
        )
        let command = paravirtualRequest(
            version: PineconeGraphicsProtocol.exactCompositeVersion,
            operation: PineconeGraphicsBlendOperator.add.rawValue,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag,
            sourceResourceID: 1, destinationResourceID: 2,
            sourceX: 0, sourceY: 0, destinationX: 0, destinationY: 0,
            width: 1, height: 1, color: 0
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: 0x4001_1000, count: 4),
            [255, 60, 255, 255]
        )
    }

    func testExactCompositeSaturateUsesPixmanUNORMQuantization() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [0x1f, 0x3f, 0x7f, 0xfe], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [0x1f, 0x3f, 0x7f, 0xfe], gpu: gpu, memory: memory
        )
        let command = paravirtualRequest(
            version: PineconeGraphicsProtocol.exactCompositeVersion,
            operation: PineconeGraphicsBlendOperator.saturate.rawValue,
            flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag,
            sourceResourceID: 1, destinationResourceID: 2,
            sourceX: 0, sourceY: 0, destinationX: 0, destinationY: 0,
            width: 1, height: 1, color: 0
        )
        XCTAssertEqual(responseType(gpu.process(request: command, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: 0x4001_1000, count: 4),
            [0x1f, 0x3f, 0x80, 0xff]
        )
    }

    func testExactCompositeSupportsDestinationOverAndSourceIn() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1, backing: 0x4001_0000,
            pixels: [40, 20, 10, 128], gpu: gpu, memory: memory
        )
        try createResource(
            id: 2, backing: 0x4001_1000,
            pixels: [100, 80, 60, 64], gpu: gpu, memory: memory
        )

        func composite(_ operation: PineconeGraphicsBlendOperator) throws -> [UInt8] {
            let command = paravirtualRequest(
                version: PineconeGraphicsProtocol.exactCompositeVersion,
                operation: operation.rawValue,
                flags: PineconeGraphicsProtocol.sourceContainsAlphaFlag,
                sourceResourceID: 1, destinationResourceID: 2,
                sourceX: 0, sourceY: 0, destinationX: 0, destinationY: 0,
                width: 1, height: 1, color: 0
            )
            XCTAssertEqual(
                responseType(gpu.process(request: command, memory: memory)),
                0x1100
            )
            return try memory.readBytes(at: 0x4001_1000, count: 4)
        }

        XCTAssertEqual(try composite(.destinationOver), [130, 95, 67, 160])
        try memory.writeBytes([100, 80, 60, 64], at: 0x4001_1000)
        XCTAssertEqual(try composite(.sourceIn), [10, 5, 3, 32])
    }

    func testNativeFallbackCopiesAndFillsSharedBacking() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let sourceBacking: GuestAddress = 0x4001_0000
        let destinationBacking: GuestAddress = 0x4001_1000
        let gpu = VirtIOGPUDevice(width: 2, height: 1)

        try createResource(
            id: 1,
            backing: sourceBacking,
            pixels: [1, 2, 3, 4, 5, 6, 7, 8],
            width: 2,
            gpu: gpu,
            memory: memory
        )
        try createResource(
            id: 2,
            backing: destinationBacking,
            pixels: [UInt8](repeating: 0, count: 8),
            width: 2,
            gpu: gpu,
            memory: memory
        )

        let copy = paravirtualRequest(
            operation: 1,
            sourceResourceID: 1,
            destinationResourceID: 2,
            sourceX: 1,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0
        )
        XCTAssertEqual(responseType(gpu.process(request: copy, memory: memory)), 0x1100)

        let fill = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 2,
            sourceX: 0,
            sourceY: 0,
            destinationX: 1,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0x4433_2211
        )
        XCTAssertEqual(responseType(gpu.process(request: fill, memory: memory)), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: destinationBacking, count: 8),
            [5, 6, 7, 8, 0x11, 0x22, 0x33, 0x44]
        )
    }

    func testParavirtualBatchExecutesAsOneAcceleratorTransaction() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 2, height: 1)
        let accelerator = RecordingGraphicsAccelerator(color: 0)
        gpu.setGraphicsAccelerator(accelerator)
        try createResource(
            id: 1,
            backing: 0x4001_0000,
            pixels: [UInt8](repeating: 0, count: 8),
            width: 2,
            gpu: gpu,
            memory: memory
        )

        let left = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0xff00_0011
        )
        let right = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 1,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0xff00_0022
        )

        let response = gpu.process(
            request: paravirtualBatchRequest([left, right]),
            memory: memory
        )

        XCTAssertEqual(responseType(response), 0x1100)
        XCTAssertEqual(accelerator.batchSizes, [2])
        XCTAssertEqual(accelerator.commands.map(\.destinationRectangle.x), [0, 1])
        XCTAssertTrue(gpu.diagnosticsSummary().contains("pv2d=2/2:2"))
        XCTAssertTrue(gpu.diagnosticsSummary().contains("/b1/"))
    }

    func testParavirtualBatchNativeFallbackPreservesCommandOrder() throws {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let backing: GuestAddress = 0x4001_0000
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        try createResource(
            id: 1,
            backing: backing,
            pixels: [0, 0, 0, 0],
            gpu: gpu,
            memory: memory
        )
        let first = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0x4433_2211
        )
        let second = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0x8877_6655
        )

        XCTAssertEqual(responseType(gpu.process(
            request: paravirtualBatchRequest([first, second]),
            memory: memory
        )), 0x1100)
        XCTAssertEqual(
            try memory.readBytes(at: backing, count: 4),
            [0x55, 0x66, 0x77, 0x88]
        )
    }

    func testParavirtualBatchRejectsMalformedEnvelope() {
        let memory = PhysicalMemory(base: 0x4000_0000, size: 0x20_000)
        let gpu = VirtIOGPUDevice(width: 1, height: 1)
        let command = paravirtualRequest(
            operation: 3,
            sourceResourceID: 0,
            destinationResourceID: 1,
            sourceX: 0,
            sourceY: 0,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0
        )
        var malformed = paravirtualBatchRequest([command])
        overwriteLE32(63, in: &malformed, at: 40)
        XCTAssertEqual(
            responseType(gpu.process(request: malformed, memory: memory)),
            0x1205
        )
    }

    private func createResource(
        id: UInt32,
        backing: GuestAddress,
        pixels: [UInt8],
        width: UInt32 = 1,
        height: UInt32 = 1,
        gpu: VirtIOGPUDevice,
        memory: PhysicalMemory
    ) throws {
        try memory.writeBytes(pixels, at: backing)
        XCTAssertEqual(responseType(gpu.process(
            request: gpuRequest(type: 0x0101, words: [id, 1, width, height]),
            memory: memory
        )), 0x1100)
        var attach = gpuRequest(type: 0x0106, words: [id, 1])
        appendLE64(backing, to: &attach)
        appendLE32(UInt32(pixels.count), to: &attach)
        appendLE32(0, to: &attach)
        XCTAssertEqual(responseType(gpu.process(request: attach, memory: memory)), 0x1100)
    }

    private func gpuRequest(type: UInt32, words: [UInt32]) -> [UInt8] {
        var bytes: [UInt8] = []
        appendLE32(type, to: &bytes)
        appendLE32(0, to: &bytes)
        appendLE64(0, to: &bytes)
        appendLE32(0, to: &bytes)
        appendLE32(0, to: &bytes)
        for word in words { appendLE32(word, to: &bytes) }
        return bytes
    }

    private func paravirtualRequest(
        version: UInt16 = PineconeGraphicsProtocol.version,
        operation: UInt16,
        flags: UInt32 = 0,
        sourceResourceID: UInt32,
        destinationResourceID: UInt32,
        sourceX: Int32,
        sourceY: Int32,
        sourceWidth: UInt32? = nil,
        sourceHeight: UInt32? = nil,
        destinationX: Int32,
        destinationY: Int32,
        width: UInt32,
        height: UInt32,
        color: UInt32,
        maskResourceID: UInt32 = 0,
        maskAlpha: UInt32 = 0
    ) -> [UInt8] {
        var bytes = gpuRequest(type: 0x0207, words: [64, 0])
        appendLE32(PineconeGraphicsProtocol.magic, to: &bytes)
        appendLE16(version, to: &bytes)
        appendLE16(operation, to: &bytes)
        appendLE32(flags, to: &bytes)
        appendLE32(sourceResourceID, to: &bytes)
        appendLE32(destinationResourceID, to: &bytes)
        appendLE32(UInt32(bitPattern: sourceX), to: &bytes)
        appendLE32(UInt32(bitPattern: sourceY), to: &bytes)
        appendLE32(UInt32(bitPattern: destinationX), to: &bytes)
        appendLE32(UInt32(bitPattern: destinationY), to: &bytes)
        appendLE32(width, to: &bytes)
        appendLE32(height, to: &bytes)
        appendLE32(color, to: &bytes)
        let operationUsesSource = version == PineconeGraphicsProtocol.version
            ? operation == 1 || operation == 2
            : operation != PineconeGraphicsBlendOperator.clear.rawValue &&
                operation != PineconeGraphicsBlendOperator.destination.rawValue &&
                flags & PineconeGraphicsProtocol.solidSourceFlag == 0
        appendLE32(sourceWidth ?? (operationUsesSource ? width : 0), to: &bytes)
        appendLE32(sourceHeight ?? (operationUsesSource ? height : 0), to: &bytes)
        appendLE32(maskResourceID, to: &bytes)
        appendLE32(maskAlpha, to: &bytes)
        return bytes
    }

    private func paravirtualBatchRequest(_ requests: [[UInt8]]) -> [UInt8] {
        let payloadByteCount = PineconeGraphicsProtocol.batchHeaderByteCount +
            requests.count * PineconeGraphicsProtocol.batchRecordByteCount
        var bytes = gpuRequest(
            type: 0x0207,
            words: [UInt32(payloadByteCount), 0]
        )
        appendLE32(PineconeGraphicsProtocol.magic, to: &bytes)
        appendLE16(PineconeGraphicsProtocol.batchVersion, to: &bytes)
        appendLE16(UInt16(requests.count), to: &bytes)
        appendLE16(
            UInt16(PineconeGraphicsProtocol.batchRecordByteCount),
            to: &bytes
        )
        appendLE16(0, to: &bytes)
        appendLE32(UInt32(payloadByteCount), to: &bytes)
        for request in requests {
            bytes.append(contentsOf: request[32..<96])
        }
        return bytes
    }

    private func responseType(_ response: [UInt8]) -> UInt32 {
        UInt32(response[0]) | UInt32(response[1]) << 8 |
            UInt32(response[2]) << 16 | UInt32(response[3]) << 24
    }

    private func appendLE16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendLE32(_ value: UInt32, to bytes: inout [UInt8]) {
        appendLE16(UInt16(truncatingIfNeeded: value), to: &bytes)
        appendLE16(UInt16(truncatingIfNeeded: value >> 16), to: &bytes)
    }

    private func appendLE64(_ value: UInt64, to bytes: inout [UInt8]) {
        appendLE32(UInt32(truncatingIfNeeded: value), to: &bytes)
        appendLE32(UInt32(truncatingIfNeeded: value >> 32), to: &bytes)
    }

    private func overwriteLE32(_ value: UInt32, in bytes: inout [UInt8], at offset: Int) {
        for index in 0..<4 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private func overwriteLE64(_ value: UInt64, in bytes: inout [UInt8], at offset: Int) {
        for index in 0..<8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8))
        }
    }

    private func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { result, index in
            result | UInt32(bytes[offset + index]) << (index * 8)
        }
    }

    private func readLE64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { result, index in
            result | UInt64(bytes[offset + index]) << (index * 8)
        }
    }
}

private final class RecordingGraphicsAccelerator: PineconeGraphicsAccelerator {
    private(set) var commands: [PineconeGraphicsCommand] = []
    private(set) var batchSizes: [Int] = []
    private let color: UInt8

    init(color: UInt32) {
        self.color = UInt8(truncatingIfNeeded: color)
    }

    func execute(
        _ command: PineconeGraphicsCommand,
        source: PineconeGraphicsSurface?,
        mask: PineconeGraphicsSurface?,
        destination: PineconeGraphicsSurface
    ) -> Bool {
        commands.append(command)
        destination.bytes.initializeMemory(as: UInt8.self, repeating: 0x7a)
        return true
    }

    func executeBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool {
        batchSizes.append(workItems.count)
        for item in workItems {
            guard execute(
                item.command,
                source: item.source,
                mask: item.mask,
                destination: item.destination
            ) else { return false }
        }
        return true
    }
}

private final class RectangleGraphicsAccelerator: PineconeGraphicsAccelerator {
    func execute(
        _ command: PineconeGraphicsCommand,
        source: PineconeGraphicsSurface?,
        mask: PineconeGraphicsSurface?,
        destination: PineconeGraphicsSurface
    ) -> Bool {
        let rectangle = command.destinationRectangle
        guard rectangle.width > 0, rectangle.height > 0 else { return false }
        for row in 0..<rectangle.height {
            let offset = (rectangle.y + row) * destination.stride + rectangle.x * 4
            let pixels = destination.bytes.baseAddress!.advanced(by: offset)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0..<rectangle.width {
                pixels[column * 4] = UInt8(truncatingIfNeeded: command.color)
                pixels[column * 4 + 1] = UInt8(truncatingIfNeeded: command.color >> 8)
                pixels[column * 4 + 2] = UInt8(truncatingIfNeeded: command.color >> 16)
                pixels[column * 4 + 3] = UInt8(truncatingIfNeeded: command.color >> 24)
            }
        }
        return true
    }

    func executeBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool {
        workItems.allSatisfy {
            execute(
                $0.command,
                source: $0.source,
                mask: $0.mask,
                destination: $0.destination
            )
        }
    }
}

private final class DeferredRecordingGraphicsAccelerator: PineconeGraphicsAccelerator,
    @unchecked Sendable {
    private var workItems: [PineconeGraphicsWorkItem] = []
    private var completion: (@Sendable (Bool) -> Void)?

    func execute(
        _ command: PineconeGraphicsCommand,
        source: PineconeGraphicsSurface?,
        mask: PineconeGraphicsSurface?,
        destination: PineconeGraphicsSurface
    ) -> Bool {
        false
    }

    func executeBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool {
        false
    }

    func executeBatchAsync(
        _ workItems: [PineconeGraphicsWorkItem],
        completion: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        self.workItems = workItems
        self.completion = completion
        return true
    }

    func complete(success: Bool) {
        if success {
            for item in workItems {
                item.destination.bytes.initializeMemory(
                    as: UInt8.self,
                    repeating: 0x7a
                )
            }
        }
        let callback = completion
        workItems.removeAll(keepingCapacity: false)
        completion = nil
        callback?(success)
    }
}

private final class DeferredResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8]?

    var value: [UInt8]? {
        lock.lock()
        let result = storage
        lock.unlock()
        return result
    }

    func store(_ value: [UInt8]) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
