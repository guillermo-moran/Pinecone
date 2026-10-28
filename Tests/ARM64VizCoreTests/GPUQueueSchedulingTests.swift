import XCTest
@testable import ARM64VizCore

final class GPUQueueSchedulingTests: XCTestCase {
    func testAccessTrackingAllowsSharedReadsAndPreservesAllWriteHazards() {
        let first = GPUResourceAccess.parse(submission(source: 1, mask: 2, destination: 3))
        let second = GPUResourceAccess.parse(submission(source: 1, mask: 2, destination: 4))
        XCTAssertEqual(first.reads, [1, 2])
        XCTAssertEqual(first.writes, [3])
        XCTAssertFalse(first.conflicts(with: second))
        XCTAssertTrue(first.conflicts(with: GPUResourceAccess(writes: [1])))
        XCTAssertTrue(GPUResourceAccess(writes: [1]).conflicts(with: first))
        XCTAssertTrue(first.conflicts(with: GPUResourceAccess(writes: [3])))
    }

    func testBatchAccessIncludesEveryRecordAndMalformedCommandsAreGlobal() {
        let first = submission(source: 1, mask: 2, destination: 3)
        let second = submission(source: 3, destination: 4)
        var payload = [UInt8]()
        append32(PineconeGraphicsProtocol.magic, to: &payload)
        append16(PineconeGraphicsProtocol.batchVersion, to: &payload)
        append16(2, to: &payload)
        append16(UInt16(PineconeGraphicsProtocol.batchRecordByteCount), to: &payload)
        append16(0, to: &payload)
        append32(144, to: &payload)
        payload += first[32...] + second[32...]
        var request = gpuRequest(0x0207, words: [UInt32(payload.count), 0]) + payload
        XCTAssertEqual(GPUResourceAccess.parse(request), GPUResourceAccess(reads: [1, 2, 3], writes: [3, 4]))
        request[40] = 63
        XCTAssertTrue(GPUResourceAccess.parse(request).isGlobal)
        for malformed in [[], Array(first.prefix(70)), gpuRequest(0xffff), gpuRequest(0x0207)] {
            XCTAssertTrue(GPUResourceAccess.parse(malformed).isGlobal)
        }
        for type: UInt32 in [0x0100, 0x0101, 0x0102, 0x0103, 0x0104, 0x0106, 0x0107, 0x0300, 0x0301] {
            XCTAssertTrue(GPUResourceAccess.parse(gpuRequest(type, words: [1, 0, 0, 0, 0, 0])).isGlobal)
        }
        XCTAssertEqual(GPUResourceAccess.parse(gpuRequest(0x0105, words: [0, 0, 2, 2, 0, 0, 7, 0])).writes, [7])
    }

    func testFencedSharedSourceAndMaskExecuteTogetherButRetireInOrder() throws {
        let fixture = try QueueFixture(resources: 4)
        let baseline = try fixture.usedCount()
        let first = try fixture.enqueue(submission(source: 1, mask: 2, destination: 3, fence: 100))
        let second = try fixture.enqueue(submission(source: 1, mask: 2, destination: 4, fence: 101))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [3, 4])
        XCTAssertEqual(try fixture.usedCount(), baseline)

