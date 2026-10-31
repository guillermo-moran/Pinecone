import Foundation
import Metal

enum TestFormat: Int {
    case argb = 0
    case a8 = 1
    case xrgb = 2
}

struct GoldenCase {
    let id: Int
    let operation: PineconeGraphicsBlendOperator
    let sourceFormat: TestFormat
    let maskKind: Int
    let componentAlpha: Bool
    let destinationFormat: TestFormat
    let source: UInt32
    let mask: UInt32
    let destination: UInt32
    let expected: UInt32
}

final class Allocation {
    let pointer: UnsafeMutableRawPointer
    let byteCount: Int

    init(byteCount: Int) {
        self.byteCount = byteCount
        pointer = .allocate(byteCount: byteCount, alignment: 64)
        pointer.initializeMemory(as: UInt8.self, repeating: 0xa5, count: byteCount)
    }

    deinit {
        pointer.deallocate()
    }

    func surface(
        id: UInt32,
        width: Int,
        height: Int,
        stride: Int,
        format: TestFormat
    ) -> PineconeGraphicsSurface {
        PineconeGraphicsSurface(
            resourceID: id,
            width: width,
            height: height,
            stride: stride,
            pixelFormat: format == .xrgb ? .bgrx8 : .bgra8Premultiplied,
            bytes: UnsafeMutableRawBufferPointer(start: pointer, count: byteCount),
            allocationByteCount: byteCount
        )
    }
}

