import Foundation
import XCTest
@testable import ARM64VizCore

final class GPUCommandConcurrencyTests: XCTestCase {
    private let size: UInt32 = 64
    private let base: GuestAddress = 0x4000_0000

    func testMetadataAndFrameReadsProgressDuringBulkCommandPhases() throws {
        for phase: VirtIOGPUDevice.PixelWorkPhase in [.transfer, .flush, .prepare, .synchronize, .native, .finish] {
            let pause = PixelWorkPause()
            let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size), pixelWorkObserver: { pause.observe($0) })
            let memory = PhysicalMemory(base: base, size: 0x10_0000)
            try create(1, gpu: gpu, memory: memory, fragmented: true)
            publish(1, gpu: gpu, memory: memory)
            let original = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))
            let held = try XCTUnwrap(gpu.frameLease(afterGeneration: nil))
            try writePixels(1, value: 0x42, memory: memory, fragmented: true)
            let request: [UInt8]
            switch phase {
            case .transfer: request = transfer(1)
            case .flush:
                assertOK(gpu.process(request: transfer(1), memory: memory))
                request = flush(1)
            default: request = submission(destination: 1)
            }
            pause.arm(phase)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                if phase == .transfer || phase == .flush {
                    self.assertOK(gpu.process(request: request, memory: memory))
                } else {
                    // No accelerator: exercise processDeferred's native path.
                    let result = gpu.processDeferred(request: request, memory: memory) { _ in
                        XCTFail("native fallback must return its response synchronously")
                    }
                    guard case let .completed(response) = result else {
                        XCTFail("expected native completion")
                        done.signal()
                        return
                    }
                    self.assertOK(response)
                }
                done.signal()
            }
            XCTAssertEqual(pause.entered.wait(timeout: .now() + 3), .success, "phase \(phase)")
            assertReadable(gpu, expected: original.pixels, generation: original.generation)
            XCTAssertEqual(bytes(held), original.pixels)
            pause.resume.signal()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(bytes(held), original.pixels)
            if phase == .flush {
                XCTAssertNotEqual(gpu.snapshot(afterGeneration: nil)?.pixels, original.pixels)
            }
        }
    }

    func testResetWaitsForCPUTransferWithoutBlockingPublishedFrameReads() throws {
        let pause = PixelWorkPause()
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size), pixelWorkObserver: { pause.observe($0) })
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        try create(1, gpu: gpu, memory: memory)
        publish(1, gpu: gpu, memory: memory)
        let held = try XCTUnwrap(gpu.frameLease(afterGeneration: nil))
        let oldPixels = bytes(held)
        pause.arm(.transfer)
        let transferred = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            self.assertOK(gpu.process(request: self.transfer(1), memory: memory))
            transferred.signal()
        }
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 3), .success)
        let resetStarted = DispatchSemaphore(value: 0)
        let resetDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            resetStarted.signal()
            gpu.reset()
            resetDone.signal()
        }
        XCTAssertEqual(resetStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(resetDone.wait(timeout: .now() + 0.05), .timedOut)
        assertReadable(gpu, expected: oldPixels, generation: held.metadata.generation)
        pause.resume.signal()
        XCTAssertEqual(transferred.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(resetDone.wait(timeout: .now() + 5), .success)
        XCTAssertNil(gpu.metadata(afterGeneration: nil))
        XCTAssertEqual(type(gpu.process(request: transfer(1), memory: memory)), 0x1203)
        XCTAssertEqual(bytes(held), oldPixels)
        try create(1, gpu: gpu, memory: memory, value: 0x31)
        publish(1, gpu: gpu, memory: memory)
        XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels.first, 0x31)
        XCTAssertEqual(bytes(held), oldPixels)
    }

    func testUnrefWaitsForDeferredFenceAndRetainsHostStorage() throws {
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size))
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        let accelerator = ControlledGPUAccelerator()
        gpu.setGraphicsAccelerator(accelerator)
        try create(1, gpu: gpu, memory: memory, fragmented: true)
        publish(1, gpu: gpu, memory: memory)
        let held = try XCTUnwrap(gpu.frameLease(afterGeneration: nil))
        let oldPixels = bytes(held)
        let response = GPUResponseBox()
        XCTAssertTrue(gpu.processDeferred(request: submission(destination: 1), memory: memory) {
            response.set($0)
        }.isDeferred)
        let started = DispatchSemaphore(value: 0)
        let unreferenced = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            self.assertOK(gpu.process(request: self.packet(0x0102, [1, 0]), memory: memory))
            unreferenced.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(unreferenced.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertNil(response.value)
        assertReadable(gpu, expected: oldPixels, generation: held.metadata.generation)
        accelerator.completeFirst()
        XCTAssertEqual(unreferenced.wait(timeout: .now() + 5), .success)
        assertOK(try XCTUnwrap(response.value))
        XCTAssertEqual(try memory.readBytes(at: address(1), count: 4), [0x7a, 0x7a, 0x7a, 0x7a])
        XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels, Array(repeating: 0, count: oldPixels.count))
        XCTAssertEqual(bytes(held), oldPixels)
        try create(1, gpu: gpu, memory: memory, value: 0x25)
        publish(1, gpu: gpu, memory: memory)
        XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels.first, 0x25)
    }

    func testResetDrainsDeferredFinishBeforeReusingResources() throws {
        let pause = PixelWorkPause()
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size), pixelWorkObserver: { pause.observe($0) })
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        let accelerator = ControlledGPUAccelerator()
        gpu.setGraphicsAccelerator(accelerator)
        try create(1, gpu: gpu, memory: memory, fragmented: true)
        publish(1, gpu: gpu, memory: memory)
        let held = try XCTUnwrap(gpu.frameLease(afterGeneration: nil))
        let response = GPUResponseBox()
        XCTAssertTrue(gpu.processDeferred(request: submission(destination: 1), memory: memory) {
            response.set($0)
        }.isDeferred)
        pause.arm(.finish)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { accelerator.completeFirst(); finished.signal() }
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 3), .success)
        let resetDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { gpu.reset(); resetDone.signal() }
        XCTAssertEqual(resetDone.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertNil(response.value)
        assertReadable(gpu, expected: bytes(held), generation: held.metadata.generation)
        pause.resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(resetDone.wait(timeout: .now() + 5), .success)
        XCTAssertNil(gpu.metadata(afterGeneration: nil))
        XCTAssertEqual(gpu.performanceCounters()["paravirtualCommands"], 0)
        assertOK(try XCTUnwrap(response.value))
        try create(1, gpu: gpu, memory: memory, value: 0x39)
        publish(1, gpu: gpu, memory: memory)
        XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels.first, 0x39)
    }

    func testTransportResetDrainsTwoSerialAcceleratorCallbacksWithoutDeadlock() throws {
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        let accelerator = ControlledGPUAccelerator()
        let transport = try GPUResetTransport(memory: memory, accelerator: accelerator)
        func createResource(_ id: UInt32) throws {
            let created = try transport.enqueue(packet(0x0101, [id, 1, size, size]))
            try transport.notify()
            XCTAssertEqual(try memory.read32(at: created), 0x1100)
            let backing = address(id)
            let attached = try transport.enqueue(packet(0x0106, [id, 1,
                UInt32(truncatingIfNeeded: backing), UInt32(backing >> 32), size * size * 4, 0]))
            try transport.notify()
            XCTAssertEqual(try memory.read32(at: attached), 0x1100)
        }
        try createResource(1)
        try createResource(2)
        let baseline = try transport.usedCount()
        let firstResponse = try transport.enqueue(submission(destination: 1))
        let secondResponse = try transport.enqueue(submission(destination: 2))
        try transport.notify()
        XCTAssertEqual(accelerator.pendingCount, 2)

        let resetStarted = DispatchSemaphore(value: 0)
        let resetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            resetStarted.signal()
            transport.device.reset()
            resetFinished.signal()
        }
        XCTAssertEqual(resetStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(resetFinished.wait(timeout: .now() + 0.05), .timedOut)

        // Metal does not promise parallel completion-handler delivery. A must
        // return without acquiring reset's transport lock so B can drain too.
        let firstReturned = DispatchSemaphore(value: 0)
        let callbacksReturned = DispatchSemaphore(value: 0)
        let callbackQueue = DispatchQueue(label: "gpu-reset-test.serial-accelerator")
        callbackQueue.async {
            accelerator.completeFirst()
            firstReturned.signal()
            _ = accelerator.completeNextIfPresent()
            callbacksReturned.signal()
        }
        let firstResult = firstReturned.wait(timeout: .now() + 3)
        XCTAssertEqual(firstResult, .success, "A blocked on reset's transport lock, preventing B's fence")
        if firstResult != .success {
            // Rescue a regressed implementation so this test does not leave
            // reset and the serial callback queue permanently blocked.
            _ = accelerator.completeNextIfPresent()
        }
        XCTAssertEqual(resetFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(callbacksReturned.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(try transport.usedCount(), baseline)
        XCTAssertEqual(try memory.read32(at: firstResponse), 0)
        XCTAssertEqual(try memory.read32(at: secondResponse), 0)

        // Old queued callbacks must not retire into the replacement queue.
        try transport.configure()
        try createResource(1)
        let freshBaseline = try transport.usedCount()
        let freshResponse = try transport.enqueue(submission(destination: 1))
        try transport.notify()
        accelerator.completeFirst()
        let freshRetired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? transport.usedCount()) == freshBaseline + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [freshRetired], timeout: 3), .completed)
        XCTAssertEqual(try transport.usedCount(), freshBaseline + 1)
        XCTAssertEqual(try memory.read32(at: freshResponse), 0x1100)

        // An inline callback reenters the recursive transport lock and must
        // publish its used entry before notify returns, without queueing work.
        let inlineAccelerator = ControlledGPUAccelerator(mode: .inlineSuccess)
        transport.device.attachGraphicsAccelerator(inlineAccelerator)
        let inlineResponse = try transport.enqueue(submission(destination: 1))
        try transport.notify()
        XCTAssertEqual(try transport.usedCount(), freshBaseline + 2)
        XCTAssertEqual(try memory.read32(at: inlineResponse), 0x1100)
    }

    func testSharedFragmentedSourceReadsOverlapWithPrivateMirrors() throws {
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size))
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        let accelerator = ControlledGPUAccelerator()
        gpu.setGraphicsAccelerator(accelerator)
        try create(1, gpu: gpu, memory: memory, value: 0x11, fragmented: true)
        try create(2, gpu: gpu, memory: memory)
        try create(3, gpu: gpu, memory: memory)
        XCTAssertTrue(gpu.processDeferred(request: submission(source: 1, destination: 2), memory: memory) {
            self.assertOK($0)
        }.isDeferred)
        let first = try XCTUnwrap(accelerator.firstSource)
        try writePixels(1, value: 0x22, memory: memory, fragmented: true)
        let submitted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertTrue(gpu.processDeferred(request: self.submission(source: 1, destination: 3), memory: memory) {
                self.assertOK($0)
            }.isDeferred)
            submitted.signal()
        }
        let overlapped = submitted.wait(timeout: .now() + 3)
        XCTAssertEqual(overlapped, .success)
        if overlapped == .success {
            XCTAssertEqual(accelerator.pendingCount, 2)
            XCTAssertNotEqual(first.bytes.baseAddress, accelerator.lastSource?.bytes.baseAddress)
            XCTAssertEqual(first.bytes[0], 0x11)
            XCTAssertEqual(accelerator.lastSource?.bytes[0], 0x22)
        }
        accelerator.completeFirst()
        if overlapped != .success { XCTAssertEqual(submitted.wait(timeout: .now() + 3), .success) }
        accelerator.completeFirst()
        XCTAssertEqual(try memory.readBytes(at: address(2), count: 1), [0x11])
        XCTAssertEqual(try memory.readBytes(at: address(3), count: 1), [0x22])
    }

    func testReadWriteHazardsWaitForDeferredFence() throws {
        for hazard in ["RAW", "WAR", "WAW"] {
            let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size))
            let memory = PhysicalMemory(base: base, size: 0x10_0000)
            let accelerator = ControlledGPUAccelerator()
            gpu.setGraphicsAccelerator(accelerator)
            for id: UInt32 in 1...3 { try create(id, gpu: gpu, memory: memory) }
            XCTAssertTrue(gpu.processDeferred(request: submission(source: 1, destination: 2), memory: memory) {
                self.assertOK($0)
            }.isDeferred)
            let next = hazard == "RAW" ? submission(source: 2, destination: 3)
                : submission(destination: hazard == "WAR" ? 1 : 2)
            let started = DispatchSemaphore(value: 0)
            let submitted = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                started.signal()
                XCTAssertTrue(gpu.processDeferred(request: next, memory: memory) { self.assertOK($0) }.isDeferred)
                submitted.signal()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
            XCTAssertEqual(submitted.wait(timeout: .now() + 0.05), .timedOut, hazard)
            XCTAssertEqual(accelerator.pendingCount, 1)
            accelerator.completeFirst()
            XCTAssertEqual(submitted.wait(timeout: .now() + 5), .success)
            accelerator.completeFirst()
        }
    }

    func testInlineCompletionAndAsyncRejectionReleaseReservations() throws {
        for mode: ControlledGPUAccelerator.Mode in [.inlineSuccess, .inlineFailure, .reject] {
            let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size))
            let memory = PhysicalMemory(base: base, size: 0x10_0000)
            let accelerator = ControlledGPUAccelerator(mode: mode)
            gpu.setGraphicsAccelerator(accelerator)
            try create(1, gpu: gpu, memory: memory)
            let response = GPUResponseBox()
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let result = gpu.processDeferred(request: self.submission(destination: 1), memory: memory) { response.set($0) }
                if case let .completed(bytes) = result { response.set(bytes) }
                self.assertOK(gpu.process(request: self.transfer(1), memory: memory))
                gpu.reset()
                finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
            let bytes = try XCTUnwrap(response.value)
            XCTAssertEqual(type(bytes), mode == .inlineFailure ? 0x1200 : 0x1100)
            XCTAssertEqual(Array(bytes[4..<24]), Array(submission(destination: 1)[4..<24]))
        }
    }

    func testFragmentedWriteThenReadBatchRetainsOneOrderedSurface() throws {
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size))
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        let accelerator = ControlledGPUAccelerator()
        gpu.setGraphicsAccelerator(accelerator)
        try create(1, gpu: gpu, memory: memory, fragmented: true)
        try create(2, gpu: gpu, memory: memory)
        let records = [submission(destination: 1), submission(source: 1, destination: 2)]
        let payloadSize = UInt32(PineconeGraphicsProtocol.batchHeaderByteCount +
            records.count * PineconeGraphicsProtocol.batchRecordByteCount)
        var request = packet(0x0207, [payloadSize, 0, PineconeGraphicsProtocol.magic,
            UInt32(PineconeGraphicsProtocol.batchVersion) | (2 << 16),
            UInt32(PineconeGraphicsProtocol.batchRecordByteCount), payloadSize])
        for record in records { request.append(contentsOf: record[32...]) }
        XCTAssertTrue(gpu.processDeferred(request: request, memory: memory) { self.assertOK($0) }.isDeferred)
        accelerator.completeFirst()
        XCTAssertEqual(try memory.readBytes(at: address(1), count: 4), [0x7a, 0x7a, 0x7a, 0x7a])
        XCTAssertEqual(try memory.readBytes(at: address(2), count: 4), [0x7a, 0x7a, 0x7a, 0x7a])
    }

    func testScanoutChangeWaitsForFlushPublicationAndOldLeaseStaysImmutable() throws {
        let pause = PixelWorkPause()
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size), pixelWorkObserver: { pause.observe($0) })
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        try create(1, gpu: gpu, memory: memory)
        try create(2, gpu: gpu, memory: memory, value: 0x23)
        publish(1, gpu: gpu, memory: memory)
        let held = try XCTUnwrap(gpu.frameLease(afterGeneration: nil))
        let oldPixels = bytes(held)
        try writePixels(1, value: 0x45, memory: memory)
        assertOK(gpu.process(request: transfer(1), memory: memory))
        assertOK(gpu.process(request: transfer(2), memory: memory))
        pause.arm(.flush)
        let flushed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            self.assertOK(gpu.process(request: self.flush(1), memory: memory))
            flushed.signal()
        }
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 3), .success)
        let changed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            self.assertOK(gpu.process(request: self.packet(0x0103, [0, 0, self.size, self.size, 0, 2]), memory: memory))
            changed.signal()
        }
        XCTAssertEqual(changed.wait(timeout: .now() + 0.05), .timedOut)
        assertReadable(gpu, expected: oldPixels, generation: held.metadata.generation)
        pause.resume.signal()
        XCTAssertEqual(flushed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(changed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels.first, 0x45)
        assertOK(gpu.process(request: flush(2), memory: memory))
        XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels.first, 0x23)
        XCTAssertEqual(bytes(held), oldPixels)
    }

    func testCursorReadsUsePublishedCopyWhileItsResourceTransfers() throws {
        let pause = PixelWorkPause()
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size), pixelWorkObserver: { pause.observe($0) })
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        try create(1, gpu: gpu, memory: memory)
        try create(2, gpu: gpu, memory: memory, value: 0x33)
        publish(1, gpu: gpu, memory: memory)
        assertOK(gpu.process(request: transfer(2), memory: memory))
        assertOK(gpu.process(request: packet(0x0300, [0, 0, 0, 0, 2, 0, 0, 0]), memory: memory))
        let held = try XCTUnwrap(gpu.frameLease(afterGeneration: nil))
        let expected = bytes(held)
        try writePixels(2, value: 0x44, memory: memory)
        // Pause after the mutable resource changed, before its cursor image is
        // published. Readers must still see the old immutable cursor copy.
        pause.arm(.frameCopy)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            self.assertOK(gpu.process(request: self.transfer(2), memory: memory))
            finished.signal()
        }
        XCTAssertEqual(pause.entered.wait(timeout: .now() + 3), .success)
        assertReadable(gpu, expected: expected, generation: held.metadata.generation)
        pause.resume.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(bytes(held), expected)
        assertOK(gpu.process(request: packet(0x0300, [0, 0, 0, 0, 2, 0, 0, 0]), memory: memory))
        XCTAssertNotEqual(gpu.snapshot(afterGeneration: nil)?.pixels, expected)
    }

    func testReusedFrameSlotsCarryExactDamageInScanoutCoordinates() throws {
        let gpu = VirtIOGPUDevice(width: Int(size), height: Int(size))
        let memory = PhysicalMemory(base: base, size: 0x10_0000)
        try create(1, gpu: gpu, memory: memory)
        assertOK(gpu.process(request: transfer(1), memory: memory))
        assertOK(gpu.process(request: packet(0x0103, [16, 0, 32, size, 0, 1]), memory: memory))
        assertOK(gpu.process(request: flush(1), memory: memory))
        for x: UInt32 in [20, 21] {
            let previousGeneration = gpu.generation
            var request = submission(destination: 1)
            request.replaceSubrange(60..<76, with: words([x, 3, 1, 1]))
            assertOK(gpu.process(request: request, memory: memory))
            assertOK(gpu.process(request: transfer(1), memory: memory))
            assertOK(gpu.process(request: flush(1), memory: memory))
            let metadata = try XCTUnwrap(gpu.metadata(afterGeneration: previousGeneration))
            XCTAssertEqual(metadata.damage, [VirtualFramebufferDamage(x: Int(x) - 16, y: 3, width: 1, height: 1)])
            let frame = try XCTUnwrap(gpu.snapshot(afterGeneration: nil))
            // The first modified pixel must survive rotating back to an older
            // frame slot, even though the resource's scanout starts at x=16.
            XCTAssertEqual(frame.pixels[(3 * Int(size) + 4) * 4], 0x44)
            XCTAssertEqual(frame.pixels[(3 * Int(size) + Int(x) - 16) * 4], 0x44)
        }
    }

    private func assertReadable(_ gpu: VirtIOGPUDevice, expected: [UInt8], generation: UInt64) {
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            XCTAssertEqual(gpu.generation, generation)
            XCTAssertEqual(gpu.metadata(afterGeneration: nil)?.generation, generation)
            XCTAssertFalse(gpu.diagnosticsSummary().isEmpty)
            XCTAssertNotNil(gpu.performanceCounters()["transferCommands"])
            if let lease = gpu.frameLease(afterGeneration: nil) {
                XCTAssertEqual(self.bytes(lease), expected)
            } else { XCTFail("missing committed frame") }
            XCTAssertEqual(gpu.snapshot(afterGeneration: nil)?.pixels, expected)
            read.signal()
        }
        XCTAssertEqual(read.wait(timeout: .now() + 3), .success, "metadata lock held during pixel work")
    }

    private func bytes(_ lease: VirtualFramebufferFrameLease) -> [UInt8] {
        lease.withUnsafeBytes { Array($0.prefix(Int(size * size * 4))) }
    }

    private func address(_ id: UInt32) -> GuestAddress { base + UInt64(id) * 0x20_000 }

    private func writePixels(_ id: UInt32, value: UInt8, memory: PhysicalMemory, fragmented: Bool = false) throws {
        let count = Int(size * size * 4)
        var pixels = Array(repeating: value, count: count)
        for offset in stride(from: 3, to: count, by: 4) { pixels[offset] = 255 }
        if fragmented {
            try memory.writeBytes(Array(pixels[..<(count / 2)]), at: address(id))
            try memory.writeBytes(Array(pixels[(count / 2)...]), at: address(id) + 0x10_000)
        } else { try memory.writeBytes(pixels, at: address(id)) }
    }

    private func create(_ id: UInt32, gpu: VirtIOGPUDevice, memory: PhysicalMemory,
                        value: UInt8 = 0x10, fragmented: Bool = false) throws {
        try writePixels(id, value: value, memory: memory, fragmented: fragmented)
        assertOK(gpu.process(request: packet(0x0101, [id, 1, size, size]), memory: memory))
        let count = size * size * 4
        let entries: [(GuestAddress, UInt32)] = fragmented
            ? [(address(id), count / 2), (address(id) + 0x10_000, count / 2)] : [(address(id), count)]
        var request = packet(0x0106, [id, UInt32(entries.count)])
        for (address, length) in entries {
            request += words([UInt32(truncatingIfNeeded: address), UInt32(address >> 32), length, 0])
        }
        assertOK(gpu.process(request: request, memory: memory))
    }

    private func publish(_ id: UInt32, gpu: VirtIOGPUDevice, memory: PhysicalMemory) {
        assertOK(gpu.process(request: transfer(id), memory: memory))
        assertOK(gpu.process(request: packet(0x0103, [0, 0, size, size, 0, id]), memory: memory))
        assertOK(gpu.process(request: flush(id), memory: memory))
    }

    private func transfer(_ id: UInt32) -> [UInt8] { packet(0x0105, [0, 0, size, size, 0, 0, id, 0]) }
    private func flush(_ id: UInt32) -> [UInt8] { packet(0x0104, [0, 0, size, size, id, 0]) }
    private func packet(_ type: UInt32, _ payload: [UInt32]) -> [UInt8] { words([type, 1, 123, 0, 7, 0] + payload) }
    private func words(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    }

    private func submission(source: UInt32 = 0, destination: UInt32) -> [UInt8] {
        packet(0x0207, [64, 0, PineconeGraphicsProtocol.magic,
                       UInt32(PineconeGraphicsProtocol.version) | ((source == 0 ? 3 : 1) << 16),
                       0, source, destination, 0, 0, 0, 0, size, size, 0xff66_5544,
                       source == 0 ? 0 : size, source == 0 ? 0 : size, 0, 0])
    }

    private func type(_ response: [UInt8]) -> UInt32 {
        guard response.count >= 4 else { return 0 }
        return (0..<4).reduce(0) { $0 | UInt32(response[$1]) << ($1 * 8) }
    }

    private func assertOK(_ response: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(type(response), 0x1100, file: file, line: line)
    }
}