        fixture.accelerator.complete(at: 1)
        XCTAssertEqual(try fixture.usedCount(), baseline)
        XCTAssertEqual(try fixture.responseType(second), 0)
        XCTAssertEqual(try fixture.device.read(offset: 0x060, width: .word), 0)
        XCTAssertEqual(try fixture.memory.readBytes(at: fixture.backing(4), count: 16), Array(repeating: 0x7a, count: 16))

        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(try fixture.usedCount(), baseline + 2)
        XCTAssertEqual(try fixture.usedDescriptor(at: baseline), first.descriptor)
        XCTAssertEqual(try fixture.usedDescriptor(at: baseline + 1), second.descriptor)
        for (ticket, fence) in [(first, UInt64(100)), (second, UInt64(101))] {
            XCTAssertEqual(try fixture.responseType(ticket), 0x1100)
            XCTAssertEqual(try fixture.memory.read32(at: ticket.response + 4) & 1, 1)
            XCTAssertEqual(try fixture.memory.read64(at: ticket.response + 8), fence)
            XCTAssertEqual(try fixture.memory.read32(at: ticket.response + 16), 42)
            XCTAssertEqual(try fixture.memory.read8(at: ticket.response + 20), 3)
        }
    }

    func testIndependentWorkPassesBlockedHeadWithoutOvertakingPendingHazards() throws {
        let fixture = try QueueFixture(resources: 4)
        _ = try fixture.enqueue(submission(destination: 1))
        _ = try fixture.enqueue(submission(source: 1, mask: 3, destination: 2))
        _ = try fixture.enqueue(submission(destination: 3))
        _ = try fixture.enqueue(submission(destination: 2))
        _ = try fixture.enqueue(submission(destination: 4))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [1, 4])

        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(fixture.accelerator.destinations, [4, 2])
        fixture.accelerator.complete(at: 1)
        XCTAssertEqual(fixture.accelerator.destinations, [4, 3, 2])
        fixture.accelerator.completeAll()
    }

    func testFencedBatchesWithSharedReadsOverlapWithoutEarlyRetirement() throws {
        let fixture = try QueueFixture(resources: 6)
        let baseline = try fixture.usedCount()
        _ = try fixture.enqueue(batch([
            submission(source: 1, mask: 2, destination: 3, fence: 300),
            submission(source: 1, mask: 2, destination: 4)
        ]))
        let later = try fixture.enqueue(batch([
            submission(source: 1, mask: 2, destination: 5, fence: 301),
            submission(source: 1, mask: 2, destination: 6)
        ]))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [3, 5])
        fixture.accelerator.complete(at: 1)
        XCTAssertEqual(try fixture.usedCount(), baseline)
        XCTAssertEqual(try fixture.responseType(later), 0)
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(try fixture.usedCount(), baseline + 2)
        XCTAssertEqual(try fixture.memory.read64(at: later.response + 8), 301)
    }

    func testSameDestinationAndActiveReadWriteHazardsStayOrdered() throws {
        let fixture = try QueueFixture(resources: 3)
        _ = try fixture.enqueue(submission(source: 1, destination: 2))
        _ = try fixture.enqueue(submission(destination: 1))
        _ = try fixture.enqueue(submission(destination: 2))
        _ = try fixture.enqueue(submission(source: 2, destination: 3))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [2])
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(fixture.accelerator.destinations, [1, 2])
        fixture.accelerator.complete(at: 1)
        XCTAssertEqual(fixture.accelerator.destinations, [1, 3])
        fixture.accelerator.completeAll()
    }

    func testUnknownAndLifecycleCommandsAreBarriers() throws {
        for barrier in [gpuRequest(0xffff), gpuRequest(0x0107, words: [1, 0])] {
            let fixture = try QueueFixture(resources: 2)
            let baseline = try fixture.usedCount()
            _ = try fixture.enqueue(submission(destination: 1))
            let middle = try fixture.enqueue(barrier)
            _ = try fixture.enqueue(submission(destination: 2))
            try fixture.notify()
            XCTAssertEqual(fixture.accelerator.destinations, [1])
            XCTAssertEqual(try fixture.responseType(middle), 0)
            fixture.accelerator.complete(at: 0)
            XCTAssertEqual(fixture.accelerator.destinations, [2])
            XCTAssertEqual(try fixture.usedCount(), baseline + 2)
            XCTAssertNotEqual(try fixture.responseType(middle), 0)
            fixture.accelerator.completeAll()
        }
    }

    func testPendingWindowAndInFlightWorkAreBoundedAndRefillWithoutNotify() throws {
        let fixture = try QueueFixture(resources: 4)
        let baseline = try fixture.usedCount()
        let count = VirtualVirtIODevice.maximumPendingGPUCommands + 4
        for index in 0..<count {
            _ = try fixture.enqueue(submission(destination: UInt32(index % 4 + 1)))
        }
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [1, 2, 3])
        fixture.accelerator.completeAll()
        XCTAssertEqual(try fixture.usedCount(), baseline + UInt16(count))
        XCTAssertEqual(fixture.accelerator.maximumPendingCount, 3)
        XCTAssertEqual(fixture.accelerator.submissionCount, count)
    }

    func testLookaheadStopsAtBoundAndRefillsWhenEarlierWorkRetires() throws {
        let fixture = try QueueFixture(resources: 2)
        for _ in 0..<VirtualVirtIODevice.maximumPendingGPUCommands {
            _ = try fixture.enqueue(submission(destination: 1))
        }
        _ = try fixture.enqueue(submission(destination: 2))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [1])
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(fixture.accelerator.destinations, [1, 2])
        fixture.accelerator.completeAll()
    }

    func testRetainedRequestBytesAreBoundedIncludingActiveCommands() throws {
        let fixture = try QueueFixture(resources: 2)
        let first = try fixture.enqueue(submission(destination: 1))
        // A large scatter/gather request remains legal under the existing 1 MiB
        // per-request limit, but cannot coexist with another retained request.
        try fixture.padRequest(first, to: VirtualVirtIODevice.maximumPendingGPURequestBytes)
        _ = try fixture.enqueue(submission(destination: 2))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [1])
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(fixture.accelerator.destinations, [2])
        fixture.accelerator.completeAll()
    }

    func testOversizedLaterRequestDoesNotStrandAlreadyStagedWork() throws {
        let fixture = try QueueFixture(resources: 2)
        let baseline = try fixture.usedCount()
        _ = try fixture.enqueue(submission(destination: 1))
        let oversized = try fixture.enqueue(submission(destination: 2))
        try fixture.padRequest(oversized, to: VirtualVirtIODevice.maximumPendingGPURequestBytes + 1)
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [1])
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(try fixture.usedCount(), baseline + 1)
        XCTAssertEqual(try fixture.responseType(oversized), 0)
        XCTAssertEqual(fixture.accelerator.submissionCount, 1)
    }

    func testFailedLaterFenceAlsoWaitsForEarlierCompletion() throws {
        let fixture = try QueueFixture(resources: 2)
        let baseline = try fixture.usedCount()
        _ = try fixture.enqueue(submission(destination: 1, fence: 10))
        let failed = try fixture.enqueue(submission(destination: 2, fence: 11))
        try fixture.notify()
        fixture.accelerator.complete(at: 1, success: false)
        XCTAssertEqual(try fixture.usedCount(), baseline)
        XCTAssertEqual(try fixture.responseType(failed), 0)
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(try fixture.usedCount(), baseline + 2)
        XCTAssertEqual(try fixture.responseType(failed), 0x1200)
        XCTAssertEqual(try fixture.memory.read64(at: failed.response + 8), 11)
    }

    func testCursorQueueBarrierBlocksLaterControlWorkAndWakesOnCompletion() throws {
        let fixture = try QueueFixture(resources: 2)
        _ = try fixture.enqueue(submission(destination: 1))
        try fixture.notify()
        let cursorUsed = try fixture.submitCursorBarrier()
        _ = try fixture.enqueue(submission(destination: 2))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [1])
        XCTAssertEqual(try fixture.memory.read16(at: cursorUsed + 2), 0)
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(try fixture.memory.read16(at: cursorUsed + 2), 1)
        XCTAssertEqual(fixture.accelerator.destinations, [2])
        fixture.accelerator.completeAll()
    }

    func testResetDropsPendingAndUnretiredResponsesAndIgnoresOldCallbacks() throws {
        let fixture = try QueueFixture(resources: 3)
        _ = try fixture.enqueue(submission(destination: 1))
        _ = try fixture.enqueue(submission(destination: 1))
        _ = try fixture.enqueue(submission(destination: 2))
        try fixture.notify()
        fixture.accelerator.complete(at: 1)
        let resetStarted = expectation(description: "reset started")
        let resetFinished = expectation(description: "reset drained GPU")
        let callbackFinished = expectation(description: "callback released transport lock")
        let resetReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            resetStarted.fulfill()
            fixture.device.reset()
            resetReturned.signal()
            resetFinished.fulfill()
        }
        wait(for: [resetStarted], timeout: 2)
        // Reset must wait for the real accelerator fence, not invent completion.
        XCTAssertEqual(resetReturned.wait(timeout: .now() + .milliseconds(50)), .timedOut)
        DispatchQueue.global().async {
            fixture.accelerator.complete(at: 0, success: false)
            callbackFinished.fulfill()
        }
        let result = XCTWaiter.wait(for: [resetFinished, callbackFinished], timeout: 2)
        XCTAssertEqual(result, .completed, "Reset and completion must not form an AB/BA lock cycle")
        guard result == .completed else { return }
        try fixture.configure()
        try fixture.createResource(1)
        let baseline = try fixture.usedCount()
        let fresh = try fixture.enqueue(submission(destination: 1, fence: 200))
        try fixture.notify()
        XCTAssertEqual(fixture.accelerator.destinations, [1])
        XCTAssertEqual(try fixture.usedCount(), baseline)
        XCTAssertEqual(try fixture.responseType(fresh), 0)
        fixture.accelerator.complete(at: 0)
        XCTAssertEqual(try fixture.usedCount(), baseline + 1)
        XCTAssertEqual(try fixture.responseType(fresh), 0x1100)
        XCTAssertEqual(fixture.accelerator.submissionCount, 3)
    }
}