func parseCases(at path: String) throws -> [GoldenCase] {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    return try text.split(separator: "\n").compactMap { line in
        if line.first == "#" { return nil }
        let fields = line.split(separator: " ")
        guard fields.count == 10,
              let id = Int(fields[0]),
              let operationValue = UInt16(fields[1]),
              let operation = PineconeGraphicsBlendOperator(rawValue: operationValue),
              let sourceValue = Int(fields[2]),
              let sourceFormat = TestFormat(rawValue: sourceValue),
              let maskKind = Int(fields[3]),
              let component = Int(fields[4]),
              let destinationValue = Int(fields[5]),
              let destinationFormat = TestFormat(rawValue: destinationValue),
              let source = UInt32(fields[6], radix: 16),
              let mask = UInt32(fields[7], radix: 16),
              let destination = UInt32(fields[8], radix: 16),
              let expected = UInt32(fields[9], radix: 16) else {
            throw NSError(domain: "PineconeMetalDifferential", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Malformed case: \(line)"])
        }
        return GoldenCase(
            id: id, operation: operation, sourceFormat: sourceFormat,
            maskKind: maskKind, componentAlpha: component != 0,
            destinationFormat: destinationFormat, source: source, mask: mask,
            destination: destination, expected: expected
        )
    }
}

func stride(for format: TestFormat) -> Int {
    format == .a8 ? 8 : 32
}

func write(
    _ pixel: UInt32,
    format: TestFormat,
    x: Int,
    y: Int,
    stride: Int,
    to pointer: UnsafeMutableRawPointer
) {
    let offset = y * stride + x * (format == .a8 ? 1 : 4)
    if format == .a8 {
        pointer.storeBytes(of: UInt8(pixel >> 24), toByteOffset: offset, as: UInt8.self)
    } else {
        pointer.storeBytes(of: pixel.littleEndian, toByteOffset: offset, as: UInt32.self)
    }
}

func read(
    format: TestFormat,
    x: Int,
    y: Int,
    stride: Int,
    from pointer: UnsafeMutableRawPointer
) -> UInt32 {
    let offset = y * stride + x * (format == .a8 ? 1 : 4)
    if format == .a8 {
        return UInt32(pointer.load(fromByteOffset: offset, as: UInt8.self)) << 24
    }
    return UInt32(littleEndian:
        pointer.load(fromByteOffset: offset, as: UInt32.self))
}

func run(_ test: GoldenCase, accelerator: PineconeMetalGraphicsAccelerator) -> String? {
    let width = 3
    let height = 3
    let sourceStride = stride(for: test.sourceFormat)
    let destinationStride = stride(for: test.destinationFormat)
    let maskFormat: TestFormat = test.maskKind == 1 ? .a8 : .argb
    let maskStride = stride(for: maskFormat)
    let sourceAllocation = Allocation(byteCount: sourceStride * height)
    let destinationAllocation = Allocation(byteCount: destinationStride * height)
    let maskAllocation = Allocation(byteCount: maskStride * height)
    write(test.source, format: test.sourceFormat, x: 1, y: 1,
          stride: sourceStride, to: sourceAllocation.pointer)
    write(test.destination, format: test.destinationFormat, x: 1, y: 1,
          stride: destinationStride, to: destinationAllocation.pointer)
    write(test.mask, format: maskFormat, x: 0, y: 0,
          stride: maskStride, to: maskAllocation.pointer)
    let initialSource = Data(
        bytes: sourceAllocation.pointer, count: sourceAllocation.byteCount)
    let initialMask = Data(
        bytes: maskAllocation.pointer, count: maskAllocation.byteCount)
    let initialDestination = Data(
        bytes: destinationAllocation.pointer,
        count: destinationAllocation.byteCount)

    let source = sourceAllocation.surface(
        id: UInt32(test.id * 3 + 1), width: width, height: height,
        stride: sourceStride, format: test.sourceFormat)
    let destination = destinationAllocation.surface(
        id: UInt32(test.id * 3 + 2), width: width, height: height,
        stride: destinationStride, format: test.destinationFormat)
    let mask = maskAllocation.surface(
        id: UInt32(test.id * 3 + 3), width: width, height: height,
        stride: maskStride, format: maskFormat)
    let command = PineconeGraphicsCommand(
        operation: .sourceOver,
        sourceResourceID: source.resourceID,
        destinationResourceID: destination.resourceID,
        sourceX: 1,
        sourceY: 1,
        sourceWidth: 1,
        sourceHeight: 1,
        destinationRectangle: PineconeGraphicsRectangle(
            x: 1, y: 1, width: 1, height: 1),
        sourceContainsAlpha: test.sourceFormat != .xrgb,
        maskResourceID: test.maskKind == 0 ? 0 : mask.resourceID,
        blendOperator: test.operation,
        componentAlphaMask: test.componentAlpha,
        maskIsPackedA8: test.maskKind == 1,
        sourceIsPackedA8: test.sourceFormat == .a8,
        destinationIsPackedA8: test.destinationFormat == .a8
    )
    guard accelerator.execute(
        command,
        source: source,
        mask: test.maskKind == 0 ? nil : mask,
        destination: destination
    ) else {
        return "case \(test.id) op=\(test.operation.rawValue) was rejected"
    }
    let actual = read(
        format: test.destinationFormat, x: 1, y: 1,
        stride: destinationStride, from: destinationAllocation.pointer)
    let comparisonMask: UInt32 = test.destinationFormat == .xrgb
        ? 0x00ff_ffff : 0xffff_ffff
    guard actual & comparisonMask == test.expected & comparisonMask else {
        return String(format:
            "case %d op=%d srcfmt=%d mask=%d component=%d dstfmt=%d " +
            "src=%08x maskpx=%08x dst=%08x expected=%08x actual=%08x",
            test.id, test.operation.rawValue, test.sourceFormat.rawValue,
            test.maskKind, test.componentAlpha ? 1 : 0,
            test.destinationFormat.rawValue, test.source, test.mask,
            test.destination, test.expected, actual)
    }
    guard Data(bytes: sourceAllocation.pointer, count: sourceAllocation.byteCount) ==
            initialSource,
          Data(bytes: maskAllocation.pointer, count: maskAllocation.byteCount) ==
            initialMask else {
        return "case \(test.id) modified a read-only source or mask"
    }
    let bytesPerPixel = test.destinationFormat == .a8 ? 1 : 4
    let targetOffset = destinationStride + bytesPerPixel
    let finalDestination = Data(
        bytes: destinationAllocation.pointer,
        count: destinationAllocation.byteCount)
    for index in 0..<finalDestination.count
    where index < targetOffset || index >= targetOffset + bytesPerPixel {
        if finalDestination[index] != initialDestination[index] {
            return "case \(test.id) wrote outside its destination rectangle at \(index)"
        }
    }
    return nil
}

func runOrderedBatch(accelerator: PineconeMetalGraphicsAccelerator, asynchronous: Bool) -> String? {
    // Span multiple workgroups and partial edge groups; retain row padding.
    let width = 65
    let height = 33
    let stride = 272

    func makeAllocation(_ pixels: [UInt32]) -> Allocation {
        let allocation = Allocation(byteCount: stride * height)
        for index in 0..<(width * height) {
            write(pixels[index % pixels.count], format: .argb, x: index % width, y: index / width,
                  stride: stride, to: allocation.pointer)
        }
        return allocation
    }

    let sourcePixels: [UInt32] = [
        0x80402010, 0xff302010, 0x400c2010, 0x01010101,
    ]
    let overlayPixels: [UInt32] = [
        0x40100804, 0x80201008, 0xff010203, 0x00000000,
    ]
    let initialPixels: [UInt32] = [
        0x20080402, 0x60301808, 0x10040302, 0x80402010,
    ]
    let sequentialSource = makeAllocation(sourcePixels)
    let sequentialOverlay = makeAllocation(overlayPixels)
    let sequentialIntermediate = makeAllocation(initialPixels)
    let sequentialDestination = makeAllocation(initialPixels.reversed())
    let batchSource = makeAllocation(sourcePixels)
    let batchOverlay = makeAllocation(overlayPixels)
    let batchIntermediate = makeAllocation(initialPixels)
    let batchDestination = makeAllocation(initialPixels.reversed())

    func surface(_ allocation: Allocation, id: UInt32) -> PineconeGraphicsSurface {
        allocation.surface(
            id: id, width: width, height: height, stride: stride, format: .argb)
    }
    func work(
        operation: PineconeGraphicsBlendOperator,
        source: PineconeGraphicsSurface,
        destination: PineconeGraphicsSurface
    ) -> PineconeGraphicsWorkItem {
        let command = PineconeGraphicsCommand(
            operation: operation == .source ? .source : .sourceOver,
            sourceResourceID: source.resourceID,
            destinationResourceID: destination.resourceID,
            sourceX: 0, sourceY: 0, sourceWidth: width, sourceHeight: height,
            destinationRectangle: PineconeGraphicsRectangle(
                x: 0, y: 0, width: width, height: height),
            sourceContainsAlpha: true,
            blendOperator: operation
        )
        return PineconeGraphicsWorkItem(
            command: command, source: source, mask: nil,
            destination: destination)
    }

    func maskedWork(mask: PineconeGraphicsSurface, destination: PineconeGraphicsSurface) -> PineconeGraphicsWorkItem {
        PineconeGraphicsWorkItem(command: PineconeGraphicsCommand(
            operation: .fillOver, sourceResourceID: 0,
            destinationResourceID: destination.resourceID,
            sourceX: 0, sourceY: 0,
            destinationRectangle: PineconeGraphicsRectangle(x: 0, y: 0, width: width, height: height),
            color: 0x80402010, maskResourceID: mask.resourceID,
            blendOperator: .sourceOver, sourceIsSolid: true),
            source: nil, mask: mask, destination: destination)
    }
    let sequentialItems = [
        work(operation: .source,
             source: surface(sequentialSource, id: 900_001),
             destination: surface(sequentialIntermediate, id: 900_002)),
        work(operation: .sourceOver,
             source: surface(sequentialIntermediate, id: 900_002),
             destination: surface(sequentialDestination, id: 900_003)),
        work(operation: .add,
             source: surface(sequentialOverlay, id: 900_004),
             destination: surface(sequentialDestination, id: 900_003)),
        // Overwrite a previously read source, then consume it as an image mask.
        work(operation: .source,
             source: surface(sequentialOverlay, id: 900_004),
             destination: surface(sequentialSource, id: 900_001)),
        maskedWork(mask: surface(sequentialSource, id: 900_001),
                   destination: surface(sequentialDestination, id: 900_003)),
    ]
    for item in sequentialItems {
        guard accelerator.execute(
            item.command, source: item.source, mask: item.mask,
            destination: item.destination) else {
            return "ordered sequential control was rejected"
        }
    }

    let batchItems = [
        work(operation: .source,
             source: surface(batchSource, id: 910_001),
             destination: surface(batchIntermediate, id: 910_002)),
        work(operation: .sourceOver,
             source: surface(batchIntermediate, id: 910_002),
             destination: surface(batchDestination, id: 910_003)),
        work(operation: .add,
             source: surface(batchOverlay, id: 910_004),
             destination: surface(batchDestination, id: 910_003)),
        work(operation: .source,
             source: surface(batchOverlay, id: 910_004),
             destination: surface(batchSource, id: 910_001)),
        maskedWork(mask: surface(batchSource, id: 910_001),
                   destination: surface(batchDestination, id: 910_003)),
    ]
    let before = accelerator.performanceCounters
    if asynchronous {
        final class Result: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func record(_ succeeded: Bool) {
                lock.lock()
                value = succeeded
                lock.unlock()
            }
            func read() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }
        let done = DispatchSemaphore(value: 0)
        let result = Result()
        guard accelerator.executeBatchAsync(batchItems, completion: { success in
            result.record(success)
            done.signal()
        }) else { return "async ordered batch rejected" }
        guard done.wait(timeout: .now() + 30) == .success else {
            // Do not release guest buffers still owned by the GPU on failure.
            fputs("async ordered batch timed out\n", stderr)
            exit(1)
        }
        guard result.read() else { return "async ordered batch failed" }
    } else if !accelerator.executeBatch(batchItems) {
        return "ordered Metal batch was rejected"
    }
    let after = accelerator.performanceCounters
    guard after["completedBatches"]! - before["completedBatches"]! == 1 else {
        return "ordered work was split into multiple command buffers"
    }
    for (sequential, batch) in [(sequentialSource, batchSource),
                                (sequentialIntermediate, batchIntermediate),
                                (sequentialDestination, batchDestination)] {
        if Data(bytes: sequential.pointer, count: sequential.byteCount) !=
            Data(bytes: batch.pointer, count: batch.byteCount) {
            return "ordered Metal batch violated source/mask/write ordering or padding"
        }
    }
    return nil
}

