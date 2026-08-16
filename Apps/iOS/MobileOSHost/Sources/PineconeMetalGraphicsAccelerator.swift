import ARM64VizCore
import Foundation
import Metal

final class PineconeMetalGraphicsAccelerator: PineconeGraphicsAccelerator {
#if targetEnvironment(simulator)
    private static let defaultMinimumMetalPixelCount = 8_192
#else
    // A synchronous Metal submission has a fixed scheduling cost. Keep small
    // glyph, icon, and control composites in the native C rasterizer and use
    // Metal for large surfaces or batches that amortize the command-buffer wait.
    private static let defaultMinimumMetalPixelCount = 32_768
#endif
    private struct Parameters {
        var operation: UInt32
        var sourceStridePixels: UInt32
        var destinationStridePixels: UInt32
        var sourceX: UInt32
        var sourceY: UInt32
        var sourceWidth: UInt32
        var sourceHeight: UInt32
        var destinationX: UInt32
        var destinationY: UInt32
        var width: UInt32
        var height: UInt32
        var color: UInt32
        var sourceOpaque: UInt32
        var destinationOpaque: UInt32
        var bilinearFiltering: UInt32
        var maskStridePixels: UInt32
        var maskAlpha: UInt32
        var hasImageMask: UInt32
        var sourceIsSolid: UInt32
        var componentAlphaMask: UInt32
        var maskIsPackedA8: UInt32
    }

    private struct CachedBuffer {
        let address: UInt
        let allocationByteCount: Int
        let buffer: MTLBuffer
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let minimumMetalPixelCount: Int
    private let lock = NSLock()
    private var cachedBuffers: [UInt32: CachedBuffer] = [:]
    private var completedCommandCount: UInt64 = 0
    private var completedBatchCount: UInt64 = 0
    private var completedPixelCount: UInt64 = 0
    private var commandNanoseconds: [UInt64] = []
    private var gpuWaitNanoseconds: [UInt64] = []