private final class PixelWorkPause: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var phase: VirtIOGPUDevice.PixelWorkPhase?

    func arm(_ phase: VirtIOGPUDevice.PixelWorkPhase) { lock.lock(); self.phase = phase; lock.unlock() }

    func observe(_ phase: VirtIOGPUDevice.PixelWorkPhase) {
        lock.lock()
        let matches = self.phase == phase
        if matches { self.phase = nil }
        lock.unlock()
        if matches {
            entered.signal()
            XCTAssertEqual(resume.wait(timeout: .now() + 15), .success, "test did not release pixel work")
        }
    }
}

private final class GPUResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UInt8]?
    var value: [UInt8]? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ value: [UInt8]) { lock.lock(); storage = value; lock.unlock() }
}

private final class ControlledGPUAccelerator: PineconeGraphicsAccelerator, @unchecked Sendable {
    enum Mode { case deferred, inlineSuccess, inlineFailure, reject }
    private struct Pending {
        let items: [PineconeGraphicsWorkItem]
        let completion: @Sendable (Bool) -> Void
    }
    private let lock = NSLock()
    private let mode: Mode
    private var pending: [Pending] = []
    init(mode: Mode = .deferred) { self.mode = mode }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    var firstSource: PineconeGraphicsSurface? { lock.lock(); defer { lock.unlock() }; return pending.first?.items.first?.source }
    var lastSource: PineconeGraphicsSurface? { lock.lock(); defer { lock.unlock() }; return pending.last?.items.first?.source }