private struct QueueTicket {
    let descriptor: UInt16
    let response: GuestAddress
}

private final class QueueFixture: @unchecked Sendable {
    let memory = PhysicalMemory(base: 0x4000_0000, size: 0x30_0000)
    let device: VirtualVirtIODevice
    let accelerator = SchedulingAccelerator()
    private let descriptors: GuestAddress = 0x4000_0000
    private let available: GuestAddress = 0x4000_1000
    private let used: GuestAddress = 0x4000_2000
    private var availableIndex: UInt16 = 0
    private let queueSize: UInt16 = 128

    init(resources: Int) throws {
        device = VirtualVirtIODevice(name: "scheduling-test", kind: .gpu, base: 0x1000,
                                     memory: memory, displayWidth: 2, displayHeight: 2)
        try configure()
        for resource in 1...resources { try createResource(UInt32(resource)) }
        device.attachGraphicsAccelerator(accelerator)
        try device.write(offset: 0x064, width: .word, value: 1)
    }

    func configure() throws {
        availableIndex = 0
        try memory.writeBytes(Array(repeating: 0, count: 0x3000), at: descriptors)
        for (offset, value): (UInt64, UInt64) in [
            (0x030, 0), (0x038, UInt64(queueSize)),
            (0x080, descriptors), (0x084, 0), (0x090, available), (0x094, 0),
            (0x0a0, used), (0x0a4, 0), (0x044, 1), (0x070, 0xf)
        ] {
            try device.write(offset: offset, width: .word, value: value)
        }
    }