    var diagnosticsSummary: String {
        lock.lock()
        let commands = completedCommandCount
        let batches = completedBatchCount
        let pixels = completedPixelCount
        let commandP95 = Self.percentileMilliseconds(commandNanoseconds)
        let waitP95 = Self.percentileMilliseconds(gpuWaitNanoseconds)
        lock.unlock()
        guard commands > 0 else { return "" }
        return "metal=\(commands)/b\(batches):\(pixels) t95=" +
            "\(String(format: "%.2f", commandP95))/" +
            "\(String(format: "%.2f", waitP95))ms"
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let function = library.makeFunction(name: "pineconeComposite2D"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        let requestedThreshold = ProcessInfo.processInfo.environment[
            "PINECONE_METAL_MIN_PIXELS"
        ].flatMap(Int.init)
        self.minimumMetalPixelCount = max(
            0,
            requestedThreshold ?? Self.defaultMinimumMetalPixelCount
        )
    }

    func execute(
        _ command: PineconeGraphicsCommand,
        source: PineconeGraphicsSurface?,
        mask: PineconeGraphicsSurface?,
        destination: PineconeGraphicsSurface
    ) -> Bool {
        executeBatch([PineconeGraphicsWorkItem(
            command: command,
            source: source,
            mask: mask,
            destination: destination
        )])
    }

    func executeBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool {
        guard !workItems.isEmpty,
              workItems.count <= PineconeGraphicsProtocol.maximumBatchCommandCount else {
            return workItems.isEmpty
        }
        lock.lock()
        defer { lock.unlock() }
        let commandStarted = DispatchTime.now().uptimeNanoseconds

        var totalPixelCount = 0
        for item in workItems {
            let command = item.command
            let rectangle = command.destinationRectangle
            guard rectangle.width > 0, rectangle.height > 0,
                  rectangle.x >= 0, rectangle.y >= 0,
                  command.sourceX >= 0, command.sourceY >= 0,
                  rectangle.x + rectangle.width <= item.destination.width,
                  rectangle.y + rectangle.height <= item.destination.height,
                  rectangle.width <= Int(UInt32.max),
                  rectangle.height <= Int(UInt32.max),
                  command.sourceWidth >= 0,
                  command.sourceHeight >= 0,
                  command.sourceWidth <= Int(UInt32.max),
                  command.sourceHeight <= Int(UInt32.max),
                  dispatchGeometry(width: rectangle.width, height: rectangle.height) != nil,
                  buffer(for: item.destination) != nil else {
                return false
            }
            let sourceRequired = command.blendOperator != .clear &&
                command.blendOperator != .destination && !command.sourceIsSolid
            if sourceRequired {
                guard let source = item.source,
                      command.sourceWidth > 0,
                      command.sourceHeight > 0,
                      command.sourceX + command.sourceWidth <= source.width,
                      command.sourceY + command.sourceHeight <= source.height,
                      buffer(for: source) != nil else {
                    return false
                }
            }
            if let mask = item.mask {
                guard mask.width >= rectangle.width,
                      mask.height >= rectangle.height,
                      buffer(for: mask) != nil else { return false }
            }
            let pixels = rectangle.width.multipliedReportingOverflow(by: rectangle.height)
            guard !pixels.overflow,
                  totalPixelCount <= Int.max - pixels.partialValue else { return false }
            totalPixelCount += pixels.partialValue
        }
        guard totalPixelCount >= minimumMetalPixelCount,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }

        var gpuWrittenResources = Set<UInt32>()
#if targetEnvironment(simulator)
        var dirtyRectangles: [UInt32: PineconeGraphicsRectangle] = [:]
        var destinationSurfaces: [UInt32: PineconeGraphicsSurface] = [:]
#endif

        encoder.setComputePipelineState(pipeline)
        for item in workItems {
            let command = item.command
            let source = item.source
            let mask = item.mask
            let destination = item.destination
            let rectangle = command.destinationRectangle
            guard let destinationBuffer = buffer(for: destination),
                  let sourceBuffer = source.map(buffer(for:)) ?? destinationBuffer,
                  let maskBuffer = mask.map(buffer(for:)) ?? destinationBuffer,
                  let geometry = dispatchGeometry(
                    width: rectangle.width,
                    height: rectangle.height
                  ) else {
                encoder.endEncoding()
                return false
            }

#if targetEnvironment(simulator)
            if let source,
               !command.sourceIsSolid,
               !gpuWrittenResources.contains(source.resourceID) {
                synchronize(
                    source, to: sourceBuffer,
                    x: command.sourceX, y: command.sourceY,
                    width: command.sourceWidth, height: command.sourceHeight
                )
            }
            if command.blendOperator == .sourceOver ||
                command.blendOperator == .add ||
                command.blendOperator == .destination,
               !gpuWrittenResources.contains(destination.resourceID) {
                synchronize(
                    destination, to: destinationBuffer,
                    x: rectangle.x, y: rectangle.y,
                    width: rectangle.width, height: rectangle.height
                )
            }
            if let mask, !gpuWrittenResources.contains(mask.resourceID) {
                synchronize(
                    mask, to: maskBuffer,
                    x: 0, y: 0,
                    width: rectangle.width, height: rectangle.height
                )
            }
#endif

            var parameters = Parameters(
                operation: UInt32(command.blendOperator.rawValue),
                sourceStridePixels: UInt32(source?.stride ?? destination.stride) / 4,
                destinationStridePixels: UInt32(destination.stride) / 4,
                sourceX: UInt32(command.sourceX),
                sourceY: UInt32(command.sourceY),
                sourceWidth: UInt32(command.sourceWidth),
                sourceHeight: UInt32(command.sourceHeight),
                destinationX: UInt32(rectangle.x),
                destinationY: UInt32(rectangle.y),
                width: UInt32(rectangle.width),
                height: UInt32(rectangle.height),
                color: command.color,
                sourceOpaque: source?.pixelFormat == .bgrx8 &&
                    !command.sourceContainsAlpha ? 1 : 0,
                destinationOpaque: destination.pixelFormat == .bgrx8 ? 1 : 0,
                bilinearFiltering: command.usesBilinearFiltering ? 1 : 0,
                maskStridePixels: UInt32(mask?.stride ?? destination.stride) / 4,
                maskAlpha: UInt32(command.maskAlpha ?? UInt8.max),
                hasImageMask: mask == nil ? 0 : 1,
                sourceIsSolid: command.sourceIsSolid ? 1 : 0,
                componentAlphaMask: command.componentAlphaMask ? 1 : 0,
                maskIsPackedA8: command.maskIsPackedA8 ? 1 : 0
            )
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(destinationBuffer, offset: 0, index: 1)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            encoder.setBytes(
                &parameters,
                length: MemoryLayout<Parameters>.stride,
                index: 3
            )
        // dispatchThreads requires non-uniform threadgroup support. Phosh emits
        // arbitrary damage rectangles, so use rounded-up threadgroups and let
        // the shader's bounds check discard edge threads on every Metal device.
        encoder.dispatchThreadgroups(
            geometry.threadgroups,
            threadsPerThreadgroup: geometry.threadsPerThreadgroup
        )
            gpuWrittenResources.insert(destination.resourceID)
#if targetEnvironment(simulator)
            destinationSurfaces[destination.resourceID] = destination
            if let existing = dirtyRectangles[destination.resourceID] {
                let left = min(existing.x, rectangle.x)
                let top = min(existing.y, rectangle.y)
                let right = max(existing.x + existing.width, rectangle.x + rectangle.width)
                let bottom = max(existing.y + existing.height, rectangle.y + rectangle.height)
                dirtyRectangles[destination.resourceID] = PineconeGraphicsRectangle(
                    x: left, y: top, width: right - left, height: bottom - top
                )
            } else {
                dirtyRectangles[destination.resourceID] = rectangle
            }
#endif
        }
        encoder.endEncoding()
        commandBuffer.commit()
        let waitStarted = DispatchTime.now().uptimeNanoseconds
        commandBuffer.waitUntilCompleted()
        let completedAt = DispatchTime.now().uptimeNanoseconds
        Self.append(completedAt &- commandStarted, to: &commandNanoseconds)
        Self.append(completedAt &- waitStarted, to: &gpuWaitNanoseconds)
        completedCommandCount &+= UInt64(workItems.count)
        completedBatchCount &+= 1
        completedPixelCount &+= UInt64(totalPixelCount)
        guard commandBuffer.status == .completed else { return false }

#if targetEnvironment(simulator)
        for (resourceID, rectangle) in dirtyRectangles {
            guard let destination = destinationSurfaces[resourceID],
                  let destinationBuffer = buffer(for: destination),
                  let destinationBytes = destination.bytes.baseAddress else { return false }
            for row in 0..<rectangle.height {
                let offset = (rectangle.y + row) * destination.stride + rectangle.x * 4
                memcpy(
                    destinationBytes.advanced(by: offset),
                    destinationBuffer.contents().advanced(by: offset),
                    rectangle.width * 4
                )
            }
        }
#endif
        return true
    }