    func execute(_ command: PineconeGraphicsCommand, source: PineconeGraphicsSurface?,
                 mask: PineconeGraphicsSurface?, destination: PineconeGraphicsSurface) -> Bool { false }

    func executeBatchAsync(_ items: [PineconeGraphicsWorkItem], completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        if mode == .reject { return false }
        if mode == .inlineSuccess || mode == .inlineFailure {
            if mode == .inlineSuccess { write(items) }
            completion(mode == .inlineSuccess)
            return true
        }
        lock.lock()
        pending.append(Pending(items: items, completion: completion))
        lock.unlock()
        return true
    }

    func completeFirst() {
        XCTAssertTrue(completeNextIfPresent(), "no pending work")
    }

    @discardableResult
    func completeNextIfPresent() -> Bool {
        lock.lock()
        guard !pending.isEmpty else { lock.unlock(); return false }
        let work = pending.removeFirst()
        lock.unlock()
        write(work.items)
        work.completion(true)
        return true
    }

    private func write(_ items: [PineconeGraphicsWorkItem]) {
        for item in items {
            if let source = item.source {
                item.destination.bytes.baseAddress!.copyMemory(from: source.bytes.baseAddress!, byteCount: source.bytes.count)
            } else {
                item.destination.bytes.initializeMemory(as: UInt8.self, repeating: 0x7a)
            }
        }
    }
}