func runPartialBatch(accelerator: PineconeMetalGraphicsAccelerator) -> String? {
    // Intersecting L-shapes leave a hole inside their bounding box. Read the
    // entire intermediate afterwards to exercise both upload and copyback.
    let rectangles = [
        PineconeGraphicsRectangle(x: 0, y: 0, width: 3, height: 1),
        PineconeGraphicsRectangle(x: 0, y: 0, width: 1, height: 3),
        PineconeGraphicsRectangle(x: 3, y: 3, width: 1, height: 1)
    ]
    let a = Allocation(byteCount: 64)
    let b = Allocation(byteCount: 64)
    for y in 0..<4 {
        for x in 0..<4 {
            write(0xff112233, format: .argb, x: x, y: y, stride: 16, to: a.pointer)
            write(0xff445566, format: .argb, x: x, y: y, stride: 16, to: b.pointer)
        }
    }
    let source = a.surface(id: 930_001, width: 4, height: 4, stride: 16, format: .argb)
    let destination = b.surface(id: 930_002, width: 4, height: 4, stride: 16, format: .argb)
    var items = rectangles.map { rect in
        PineconeGraphicsWorkItem(command: PineconeGraphicsCommand(
            operation: .fill, sourceResourceID: 0, destinationResourceID: source.resourceID,
            sourceX: 0, sourceY: 0, sourceWidth: 0, sourceHeight: 0,
            destinationRectangle: rect, color: 0xff778899,
            blendOperator: .source, sourceIsSolid: true), source: nil, mask: nil, destination: source)
    }
    items.append(PineconeGraphicsWorkItem(command: PineconeGraphicsCommand(
        operation: .source, sourceResourceID: source.resourceID,
        destinationResourceID: destination.resourceID,
        sourceX: 0, sourceY: 0, sourceWidth: 4, sourceHeight: 4,
        destinationRectangle: PineconeGraphicsRectangle(x: 0, y: 0, width: 4, height: 4),
        sourceContainsAlpha: true, blendOperator: .source),
        source: source, mask: nil, destination: destination))
    guard accelerator.executeBatch(items) else { return "partial batch rejected" }
    for y in 0..<4 {
        for x in 0..<4 {
            let written = rectangles.contains { x >= $0.x && x < $0.x + $0.width &&
                                                y >= $0.y && y < $0.y + $0.height }
            let expected: UInt32 = written ? 0xff778899 : 0xff112233
            for allocation in [a, b] {
                if read(format: .argb, x: x, y: y, stride: 16,
                        from: allocation.pointer) != expected {
                    return "partial batch corrupted pixel (\(x), \(y))"
                }
            }
        }
    }
    return nil
}