    func backing(_ resource: UInt32) -> GuestAddress { 0x4008_0000 + UInt64(resource) * 0x100 }

    func createResource(_ id: UInt32) throws {
        let create = try enqueue(gpuRequest(0x0101, words: [id, 1, 2, 2]))
        try notify()
        XCTAssertEqual(try responseType(create), 0x1100)
        var attach = gpuRequest(0x0106, words: [id, 1])
        append32(UInt32(backing(id)), to: &attach)
        append32(0, to: &attach)
        append32(16, to: &attach)
        append32(0, to: &attach)
        let ticket = try enqueue(attach)
        try notify()
        XCTAssertEqual(try responseType(ticket), 0x1100)
    }

    func enqueue(_ request: [UInt8]) throws -> QueueTicket {
        let slot = availableIndex % (queueSize / 2)
        let head = slot * 2
        let address = 0x4001_0000 + UInt64(slot) * 0x1000
        let response = address + 0x800
        try memory.writeBytes(request, at: address)
        try memory.writeBytes(Array(repeating: 0, count: 512), at: response)
        for (index, data, length, flags, next): (UInt16, UInt64, UInt32, UInt16, UInt16) in [
            (head, address, UInt32(request.count), 1, head + 1),
            (head + 1, response, 512, 2, 0)
        ] {
            let entry = descriptors + UInt64(index) * 16
            try memory.write64(data, at: entry)
            try memory.write32(length, at: entry + 8)
            try memory.write16(flags, at: entry + 12)
            try memory.write16(next, at: entry + 14)
        }
        try memory.write16(head, at: available + 4 + UInt64(availableIndex % queueSize) * 2)
        availableIndex &+= 1
        try memory.write16(availableIndex, at: available + 2)
        return QueueTicket(descriptor: head, response: response)
    }

    func notify() throws { try device.write(offset: 0x050, width: .word, value: 0) }

    func padRequest(_ ticket: QueueTicket, to length: Int) throws {
        let entry = descriptors + UInt64(ticket.descriptor) * 16
        let original = try memory.read64(at: entry)
        let originalLength = Int(try memory.read32(at: entry + 8))
        let relocated: UInt64 = 0x4010_0000
        var request = try memory.readBytes(at: original, count: originalLength)
        request += Array(repeating: 0, count: length - request.count)
        try memory.writeBytes(request, at: relocated)
        try memory.write64(relocated, at: entry)
        try memory.write32(UInt32(length), at: entry + 8)
    }