private final class GPUResetTransport: @unchecked Sendable {
    let device: VirtualVirtIODevice
    private let memory: PhysicalMemory
    private let descriptors: GuestAddress = 0x4000_0000
    private let available: GuestAddress = 0x4000_1000
    private let used: GuestAddress = 0x4000_2000
    private let queueSize: UInt16 = 32
    private var availableIndex: UInt16 = 0

    init(memory: PhysicalMemory, accelerator: PineconeGraphicsAccelerator) throws {
        self.memory = memory
        device = VirtualVirtIODevice(name: "gpu-serial-reset", kind: .gpu, base: 0x1000,
                                     memory: memory, displayWidth: 64, displayHeight: 64)
        try configure()
        device.attachGraphicsAccelerator(accelerator)
    }

    func configure() throws {
        availableIndex = 0
        try memory.writeBytes(Array(repeating: 0, count: 0x3000), at: descriptors)
        for (offset, value): (UInt64, UInt64) in [
            (0x030, 0), (0x038, UInt64(queueSize)), (0x080, descriptors), (0x084, 0),
            (0x090, available), (0x094, 0), (0x0a0, used), (0x0a4, 0), (0x044, 1), (0x070, 0xf)
        ] {
            try device.write(offset: offset, width: .word, value: value)
        }
    }