    func discardSurface(resourceID: UInt32) {
        lock.lock()
        cachedBuffers.removeValue(forKey: resourceID)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cachedBuffers.removeAll(keepingCapacity: true)
        completedCommandCount = 0
        completedBatchCount = 0
        completedPixelCount = 0
        commandNanoseconds.removeAll(keepingCapacity: true)
        gpuWaitNanoseconds.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private static func append(_ value: UInt64, to samples: inout [UInt64]) {
        samples.append(value)
        if samples.count > 120 {
            samples.removeFirst(samples.count - 120)
        }
    }

    private static func percentileMilliseconds(_ samples: [UInt64]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(
            sorted.count - 1,
            Int((Double(sorted.count - 1) * 0.95).rounded(.up))
        )
        return Double(sorted[index]) / 1_000_000
    }

    private func dispatchGeometry(
        width: Int,
        height: Int
    ) -> (threadgroups: MTLSize, threadsPerThreadgroup: MTLSize)? {
        guard width > 0, height > 0 else { return nil }

        let deviceLimit = device.maxThreadsPerThreadgroup
        let maxTotal = pipeline.maxTotalThreadsPerThreadgroup
        guard deviceLimit.width > 0, deviceLimit.height > 0, maxTotal > 0 else {
            return nil
        }

        let threadWidth = min(
            width,
            deviceLimit.width,
            maxTotal,
            max(1, pipeline.threadExecutionWidth)
        )
        guard threadWidth > 0 else { return nil }
        let threadHeight = min(
            height,
            deviceLimit.height,
            16,
            maxTotal / threadWidth
        )
        guard threadHeight > 0 else { return nil }

        return (
            threadgroups: MTLSize(
                width: (width - 1) / threadWidth + 1,
                height: (height - 1) / threadHeight + 1,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
    }

    private func buffer(for surface: PineconeGraphicsSurface) -> MTLBuffer? {
        guard let baseAddress = surface.bytes.baseAddress,
              surface.bytes.count > 0,
              surface.allocationByteCount >= surface.bytes.count else {
            return nil
        }
#if targetEnvironment(simulator)
        let address = UInt(bitPattern: baseAddress)
        if let cached = cachedBuffers[surface.resourceID],
           cached.address == address,
           cached.allocationByteCount == surface.allocationByteCount {
            return cached.buffer
        }
        guard let buffer = device.makeBuffer(
            length: surface.allocationByteCount,
            options: .storageModeShared
        ) else {
            return nil
        }
        cachedBuffers[surface.resourceID] = CachedBuffer(
            address: address,
            allocationByteCount: surface.allocationByteCount,
            buffer: buffer
        )
        return buffer
#else
        let address = UInt(bitPattern: baseAddress)
        if let cached = cachedBuffers[surface.resourceID],
           cached.address == address,
           cached.allocationByteCount == surface.allocationByteCount {
            return cached.buffer
        }
        guard let buffer = device.makeBuffer(
            bytesNoCopy: baseAddress,
            length: surface.allocationByteCount,
            options: .storageModeShared,
            deallocator: nil
        ) else {
            return nil
        }
        cachedBuffers[surface.resourceID] = CachedBuffer(
            address: address,
            allocationByteCount: surface.allocationByteCount,
            buffer: buffer
        )
        return buffer
#endif
    }

#if targetEnvironment(simulator)
    private func synchronize(
        _ surface: PineconeGraphicsSurface,
        to buffer: MTLBuffer,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        guard let source = surface.bytes.baseAddress else { return }
        for row in 0..<height {
            let offset = (y + row) * surface.stride + x * 4
            memcpy(
                buffer.contents().advanced(by: offset),
                source.advanced(by: offset),
                width * 4
            )
        }
    }
#endif

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PineconeCompositeParameters {
        uint operation;
        uint sourceStridePixels;
        uint destinationStridePixels;
        uint sourceX;
        uint sourceY;
        uint sourceWidth;
        uint sourceHeight;
        uint destinationX;
        uint destinationY;
        uint width;
        uint height;
        uint color;
        uint sourceOpaque;
        uint destinationOpaque;
        uint bilinearFiltering;
        uint maskStridePixels;
        uint maskAlpha;
        uint hasImageMask;
        uint sourceIsSolid;
        uint componentAlphaMask;
        uint maskIsPackedA8;
    };

    kernel void pineconeComposite2D(
        device const uchar4 *source [[buffer(0)]],
        device uchar4 *destination [[buffer(1)]],
        device const uchar4 *mask [[buffer(2)]],
        constant PineconeCompositeParameters &parameters [[buffer(3)]],
        uint2 position [[thread_position_in_grid]]
    ) {
        if (position.x >= parameters.width || position.y >= parameters.height) {
            return;
        }
        const uint destinationIndex =
            (parameters.destinationY + position.y) * parameters.destinationStridePixels +
            parameters.destinationX + position.x;
        uchar4 sourcePixel;
        if (parameters.operation == 0u) {
            destination[destinationIndex] = uchar4(0u);
            return;
        }
        if (parameters.operation == 2u) {
            return;
        }
        if (parameters.sourceIsSolid != 0u) {
            sourcePixel = uchar4(
                parameters.color & 0xffu,
                (parameters.color >> 8u) & 0xffu,
                (parameters.color >> 16u) & 0xffu,
                (parameters.color >> 24u) & 0xffu
            );
        } else {
            if (parameters.bilinearFiltering == 0u) {
                const ulong scaledX =
                    (ulong(position.x) * ulong(parameters.sourceWidth)) /
                    ulong(parameters.width);
                const ulong scaledY =
                    (ulong(position.y) * ulong(parameters.sourceHeight)) /
                    ulong(parameters.height);
                const uint sourceIndex =
                    (parameters.sourceY + uint(scaledY)) * parameters.sourceStridePixels +
                    parameters.sourceX + uint(scaledX);
                sourcePixel = source[sourceIndex];
            } else {
                const float2 sourcePosition = float2(
                    (float(position.x) + 0.5f) * float(parameters.sourceWidth) /
                        float(parameters.width) - 0.5f,
                    (float(position.y) + 0.5f) * float(parameters.sourceHeight) /
                        float(parameters.height) - 0.5f
                );
                const float2 clampedPosition = clamp(
                    sourcePosition,
                    float2(0.0f),
                    float2(parameters.sourceWidth - 1u, parameters.sourceHeight - 1u)
                );
                const uint2 lower = uint2(floor(clampedPosition));
                const uint2 upper = min(
                    lower + uint2(1u),
                    uint2(parameters.sourceWidth - 1u, parameters.sourceHeight - 1u)
                );
                const float2 fraction = clampedPosition - float2(lower);
                const uint baseX = parameters.sourceX;
                const uint baseY = parameters.sourceY;
                const float4 topLeft = float4(source[
                    (baseY + lower.y) * parameters.sourceStridePixels + baseX + lower.x]);
                const float4 topRight = float4(source[
                    (baseY + lower.y) * parameters.sourceStridePixels + baseX + upper.x]);
                const float4 bottomLeft = float4(source[
                    (baseY + upper.y) * parameters.sourceStridePixels + baseX + lower.x]);
                const float4 bottomRight = float4(source[
                    (baseY + upper.y) * parameters.sourceStridePixels + baseX + upper.x]);
                sourcePixel = uchar4(clamp(rint(mix(
                    mix(topLeft, topRight, fraction.x),
                    mix(bottomLeft, bottomRight, fraction.x),
                    fraction.y
                )), 0.0f, 255.0f));
            }
            if (parameters.sourceOpaque != 0u) {
                sourcePixel.w = 255u;
            }
        }
        uint4 coverage = uint4(parameters.maskAlpha);
        if (parameters.hasImageMask != 0u) {
            if (parameters.maskIsPackedA8 != 0u) {
                device const uchar *packedMask =
                    reinterpret_cast<device const uchar *>(mask);
                coverage = uint4(uint(packedMask[
                    position.y * parameters.maskStridePixels * 4u + position.x]));
            } else {
                const uchar4 maskPixel =
                    mask[position.y * parameters.maskStridePixels + position.x];
                coverage = parameters.componentAlphaMask != 0u
                    ? uint4(maskPixel) : uint4(uint(maskPixel.w));
            }
        }
        uint4 masked = uint4(sourcePixel) * coverage;
        masked = masked + 128u + ((masked + 128u) >> 8u);
        const uchar4 maskedSource = uchar4(masked >> 8u);
        if (parameters.operation == 1u) {
            sourcePixel = maskedSource;
            if (parameters.destinationOpaque != 0u) {
                sourcePixel.w = 255u;
            }
            destination[destinationIndex] = sourcePixel;
            return;
        }

        uchar4 destinationPixel = destination[destinationIndex];
        if (parameters.destinationOpaque != 0u) {
            destinationPixel.w = 255u;
        }
        uchar4 output;
        if (parameters.operation == 12u) {
            output = uchar4(min(
                uint4(255u), uint4(maskedSource) + uint4(destinationPixel)));
        } else {
            uint4 coveredAlpha = uint4(uint(sourcePixel.w)) * coverage;
            coveredAlpha = coveredAlpha + 128u + ((coveredAlpha + 128u) >> 8u);
            const uint4 inverseAlpha = uint4(255u) - (coveredAlpha >> 8u);
            uint4 product = uint4(destinationPixel) * inverseAlpha;
            product = product + 128u + ((product + 128u) >> 8u);
            output = uchar4(min(uint4(255u),
                uint4(maskedSource) + (product >> 8u)));
        }
        if (parameters.destinationOpaque != 0u) {
            output.w = 255u;
        }
        destination[destinationIndex] = output;
    }
    """
}