    func submitCursorBarrier() throws -> GuestAddress {
        let table: UInt64 = 0x4000_4000
        let available: UInt64 = 0x4000_5000
        let used: UInt64 = 0x4000_6000
        let request: UInt64 = 0x4000_7000
        let bytes = gpuRequest(0x0301, words: [0, 0, 0, 0, 0, 0, 0, 0])
        try memory.writeBytes(bytes, at: request)
        try memory.write64(request, at: table)
        try memory.write32(UInt32(bytes.count), at: table + 8)
        try memory.write16(0, at: available + 4)
        try memory.write16(1, at: available + 2)
        for (offset, value): (UInt64, UInt64) in [
            (0x030, 1), (0x038, 8), (0x080, table), (0x084, 0),
            (0x090, available), (0x094, 0), (0x0a0, used), (0x0a4, 0), (0x044, 1)
        ] { try device.write(offset: offset, width: .word, value: value) }
        try device.write(offset: 0x050, width: .word, value: 1)
        return used
    }
    func usedCount() throws -> UInt16 { try memory.read16(at: used + 2) }
    func responseType(_ ticket: QueueTicket) throws -> UInt32 { try memory.read32(at: ticket.response) }
    func usedDescriptor(at index: UInt16) throws -> UInt16 {
        UInt16(try memory.read32(at: used + 4 + UInt64(index % queueSize) * 8))
    }
}

private final class SchedulingAccelerator: PineconeGraphicsAccelerator, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(items: [PineconeGraphicsWorkItem], completion: @Sendable (Bool) -> Void)] = []
    private(set) var maximumPendingCount = 0
    private(set) var submissionCount = 0
    var destinations: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return pending.map { $0.items[0].command.destinationResourceID }
    }

    func execute(_ command: PineconeGraphicsCommand, source: PineconeGraphicsSurface?,
                 mask: PineconeGraphicsSurface?, destination: PineconeGraphicsSurface) -> Bool { false }

    func executeBatchAsync(_ items: [PineconeGraphicsWorkItem],
                           completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending.append((items, completion))
        maximumPendingCount = max(maximumPendingCount, pending.count)
        submissionCount += 1
        return true
    }

    func complete(at index: Int, success: Bool = true) {
        lock.lock()
        guard pending.indices.contains(index) else {
            lock.unlock()
            XCTFail("No accelerator work at index \(index)")
            return
        }
        let work = pending.remove(at: index)
        lock.unlock()
        if success {
            for item in work.items { item.destination.bytes.initializeMemory(as: UInt8.self, repeating: 0x7a) }
        }
        work.completion(success)
    }

    func completeAll() {
        for _ in 0..<256 {
            if destinations.isEmpty { return }
            complete(at: 0)
        }
        XCTFail("GPU scheduling did not drain")
    }
}

private func gpuRequest(_ type: UInt32, words: [UInt32] = []) -> [UInt8] {
    var bytes = [UInt8]()
    for word in [type, 0, 0, 0, 0, 0] + words { append32(word, to: &bytes) }
    return bytes
}

private func submission(source: UInt32 = 0, mask: UInt32 = 0, destination: UInt32,
                        fence: UInt64 = 0) -> [UInt8] {
    var request = [UInt8]()
    for word: UInt32 in [0x0207, fence == 0 ? 0 : 3, UInt32(truncatingIfNeeded: fence),
                        UInt32(fence >> 32), 42, 3, 64, 0] { append32(word, to: &request) }
    append32(PineconeGraphicsProtocol.magic, to: &request)
    append16(PineconeGraphicsProtocol.version, to: &request)
    append16(source == 0 ? 3 : 2, to: &request)
    for word: UInt32 in [mask == 0 ? 0 : PineconeGraphicsProtocol.hasMaskFlag,
                        source, destination, 0, 0, 0, 0, 2, 2, 0xff00_0000,
                        source == 0 ? 0 : 2, source == 0 ? 0 : 2, mask, 0] {
        append32(word, to: &request)
    }
    return request
}

private func batch(_ requests: [[UInt8]]) -> [UInt8] {
    let size = PineconeGraphicsProtocol.batchHeaderByteCount +
        requests.count * PineconeGraphicsProtocol.batchRecordByteCount
    var request = Array(requests[0].prefix(24))
    append32(UInt32(size), to: &request)
    append32(0, to: &request)
    append32(PineconeGraphicsProtocol.magic, to: &request)
    append16(PineconeGraphicsProtocol.batchVersion, to: &request)
    append16(UInt16(requests.count), to: &request)
    append16(UInt16(PineconeGraphicsProtocol.batchRecordByteCount), to: &request)
    append16(0, to: &request)
    append32(UInt32(size), to: &request)
    for record in requests { request += record[32...] }
    return request
}

private func append16(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes += [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
}

private func append32(_ value: UInt32, to bytes: inout [UInt8]) {
    append16(UInt16(truncatingIfNeeded: value), to: &bytes)
    append16(UInt16(truncatingIfNeeded: value >> 16), to: &bytes)
}