    func enqueue(_ request: [UInt8]) throws -> GuestAddress {
        let slot = availableIndex % (queueSize / 2)
        let head = slot * 2
        let requestAddress: GuestAddress = 0x4001_0000 + UInt64(slot) * 0x1000
        let response = requestAddress + 0x800
        try memory.writeBytes(request, at: requestAddress)
        try memory.writeBytes(Array(repeating: 0, count: 24), at: response)
        for (index, address, length, flags, next): (UInt16, UInt64, UInt32, UInt16, UInt16) in [
            (head, requestAddress, UInt32(request.count), 1, head + 1),
            (head + 1, response, 24, 2, 0)
        ] {
            let descriptor = descriptors + UInt64(index) * 16
            try memory.write64(address, at: descriptor)
            try memory.write32(length, at: descriptor + 8)
            try memory.write16(flags, at: descriptor + 12)
            try memory.write16(next, at: descriptor + 14)
        }
        try memory.write16(head, at: available + 4 + UInt64(availableIndex % queueSize) * 2)
        availableIndex &+= 1
        try memory.write16(availableIndex, at: available + 2)
        return response
    }

    func notify() throws { try device.write(offset: 0x050, width: .word, value: 0) }
    func usedCount() throws -> UInt16 { try memory.read16(at: used + 2) }
}
