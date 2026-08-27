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

func runOrderedBatch(accelerator: PineconeMetalGraphicsAccelerator) -> String? {
    let width = 2
    let height = 2
    let stride = 16

    func makeAllocation(_ pixels: [UInt32]) -> Allocation {
        let allocation = Allocation(byteCount: stride * height)
        for (index, pixel) in pixels.enumerated() {
            write(pixel, format: .argb, x: index % width, y: index / width,
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
    ]
    guard accelerator.executeBatch(batchItems) else {
        return "ordered Metal batch was rejected"
    }
    let sequentialResult = Data(
        bytes: sequentialDestination.pointer,
        count: sequentialDestination.byteCount)
    let batchResult = Data(
        bytes: batchDestination.pointer, count: batchDestination.byteCount)
    return sequentialResult == batchResult
        ? nil : "ordered Metal batch violated a read-after-write dependency"
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
if let failure = runOrderedBatch(accelerator: accelerator) {
    fputs(failure + "\n", stderr)
    failures += 1
}
if let failure = runScaling(accelerator: accelerator) {
    fputs(failure + "\n", stderr)
    failures += 1
}
guard failures == 0 else {
    fputs("Metal differential failed after \(failures) mismatches\n", stderr)
    exit(1)
}
print("Metal compositor matches Pixman for \(cases.count) cases")