func runScaling(accelerator: PineconeMetalGraphicsAccelerator) -> String? {
    let sourceStride = 16
    let destinationStride = 16
    let sourceAllocation = Allocation(byteCount: sourceStride)
    write(0xff000000, format: .argb, x: 0, y: 0,
          stride: sourceStride, to: sourceAllocation.pointer)
    write(0xfff0c864, format: .argb, x: 1, y: 0,
          stride: sourceStride, to: sourceAllocation.pointer)
    let source = sourceAllocation.surface(
        id: 920_001, width: 2, height: 1, stride: sourceStride, format: .argb)

    for bilinear in [false, true] {
        let destinationAllocation = Allocation(byteCount: destinationStride)
        let destination = destinationAllocation.surface(
            id: bilinear ? 920_003 : 920_002,
            width: 3, height: 1, stride: destinationStride, format: .argb)
        let command = PineconeGraphicsCommand(
            operation: .source,
            sourceResourceID: source.resourceID,
            destinationResourceID: destination.resourceID,
            sourceX: 0, sourceY: 0, sourceWidth: 2, sourceHeight: 1,
            destinationRectangle: PineconeGraphicsRectangle(
                x: 0, y: 0, width: 3, height: 1),
            sourceContainsAlpha: true,
            usesBilinearFiltering: bilinear,
            blendOperator: .source
        )
        guard accelerator.execute(
            command, source: source, mask: nil, destination: destination) else {
            return "\(bilinear ? "bilinear" : "nearest") scaling was rejected"
        }
        let expected: [UInt32] = bilinear
            ? [0xff000000, 0xff786432, 0xfff0c864]
            : [0xff000000, 0xff000000, 0xfff0c864]
        for (x, pixel) in expected.enumerated() {
            let actual = read(
                format: .argb, x: x, y: 0, stride: destinationStride,
                from: destinationAllocation.pointer)
            if actual != pixel {
                return String(format:
                    "%@ scaling pixel %d expected=%08x actual=%08x",
                    bilinear ? "bilinear" : "nearest", x, pixel, actual)
            }
        }
    }
    return nil
}

