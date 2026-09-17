import ARM64VizCore
import Foundation
import Metal

final class PineconeMetalGraphicsAccelerator: PineconeGraphicsAccelerator {
#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
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
        var sourceIsPackedA8: UInt32
        var destinationIsPackedA8: UInt32
    }

    private struct CachedBuffer {
        let address: UInt
        let allocationByteCount: Int
        let buffer: MTLBuffer
    }

    private struct DirtyDestination {
        var rectangles: [PineconeGraphicsRectangle]
        let surface: PineconeGraphicsSurface
        let packedA8: Bool
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let minimumMetalPixelCount: Int
    private let enabledOperatorMask: UInt64
    private let enabledCapabilities: PineconeGraphicsCapabilities
    private let cacheLock = NSLock()
    private let pendingWrites = DispatchGroup()
    private let diagnosticsLock = NSLock()
    private var cachedBuffers: [UInt32: CachedBuffer] = [:]
    private var completedCommandCount: UInt64 = 0
    private var completedBatchCount: UInt64 = 0
    private var completedPixelCount: UInt64 = 0
    private var commandNanoseconds: [UInt64] = []
    private var gpuWaitNanoseconds: [UInt64] = []
    private var initializationNanoseconds: UInt64 = 0
    private var prewarmBufferCreationNanoseconds: UInt64 = 0
    private var prewarmEncodingNanoseconds: UInt64 = 0
    private var prewarmCompletionNanoseconds: UInt64 = 0
    private var prewarmSucceeded = false
    private var firstGuestSubmissionClaimed = false
    private var firstGuestPreparationNanoseconds: UInt64 = 0
    private var firstGuestCompletionNanoseconds: UInt64 = 0

    var diagnosticsSummary: String {
        diagnosticsLock.lock()
        let commands = completedCommandCount
        let batches = completedBatchCount
        let pixels = completedPixelCount
        let commandP95 = Self.percentileMilliseconds(commandNanoseconds)
        let waitP95 = Self.percentileMilliseconds(gpuWaitNanoseconds)
        diagnosticsLock.unlock()
        guard commands > 0 else { return "" }
        return "metal=\(commands)/b\(batches):\(pixels) t95=" +
            "\(String(format: "%.2f", commandP95))/" +
            "\(String(format: "%.2f", waitP95))ms"
    }

    var performanceCounters: [String: Double] {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return [
            "completedCommands": Double(completedCommandCount),
            "completedBatches": Double(completedBatchCount),
            "completedPixels": Double(completedPixelCount),
            "commandP95Milliseconds": Self.percentileMilliseconds(commandNanoseconds),
            "synchronousWaitP95Milliseconds": Self.percentileMilliseconds(
                gpuWaitNanoseconds
            ),
            "initializationMilliseconds": Self.milliseconds(initializationNanoseconds),
            "prewarmBufferCreationMilliseconds": Self.milliseconds(
                prewarmBufferCreationNanoseconds
            ),
            "prewarmEncodingMilliseconds": Self.milliseconds(prewarmEncodingNanoseconds),
            "prewarmCompletionMilliseconds": Self.milliseconds(
                prewarmCompletionNanoseconds
            ),
            "prewarmSucceeded": prewarmSucceeded ? 1 : 0,
            "firstGuestPreparationMilliseconds": Self.milliseconds(
                firstGuestPreparationNanoseconds
            ),
            "firstGuestCompletionMilliseconds": Self.milliseconds(
                firstGuestCompletionNanoseconds
            ),
        ]
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        let initializationStarted = DispatchTime.now().uptimeNanoseconds
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
        self.enabledOperatorMask = Self.environmentUInt64(
            "PINECONE_METAL_OPERATOR_MASK",
            default: PineconeGraphicsProtocol.exactOperatorMask
        ) & PineconeGraphicsProtocol.exactOperatorMask
        var capabilities = PineconeGraphicsCapabilities.all
        let environment = ProcessInfo.processInfo.environment
        if environment["PINECONE_METAL_COMPONENT_ALPHA"] == "0" {
            capabilities.remove(.componentAlphaMask)
        }
        if environment["PINECONE_METAL_PACKED_A8_SOURCE"] == "0" {
            capabilities.remove(.packedA8Source)
        }
        if environment["PINECONE_METAL_PACKED_A8_MASK"] == "0" {
            capabilities.remove(.packedA8Mask)
        }
        if environment["PINECONE_METAL_PACKED_A8_DESTINATION"] == "0" {
            capabilities.remove(.packedA8Destination)
        }
        if environment["PINECONE_METAL_BILINEAR"] == "0" {
            capabilities.remove(.bilinearScaling)
        }
        if environment["PINECONE_METAL_ORDERED_BATCH"] == "0" {
            capabilities.remove(.orderedBatch)
        }
        self.enabledCapabilities = capabilities
        initializationNanoseconds = DispatchTime.now().uptimeNanoseconds &-
            initializationStarted
        prewarm()
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
        executeBatch(workItems, completion: nil)
    }

    func executeBatchAsync(
        _ workItems: [PineconeGraphicsWorkItem],
        completion: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        executeBatch(workItems, completion: completion)
    }

    func acceptsBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool {
        guard !workItems.isEmpty,
              workItems.count <= PineconeGraphicsProtocol.maximumBatchCommandCount,
              workItems.count == 1 || enabledCapabilities.contains(.orderedBatch) else {
            return false
        }
        var pixels = 0
        var packedFormats: [UInt32: Bool] = [:]
        func acceptFormat(_ surface: PineconeGraphicsSurface?, packed: Bool) -> Bool {
            guard let surface else { return true }
            if let previous = packedFormats[surface.resourceID], previous != packed { return false }
            packedFormats[surface.resourceID] = packed
            return true
        }
        for item in workItems {
            let command = item.command
            let rectangle = command.destinationRectangle
            let count = rectangle.width.multipliedReportingOverflow(by: rectangle.height)
            guard rectangle.width > 0, rectangle.height > 0, !count.overflow,
                  pixels <= Int.max - count.partialValue,
                  enabledOperatorMask & (1 << UInt64(command.blendOperator.rawValue)) != 0,
                  !command.componentAlphaMask || enabledCapabilities.contains(.componentAlphaMask),
                  !command.sourceIsPackedA8 || enabledCapabilities.contains(.packedA8Source),
                  !command.maskIsPackedA8 || enabledCapabilities.contains(.packedA8Mask),
                  !command.destinationIsPackedA8 || enabledCapabilities.contains(.packedA8Destination),
                  !command.usesBilinearFiltering || enabledCapabilities.contains(.bilinearScaling),
                  acceptFormat(item.destination, packed: command.destinationIsPackedA8),
                  acceptFormat(command.sourceIsSolid ? nil : item.source, packed: command.sourceIsPackedA8),
                  acceptFormat(item.mask, packed: command.maskIsPackedA8) else {
                return false
            }
            pixels += count.partialValue
        }
        return pixels >= minimumMetalPixelCount
    }

    private func executeBatch(
        _ workItems: [PineconeGraphicsWorkItem],
        completion: (@Sendable (Bool) -> Void)?
    ) -> Bool {
        guard !workItems.isEmpty,
              workItems.count <= PineconeGraphicsProtocol.maximumBatchCommandCount else {
            return workItems.isEmpty
        }
        let commandStarted = DispatchTime.now().uptimeNanoseconds
        guard acceptsBatch(workItems) else { return false }

        var totalPixelCount = 0
        if workItems.count > 1 &&
            !enabledCapabilities.contains(.orderedBatch) {
            return false
        }
        for item in workItems {
            let command = item.command
            let operatorBit = UInt64(1) << UInt64(command.blendOperator.rawValue)
            guard enabledOperatorMask & operatorBit != 0,
                  (!command.componentAlphaMask ||
                    enabledCapabilities.contains(.componentAlphaMask)),
                  (!command.sourceIsPackedA8 ||
                    enabledCapabilities.contains(.packedA8Source)),
                  (!command.maskIsPackedA8 ||
                    enabledCapabilities.contains(.packedA8Mask)),
                  (!command.destinationIsPackedA8 ||
                    enabledCapabilities.contains(.packedA8Destination)),
                  (!command.usesBilinearFiltering ||
                    enabledCapabilities.contains(.bilinearScaling)) else {
                return false
            }
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
        guard totalPixelCount >= minimumMetalPixelCount else {
            return false
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return false
        }
        let isFirstGuestSubmission = claimFirstGuestSubmission()

        var gpuWrittenResources = Set<UInt32>()
#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
        var dirtyDestinations: [UInt32: DirtyDestination] = [:]
        var synchronizedInputs: [UInt32: [PineconeGraphicsRectangle]] = [:]
#endif

        encoder.setComputePipelineState(pipeline)
        for (workIndex, item) in workItems.enumerated() {
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

#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
            if let source, !command.sourceIsSolid {
                synchronizeMissing(
                    source, to: sourceBuffer,
                    x: command.sourceX, y: command.sourceY,
                    width: command.sourceWidth, height: command.sourceHeight,
                    packedA8: command.sourceIsPackedA8,
                    synchronized: &synchronizedInputs
                )
            }
            if command.blendOperator != .clear &&
                command.blendOperator != .source {
                synchronizeMissing(
                    destination, to: destinationBuffer,
                    x: rectangle.x, y: rectangle.y,
                    width: rectangle.width, height: rectangle.height,
                    packedA8: command.destinationIsPackedA8,
                    synchronized: &synchronizedInputs
                )
            }
            if let mask {
                synchronizeMissing(
                    mask, to: maskBuffer,
                    x: 0, y: 0,
                    width: rectangle.width, height: rectangle.height,
                    packedA8: command.maskIsPackedA8,
                    synchronized: &synchronizedInputs
                )
            }
#endif

            let hasGPUDependency = gpuWrittenResources.contains(destination.resourceID) ||
                source.map { gpuWrittenResources.contains($0.resourceID) } == true ||
                mask.map { gpuWrittenResources.contains($0.resourceID) } == true
            if workIndex != 0 && hasGPUDependency {
                // Independent dispatches need no global visibility barrier.
                // Preserve Pixman's ordering only when this command consumes
                // or overwrites a resource written earlier in the frame.
                encoder.memoryBarrier(scope: .buffers)
            }

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
                destinationOpaque: destination.pixelFormat == .bgrx8 &&
                    !command.destinationIsPackedA8 ? 1 : 0,
                bilinearFiltering: command.usesBilinearFiltering ? 1 : 0,
                maskStridePixels: UInt32(mask?.stride ?? destination.stride) / 4,
                maskAlpha: UInt32(command.maskAlpha ?? UInt8.max),
                hasImageMask: mask == nil ? 0 : 1,
                sourceIsSolid: command.sourceIsSolid ? 1 : 0,
                componentAlphaMask: command.componentAlphaMask ? 1 : 0,
                maskIsPackedA8: command.maskIsPackedA8 ? 1 : 0,
                sourceIsPackedA8: command.sourceIsPackedA8 ? 1 : 0,
                destinationIsPackedA8: command.destinationIsPackedA8 ? 1 : 0
            )
            encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
            encoder.setBuffer(destinationBuffer, offset: 0, index: 1)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            encoder.setBytes(
                &parameters,
                length: MemoryLayout<Parameters>.stride,
                index: 3
            )
            // dispatchThreads requires non-uniform threadgroup support. Phosh
            // emits arbitrary damage rectangles, so round up and let the
            // shader's bounds check discard edge threads.
            encoder.dispatchThreadgroups(
                geometry.threadgroups,
                threadsPerThreadgroup: geometry.threadsPerThreadgroup
            )
            gpuWrittenResources.insert(destination.resourceID)
#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
            // A GPU write initializes precisely these pixels. Later commands may
            // still need guest pixels from other parts of the same resource.
            var initialized = synchronizedInputs[destination.resourceID] ?? []
            Self.appendDamage(rectangle, to: &initialized)
            synchronizedInputs[destination.resourceID] = initialized
            if var existing = dirtyDestinations[destination.resourceID] {
                guard existing.packedA8 == command.destinationIsPackedA8 else {
                    encoder.endEncoding()
                    return false
                }
                Self.appendDamage(rectangle, to: &existing.rectangles)
                dirtyDestinations[destination.resourceID] = existing
            } else {
                dirtyDestinations[destination.resourceID] = DirtyDestination(
                    rectangles: [rectangle],
                    surface: destination,
                    packedA8: command.destinationIsPackedA8
                )
            }
#endif
        }
        encoder.endEncoding()
        if let completion {
            pendingWrites.enter()
            let commandCount = workItems.count
            commandBuffer.addCompletedHandler { [self] completedBuffer in
                let completedAt = DispatchTime.now().uptimeNanoseconds
                var succeeded = completedBuffer.status == .completed
#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
                if succeeded {
                    succeeded = synchronizeDestinationsToGuest(
                        dirtyDestinations
                    )
                }
#endif
                diagnosticsLock.lock()
                Self.append(completedAt &- commandStarted, to: &commandNanoseconds)
                completedCommandCount &+= UInt64(commandCount)
                completedBatchCount &+= 1
                completedPixelCount &+= UInt64(totalPixelCount)
                if isFirstGuestSubmission {
                    firstGuestCompletionNanoseconds = completedAt &- commandStarted
                }
                diagnosticsLock.unlock()
                // Reset may hold the device lock while draining GPU writes.
                // Leave before its callback tries to acquire that same lock.
                pendingWrites.leave()
                completion(succeeded)
            }
            if isFirstGuestSubmission {
                recordFirstGuestPreparation(
                    DispatchTime.now().uptimeNanoseconds &- commandStarted
                )
            }
            commandBuffer.commit()
            return true
        }
        if isFirstGuestSubmission {
            recordFirstGuestPreparation(
                DispatchTime.now().uptimeNanoseconds &- commandStarted
            )
        }
        commandBuffer.commit()
        let waitStarted = DispatchTime.now().uptimeNanoseconds
        commandBuffer.waitUntilCompleted()
        let completedAt = DispatchTime.now().uptimeNanoseconds
        diagnosticsLock.lock()
        Self.append(completedAt &- commandStarted, to: &commandNanoseconds)
        Self.append(completedAt &- waitStarted, to: &gpuWaitNanoseconds)
        completedCommandCount &+= UInt64(workItems.count)
        completedBatchCount &+= 1
        completedPixelCount &+= UInt64(totalPixelCount)
        if isFirstGuestSubmission {
            firstGuestCompletionNanoseconds = completedAt &- commandStarted
        }
        diagnosticsLock.unlock()
        guard commandBuffer.status == .completed else { return false }

#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
        guard synchronizeDestinationsToGuest(
            dirtyDestinations
        ) else { return false }
#endif
        return true
    }

    func discardSurface(resourceID: UInt32) {
        cacheLock.lock()
        cachedBuffers.removeValue(forKey: resourceID)
        cacheLock.unlock()
    }

    func reset() {
        pendingWrites.wait()
        cacheLock.lock()
        cachedBuffers.removeAll(keepingCapacity: true)
        cacheLock.unlock()
        diagnosticsLock.lock()
        completedCommandCount = 0
        completedBatchCount = 0
        completedPixelCount = 0
        commandNanoseconds.removeAll(keepingCapacity: true)
        gpuWaitNanoseconds.removeAll(keepingCapacity: true)
        diagnosticsLock.unlock()
    }

    private static func append(_ value: UInt64, to samples: inout [UInt64]) {
        samples.append(value)
        if samples.count > 120 {
            samples.removeFirst(samples.count - 120)
        }
    }

    private static func environmentUInt64(
        _ name: String,
        default defaultValue: UInt64
    ) -> UInt64 {
        guard let value = ProcessInfo.processInfo.environment[name] else {
            return defaultValue
        }
        let text = value.lowercased()
        if text.hasPrefix("0x") {
            return UInt64(text.dropFirst(2), radix: 16) ?? defaultValue
        }
        return UInt64(text) ?? defaultValue
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

    private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }

    private func claimFirstGuestSubmission() -> Bool {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        guard !firstGuestSubmissionClaimed else { return false }
        firstGuestSubmissionClaimed = true
        return true
    }

    private func recordFirstGuestPreparation(_ nanoseconds: UInt64) {
        diagnosticsLock.lock()
        firstGuestPreparationNanoseconds = nanoseconds
        diagnosticsLock.unlock()
    }

    /// Force Metal's lazy device, queue, pipeline, and first-dispatch work to
    /// complete before the guest can submit a user-visible Phosh frame.
    private func prewarm() {
        guard ProcessInfo.processInfo.environment["PINECONE_METAL_PREWARM"] != "0" else {
            return
        }

        let bufferCreationStarted = DispatchTime.now().uptimeNanoseconds
        guard let source = device.makeBuffer(length: 4, options: .storageModeShared),
              let destination = device.makeBuffer(length: 4, options: .storageModeShared),
              let mask = device.makeBuffer(length: 4, options: .storageModeShared) else {
            prewarmBufferCreationNanoseconds = DispatchTime.now().uptimeNanoseconds &-
                bufferCreationStarted
            return
        }
        prewarmBufferCreationNanoseconds = DispatchTime.now().uptimeNanoseconds &-
            bufferCreationStarted

        var parameters = Parameters(
            operation: UInt32(PineconeGraphicsBlendOperator.clear.rawValue),
            sourceStridePixels: 1,
            destinationStridePixels: 1,
            sourceX: 0,
            sourceY: 0,
            sourceWidth: 1,
            sourceHeight: 1,
            destinationX: 0,
            destinationY: 0,
            width: 1,
            height: 1,
            color: 0,
            sourceOpaque: 0,
            destinationOpaque: 0,
            bilinearFiltering: 0,
            maskStridePixels: 1,
            maskAlpha: UInt32(UInt8.max),
            hasImageMask: 0,
            sourceIsSolid: 1,
            componentAlphaMask: 0,
            maskIsPackedA8: 0,
            sourceIsPackedA8: 0,
            destinationIsPackedA8: 0
        )
        let encodingStarted = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            prewarmEncodingNanoseconds = DispatchTime.now().uptimeNanoseconds &-
                encodingStarted
            return
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setBuffer(mask, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        encoder.endEncoding()
        prewarmEncodingNanoseconds = DispatchTime.now().uptimeNanoseconds &-
            encodingStarted

        let completionStarted = DispatchTime.now().uptimeNanoseconds
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        prewarmCompletionNanoseconds = DispatchTime.now().uptimeNanoseconds &-
            completionStarted
        prewarmSucceeded = commandBuffer.status == .completed
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
#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
        let address = UInt(bitPattern: baseAddress)
        cacheLock.lock()
        defer { cacheLock.unlock() }
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
        cacheLock.lock()
        defer { cacheLock.unlock() }
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

#if targetEnvironment(simulator) || PINECONE_TEST_SIMULATOR_COPY
    /// Simulator Metal buffers cannot alias the package's guest-memory
    /// allocation. Copy only GPU-written rectangles back before completing the
    /// virtio fence; physical devices use bytesNoCopy and skip this path.
    private func synchronizeDestinationsToGuest(
        _ dirtyDestinations: [UInt32: DirtyDestination]
    ) -> Bool {
        for (resourceID, dirty) in dirtyDestinations {
            let destination = dirty.surface
            guard destination.resourceID == resourceID,
                  let destinationBuffer = buffer(for: destination),
                  let destinationBytes = destination.bytes.baseAddress else {
                return false
            }
            let bytesPerPixel = dirty.packedA8 ? 1 : 4
            for rectangle in dirty.rectangles {
                let rowBytes = rectangle.width * bytesPerPixel
                if rectangle.x == 0 && rowBytes == destination.stride {
                    let offset = rectangle.y * destination.stride
                    memcpy(
                        destinationBytes.advanced(by: offset),
                        destinationBuffer.contents().advanced(by: offset),
                        rectangle.height * destination.stride
                    )
                    continue
                }
                for row in 0..<rectangle.height {
                    let offset = (rectangle.y + row) * destination.stride +
                        rectangle.x * bytesPerPixel
                    memcpy(
                        destinationBytes.advanced(by: offset),
                        destinationBuffer.contents().advanced(by: offset),
                        rowBytes
                    )
                }
            }
        }
        return true
    }

    private func synchronizeMissing(
        _ surface: PineconeGraphicsSurface,
        to buffer: MTLBuffer,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        packedA8: Bool,
        synchronized: inout [UInt32: [PineconeGraphicsRectangle]]
    ) {
        let requested = PineconeGraphicsRectangle(x: x, y: y, width: width, height: height)
        let existing = synchronized[surface.resourceID] ?? []
        let missing = existing.reduce([requested]) { rectangles, covered in
            rectangles.flatMap { Self.subtract($0, covered) }
        }
        for rectangle in missing {
            synchronize(
                surface,
                to: buffer,
                x: rectangle.x,
                y: rectangle.y,
                width: rectangle.width,
                height: rectangle.height,
                packedA8: packedA8
            )
        }
        var updated = existing
        Self.appendDamage(requested, to: &updated)
        synchronized[surface.resourceID] = updated
    }

    private static func appendDamage(
        _ rectangle: PineconeGraphicsRectangle,
        to rectangles: inout [PineconeGraphicsRectangle]
    ) {
        var candidate = rectangle
        var index = 0
        while index < rectangles.count {
            let existing = rectangles[index]
            let horizontal = existing.y == candidate.y &&
                existing.height == candidate.height &&
                existing.x <= candidate.x + candidate.width &&
                candidate.x <= existing.x + existing.width
            let vertical = existing.x == candidate.x &&
                existing.width == candidate.width &&
                existing.y <= candidate.y + candidate.height &&
                candidate.y <= existing.y + existing.height
            // Only merge when the union is itself a rectangle. Bounding an
            // arbitrary overlap invents damage and copies uninitialized pixels.
            if horizontal || vertical {
                let left = min(existing.x, candidate.x)
                let top = min(existing.y, candidate.y)
                let right = max(existing.x + existing.width, candidate.x + candidate.width)
                let bottom = max(existing.y + existing.height, candidate.y + candidate.height)
                candidate = PineconeGraphicsRectangle(
                    x: left, y: top, width: right - left, height: bottom - top
                )
                rectangles.remove(at: index)
                index = 0
            } else {
                index += 1
            }
        }
        rectangles.append(candidate)
    }

    private static func subtract(
        _ rectangle: PineconeGraphicsRectangle,
        _ covered: PineconeGraphicsRectangle
    ) -> [PineconeGraphicsRectangle] {
        let left = max(rectangle.x, covered.x)
        let top = max(rectangle.y, covered.y)
        let right = min(rectangle.x + rectangle.width, covered.x + covered.width)
        let bottom = min(rectangle.y + rectangle.height, covered.y + covered.height)
        guard left < right, top < bottom else { return [rectangle] }
        var output: [PineconeGraphicsRectangle] = []
        if rectangle.y < top {
            output.append(PineconeGraphicsRectangle(
                x: rectangle.x, y: rectangle.y,
                width: rectangle.width, height: top - rectangle.y
            ))
        }
        if bottom < rectangle.y + rectangle.height {
            output.append(PineconeGraphicsRectangle(
                x: rectangle.x, y: bottom,
                width: rectangle.width,
                height: rectangle.y + rectangle.height - bottom
            ))
        }
        if rectangle.x < left {
            output.append(PineconeGraphicsRectangle(
                x: rectangle.x, y: top,
                width: left - rectangle.x, height: bottom - top
            ))
        }
        if right < rectangle.x + rectangle.width {
            output.append(PineconeGraphicsRectangle(
                x: right, y: top,
                width: rectangle.x + rectangle.width - right,
                height: bottom - top
            ))
        }
        return output
    }

    private func synchronize(
        _ surface: PineconeGraphicsSurface,
        to buffer: MTLBuffer,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        packedA8: Bool
    ) {
        guard let source = surface.bytes.baseAddress else { return }
        let bytesPerPixel = packedA8 ? 1 : 4
        let rowBytes = width * bytesPerPixel
        if x == 0 && rowBytes == surface.stride {
            let offset = y * surface.stride
            memcpy(
                buffer.contents().advanced(by: offset),
                source.advanced(by: offset),
                height * surface.stride
            )
            return
        }
        for row in 0..<height {
            let offset = (y + row) * surface.stride + x * bytesPerPixel
            memcpy(
                buffer.contents().advanced(by: offset),
                source.advanced(by: offset),
                rowBytes
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
        uint sourceIsPackedA8;
        uint destinationIsPackedA8;
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
        const uint destinationByteIndex =
            (parameters.destinationY + position.y) *
                parameters.destinationStridePixels * 4u +
            parameters.destinationX + position.x;
        device uchar *packedDestination =
            reinterpret_cast<device uchar *>(destination);
        uchar4 sourcePixel;
        if (parameters.operation == 0u) {
            if (parameters.destinationIsPackedA8 != 0u) {
                packedDestination[destinationByteIndex] = 0u;
            } else {
                destination[destinationIndex] = uchar4(0u);
            }
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
                if (parameters.sourceIsPackedA8 != 0u) {
                    device const uchar *packedSource =
                        reinterpret_cast<device const uchar *>(source);
                    const uint sourceByteIndex =
                        (parameters.sourceY + uint(scaledY)) *
                            parameters.sourceStridePixels * 4u +
                        parameters.sourceX + uint(scaledX);
                    sourcePixel = uchar4(
                        0u, 0u, 0u, packedSource[sourceByteIndex]);
                } else {
                    sourcePixel = source[sourceIndex];
                }
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
            if (parameters.destinationIsPackedA8 != 0u) {
                packedDestination[destinationByteIndex] = sourcePixel.w;
            } else {
                destination[destinationIndex] = sourcePixel;
            }
            return;
        }

        uchar4 destinationPixel = parameters.destinationIsPackedA8 != 0u
            ? uchar4(0u, 0u, 0u, packedDestination[destinationByteIndex])
            : destination[destinationIndex];
        if (parameters.destinationOpaque != 0u) {
            destinationPixel.w = 255u;
        }
        uchar4 output;
        if (parameters.operation == 13u) {
            const float4 sourceValue = float4(sourcePixel) * (1.0f / 255.0f);
            const float4 coverageValue = float4(coverage) * (1.0f / 255.0f);
            const float4 maskedValue = sourceValue * coverageValue;
            const float4 sourceAlphaValue =
                float4(sourceValue.w) * coverageValue;
            const float destinationAlphaValue =
                float(destinationPixel.w) * (1.0f / 255.0f);
            const float4 sourceFactor = select(
                float4(1.0f),
                clamp(
                    (float4(1.0f) - destinationAlphaValue) /
                        max(sourceAlphaValue, float4(1.0f / 65536.0f)),
                    float4(0.0f), float4(1.0f)),
                sourceAlphaValue > float4(0.0f));
            const float4 result = min(
                float4(1.0f),
                maskedValue * sourceFactor +
                    float4(destinationPixel) * (1.0f / 255.0f));
            output = uchar4(min(uint4(255u), uint4(result * 256.0f)));
        } else if (parameters.operation == 12u) {
            output = uchar4(min(
                uint4(255u), uint4(maskedSource) + uint4(destinationPixel)));
        } else {
            uint4 coveredAlpha = uint4(uint(sourcePixel.w)) * coverage;
            coveredAlpha = coveredAlpha + 128u + ((coveredAlpha + 128u) >> 8u);
            const uint4 sourceAlpha = coveredAlpha >> 8u;
            const uint4 destinationAlpha = uint4(uint(destinationPixel.w));
            uint4 sourceFactor = uint4(255u);
            uint4 destinationFactor = uint4(255u) - sourceAlpha;
            switch (parameters.operation) {
            case 4u:
                sourceFactor = uint4(255u) - destinationAlpha;
                destinationFactor = uint4(255u);
                break;
            case 5u:
                sourceFactor = destinationAlpha;
                destinationFactor = uint4(0u);
                break;
            case 6u:
                sourceFactor = uint4(0u);
                destinationFactor = sourceAlpha;
                break;
            case 7u:
                sourceFactor = uint4(255u) - destinationAlpha;
                destinationFactor = uint4(0u);
                break;
            case 8u:
                sourceFactor = uint4(0u);
                destinationFactor = uint4(255u) - sourceAlpha;
                break;
            case 9u:
                sourceFactor = destinationAlpha;
                break;
            case 10u:
                sourceFactor = uint4(255u) - destinationAlpha;
                destinationFactor = sourceAlpha;
                break;
            case 11u:
                sourceFactor = uint4(255u) - destinationAlpha;
                break;
            case 13u:
                sourceFactor = min(
                    uint4(255u),
                    ((uint4(255u) - destinationAlpha) * uint4(255u)) /
                        max(sourceAlpha, uint4(1u))
                );
                destinationFactor = uint4(255u);
                break;
            default:
                break;
            }
            uint4 sourceProduct = uint4(maskedSource) * sourceFactor;
            sourceProduct = sourceProduct + 128u +
                ((sourceProduct + 128u) >> 8u);
            uint4 destinationProduct =
                uint4(destinationPixel) * destinationFactor;
            destinationProduct = destinationProduct + 128u +
                ((destinationProduct + 128u) >> 8u);
            output = uchar4(min(
                uint4(255u),
                (sourceProduct >> 8u) + (destinationProduct >> 8u)
            ));
        }
        if (parameters.destinationOpaque != 0u) {
            output.w = 255u;
        }
        if (parameters.destinationIsPackedA8 != 0u) {
            packedDestination[destinationByteIndex] = output.w;
        } else {
            destination[destinationIndex] = output;
        }
    }
    """
}