#if PINECONE_TEST_SIMULATOR_COPY
func runOverlappingReadSnapshots(accelerator: PineconeMetalGraphicsAccelerator) -> String? {
    final class Results {
        let lock = NSLock()
        var succeeded = true
        func record(_ value: Bool) {
            lock.lock()
            succeeded = succeeded && value
            lock.unlock()
        }
    }
    guard let device = MTLCreateSystemDefaultDevice(), let event = device.makeSharedEvent(),
          accelerator.enqueueTestWait(for: event, value: 1) else {
        return "cannot gate overlapping staging regression"
    }
    defer { event.signaledValue = 1 }
    let source = Allocation(byteCount: 16)
    let first = Allocation(byteCount: 16)
    let second = Allocation(byteCount: 16)
    let sourceSurface = source.surface(id: 940_001, width: 1, height: 1, stride: 16, format: .argb)
    let group = DispatchGroup()
    let results = Results()
    func submit(_ destination: Allocation, id: UInt32) -> Bool {
        let target = destination.surface(id: id, width: 1, height: 1, stride: 16, format: .argb)
        let command = PineconeGraphicsCommand(
            operation: .source, sourceResourceID: sourceSurface.resourceID,
            destinationResourceID: id, sourceX: 0, sourceY: 0, sourceWidth: 1, sourceHeight: 1,
            destinationRectangle: PineconeGraphicsRectangle(x: 0, y: 0, width: 1, height: 1),
            sourceContainsAlpha: true, blendOperator: .source)
        group.enter()
        let accepted = accelerator.executeBatchAsync([
            PineconeGraphicsWorkItem(command: command, source: sourceSurface, mask: nil, destination: target)
        ]) { succeeded in
            results.record(succeeded)
            group.leave()
        }
        if !accepted { group.leave() }
        return accepted
    }
    write(0xff123456, format: .argb, x: 0, y: 0, stride: 16, to: source.pointer)
    let acceptedFirst = submit(first, id: 940_002)
    // The GPU cannot run yet. A second CPU upload must not overwrite its source
    // staging buffer, even though both commands refer to the same resource ID.
    write(0xffabcdef, format: .argb, x: 0, y: 0, stride: 16, to: source.pointer)
    let acceptedSecond = submit(second, id: 940_003)
    event.signaledValue = 1
    guard group.wait(timeout: .now() + 10) == .success else {
        return "overlapping staging completions timed out"
    }
    guard acceptedFirst, acceptedSecond, results.succeeded else {
        return "overlapping staging submission failed"
    }
    guard read(format: .argb, x: 0, y: 0, stride: 16, from: first.pointer) == 0xff123456,
          read(format: .argb, x: 0, y: 0, stride: 16, from: second.pointer) == 0xffabcdef else {
        return "overlapping read submissions shared a mutable Metal staging buffer"
    }
    return nil
}
#endif

func runCostTelemetry(accelerator: PineconeMetalGraphicsAccelerator) -> String? {
    accelerator.reset()
    let storage = Allocation(byteCount: 128)
    let target = storage.surface(id: 950_001, width: 8, height: 4, stride: 32, format: .argb)
    func item(packed: Bool = false) -> PineconeGraphicsWorkItem {
        PineconeGraphicsWorkItem(command: PineconeGraphicsCommand(
            operation: .fillOver, sourceResourceID: 0, destinationResourceID: target.resourceID,
            sourceX: 0, sourceY: 0,
            destinationRectangle: PineconeGraphicsRectangle(x: 1, y: 1, width: 3, height: 2),
            color: 0x80402010, destinationIsPackedA8: packed),
            source: nil, mask: nil, destination: target)
    }
    guard accelerator.executeBatch([item()]) else { return "telemetry draw rejected" }
    let costs = accelerator.performanceCounters
    guard costs["completedCommands"] == 1, costs["completedPixels"] == 6,
          (costs["preparationMilliseconds"] ?? 0) > 0 else {
        return "command preparation cost counters incorrect"
    }
#if PINECONE_TEST_SIMULATOR_COPY
    guard costs["inputCopyBytes"] == 24, costs["outputCopyBytes"] == 24,
          (costs["inputCopyMilliseconds"] ?? 0) > 0,
          (costs["outputCopyMilliseconds"] ?? 0) > 0 else {
        return "Simulator rectangle copy counters incorrect: \(costs)"
    }
#else
    guard costs["inputCopyBytes"] == 0, costs["outputCopyBytes"] == 0 else {
        return "direct Metal must not report Simulator staging bytes"
    }
#endif
    guard !accelerator.acceptsBatch([item(), item(packed: true)]),
          accelerator.performanceCounters["rejectedEligibility.mixedPackedFormats.checks"] == 1,
          accelerator.performanceCounters["rejectedEligibility.mixedPackedFormats.pixels"] == 12 else {
        return "mixed packed formats rejection counters incorrect"
    }
    accelerator.discardSurface(resourceID: target.resourceID)
    guard accelerator.executeBatch([item()]) else { return "discard/reuse rejected" }
    accelerator.reset()
    let reset = accelerator.performanceCounters
    for key in ["completedCommands", "completedPixels", "preparationMilliseconds",
                "gpuExecutionMilliseconds", "inputCopyBytes", "outputCopyBytes",
                "inputCopyMilliseconds", "outputCopyMilliseconds"] {
        if reset[key] != 0 { return "reset retained \(key)" }
    }
    if reset.keys.contains(where: { $0.hasPrefix("rejectedEligibility.") }) {
        return "reset retained rejection checks"
    }
    let savedThreshold = ProcessInfo.processInfo.environment["PINECONE_METAL_MIN_PIXELS"]
    setenv("PINECONE_METAL_MIN_PIXELS", "100", 1)
    defer {
        if let savedThreshold { setenv("PINECONE_METAL_MIN_PIXELS", savedThreshold, 1) }
        else { unsetenv("PINECONE_METAL_MIN_PIXELS") }
    }
    guard let threshold = PineconeMetalGraphicsAccelerator(),
          !threshold.acceptsBatch([item()]),
          threshold.performanceCounters["rejectedEligibility.belowThreshold.checks"] == 1,
          threshold.performanceCounters["rejectedEligibility.belowThreshold.pixels"] == 6 else {
        return "threshold rejection counters incorrect"
    }
    return nil
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: metal-differential GOLDEN-CASES\n", stderr)
    exit(2)
}
guard let accelerator = PineconeMetalGraphicsAccelerator() else {
    fputs("Metal is unavailable\n", stderr)
    exit(2)
}
let cases = try parseCases(at: CommandLine.arguments[1])
var failures = 0
for test in cases {
    if let failure = run(test, accelerator: accelerator) {
        fputs(failure + "\n", stderr)
        failures += 1
        if failures >= 40 { break }
    }
}
for asynchronous in [false, true] {
    if let failure = runOrderedBatch(accelerator: accelerator, asynchronous: asynchronous) {
        fputs(failure + "\n", stderr)
        failures += 1
    }
}
if let failure = runScaling(accelerator: accelerator) {
    fputs(failure + "\n", stderr)
    failures += 1
}
if let failure = runPartialBatch(accelerator: accelerator) {
    fputs(failure + "\n", stderr)
    failures += 1
}
#if PINECONE_TEST_SIMULATOR_COPY
if let failure = runOverlappingReadSnapshots(accelerator: accelerator) {
    fputs(failure + "\n", stderr)
    failures += 1
}
#endif
if let failure = runCostTelemetry(accelerator: accelerator) {
    fputs(failure + "\n", stderr)
    failures += 1
}
guard failures == 0 else {
    fputs("Metal differential failed after \(failures) mismatches\n", stderr)
    exit(1)
}
print("Metal compositor matches Pixman for \(cases.count) cases; copy/rejection/reset telemetry passed")
