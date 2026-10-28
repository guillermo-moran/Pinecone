import Foundation
import XCTest
@testable import ARM64VizCore

final class InputFrameAttributionTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now: UInt64 = 1 }
    private func event(_ phase: TouchPhase = .down, id: UInt64 = 1, x: UInt32 = 0) -> TimestampedTouchEvent {
        .init(x: x, y: 0, isDown: phase.isDown, timestampNanoseconds: 1, phase: phase,
              traceIdentity: .init(epoch: 1, sequence: id))
    }

    private func trace(_ json: String) throws -> GuestGraphicsTraceEvent {
        try JSONDecoder().decode(GuestGraphicsTraceEvent.self, from: Data(json.utf8))
    }

    private var touch: String {
        #"{"version":2,"event":"touch","epoch":7,"inputSequence":3,"guestUs":1000,"handlerEndUs":1100,"eventTimeMsec":4294967295,"touchID":0,"phase":"up"}"#
    }
    private var frame: String {
        #"{"version":2,"event":"present","epoch":7,"frameID":20,"outputID":9,"sequence":4294967295,"guestUs":4000,"inputSequence":3,"inputUs":1000,"renderUs":2000,"submitUs":3000,"commitUs":3500,"association":"temporalOnly"}"#
    }

    func testTracingIsOptIn() throws {
        let timeline = VMPerformanceTimeline(startNanoseconds: 0) { 1 }
        XCTAssertNil(timeline.beginInputTrace(event(), queuedAt: 1))
        timeline.recordGuestGraphics(try trace(touch))
        XCTAssertTrue(timeline.snapshot().guestGraphics.isEmpty)
        XCTAssertTrue(timeline.snapshot().inputAttribution.isEmpty)
    }

    func testMalformedOptionalTraceMetadataCannotDropARelease() throws {
        let release = try JSONDecoder().decode(TimestampedTouchEvent.self,
            from: Data(#"{"x":0,"y":0,"isDown":false,"phase":"up","traceIdentity":{"epoch":-1}}"#.utf8))
        XCTAssertEqual(release.phase, .up)
        XCTAssertNil(release.traceIdentity)
    }

    func testCPUStagesRequirePairedNondecreasingThreadClockSamples() throws {
        let cpuTouch = touch.replacingOccurrences(of: "\"handlerEndUs\":1100", with: "\"handlerEndUs\":1100,\"handlerCPUUs\":30")
        let cpuFrame = frame.replacingOccurrences(of: "\"renderUs\":2000",
            with: "\"renderUs\":2000,\"renderCPUUs\":100,\"submitCPUUs\":120,\"commitCPUUs\":170")
        let sample = try XCTUnwrap(GuestFrameStageSample.samples(from: [trace(cpuTouch), trace(cpuFrame)]).first)
        XCTAssertEqual(sample.handlerCPUMilliseconds, 0.03)
        XCTAssertEqual(sample.renderToSubmitCPUMilliseconds, 0.02)
        XCTAssertEqual(sample.submitToCommitCPUMilliseconds, 0.05)
        let invalid = cpuFrame.replacingOccurrences(of: "\"submitCPUUs\":120", with: "\"submitCPUUs\":99")
        XCTAssertNil(try GuestFrameStageSample.samples(from: [trace(invalid)]).first?.renderToSubmitCPUMilliseconds)
        XCTAssertNil(try GuestFrameStageSample.samples(from: [trace(frame)]).first?.renderToSubmitCPUMilliseconds)
    }

    func testShortSwipeDoesNotBecomeResponseToUnrelatedFrame52SecondsLater() throws {
        let clock = Clock()
        let timeline = VMPerformanceTimeline(startNanoseconds: 0, attributionEnabled: true) { clock.now }
        let id = try XCTUnwrap(timeline.beginInputTrace(event(), queuedAt: 1))
        timeline.recordInputDisposition(id, reason: "injectedUncorrelated", atNanoseconds: 2)
        clock.now = 52_000_000_000
        timeline.recordFramePublished(generation: 1, committedAtNanoseconds: clock.now,
                                      publishedAtNanoseconds: clock.now, damagedByteCount: 4)
        XCTAssertFalse(timeline.recordFramePresented(generation: 1,
            presentedAtNanoseconds: clock.now + 1, uploadedByteCount: 4))
        let snapshot = timeline.snapshot()
        XCTAssertEqual(snapshot.inputAttribution.first?.disposition, "expiredUncorrelated")
        XCTAssertEqual(snapshot.attributionCounts["expiredUncorrelated"], 1)
        XCTAssertEqual(snapshot.touchSampleCount, 0)
        XCTAssertNil(snapshot.touchLatencyP95Milliseconds)
        XCTAssertTrue(snapshot.interactions.isEmpty)
        XCTAssertTrue(snapshot.inputFrameCorrelation.hasPrefix("unavailable"))
    }

    func testEvenImmediateUnrelatedFrameCannotCompleteAnInput() throws {
        let timeline = VMPerformanceTimeline(startNanoseconds: 0, attributionEnabled: true) { 3 }
        let id = try XCTUnwrap(timeline.beginInputTrace(event(), queuedAt: 1))
        timeline.recordInputDisposition(id, reason: "injectedUncorrelated", atNanoseconds: 2)
        timeline.recordFramePublished(generation: 1, committedAtNanoseconds: 3,
                                      publishedAtNanoseconds: 4, damagedByteCount: 4)
        XCTAssertFalse(timeline.recordFramePresented(generation: 1,
            presentedAtNanoseconds: 5, uploadedByteCount: 4))
        XCTAssertEqual(timeline.snapshot().inputAttribution.first?.disposition, "injectedUncorrelated")
        XCTAssertEqual(timeline.snapshot().framePipeline.frameSampleCount, 1)
    }

    func testLegacyTimeOnlyDiagnosticsAreExplicitAndBounded() {
        let timeline = VMPerformanceTimeline(startNanoseconds: 0) { 0 }
        for (generation, delay): (UInt64, UInt64) in [(1, 8_000_000_000), (2, 52_000_000_000)] {
            timeline.recordTouchFrame(generation: generation, queued: 1, delivered: 2)
            timeline.recordFramePublished(generation: generation, committedAtNanoseconds: delay,
                                          publishedAtNanoseconds: delay + 1, damagedByteCount: 4)
            timeline.recordFramePresented(generation: generation,
                presentedAtNanoseconds: delay + 2, uploadedByteCount: 4)
        }
        XCTAssertEqual(timeline.snapshot().interactions.count, 1)
        XCTAssertEqual(timeline.snapshot().interactions.first?.attribution, "temporalOnly")
        XCTAssertEqual(timeline.snapshot().touchSampleCount, 0)
    }

    func testMotionCoalescingHasExactIdentityAndPreservesEdges() {
        var queue = TouchMotionQueue(capacity: 8, maximumPendingMotionSamplesPerGesture: 2)
        queue.enqueue(event(.down, id: 1), nowNanoseconds: 100)
        for id in 2...5 { queue.enqueue(event(.move, id: UInt64(id), x: UInt32(id)), nowNanoseconds: 100) }
        queue.enqueue(event(.up, id: 6, x: 9), nowNanoseconds: 100)
        let discarded = queue.drainTraceDispositions()
        XCTAssertEqual(discarded.map(\.identity.sequence), [2, 3])
        XCTAssertEqual(discarded.map(\.reason), ["coalesced", "coalesced"])
        let output = queue.drain()
        XCTAssertEqual(output.compactMap(\.traceIdentity).map(\.sequence), [1, 4, 5, 6])
        XCTAssertNil(output[output.count - 2].traceIdentity, "Synthesized final motion must not reuse release identity")
        XCTAssertEqual(output.last?.phase, .up)
    }

    func testOverflowAndRejectedSamplesAreDistinct() {
        var queue = TouchMotionQueue(capacity: 4)
        queue.enqueue(event(.down, id: 1), nowNanoseconds: 100)
        queue.enqueue(event(.move, id: 2), nowNanoseconds: 100)
        queue.enqueue(event(.move, id: 3), nowNanoseconds: 100)
        XCTAssertFalse(queue.enqueue(event(.down, id: 4), nowNanoseconds: 100))
        XCTAssertEqual(queue.drainTraceDispositions().map(\.reason), ["droppedMotion", "rejected"])
    }

    func testDispositionBufferIsBoundedAndEmptyWithoutIdentity() {
        var queue = TouchMotionQueue(capacity: 4)
        for id in 1...100 { queue.enqueue(event(.up, id: UInt64(id)), nowNanoseconds: 100) }
        XCTAssertEqual(queue.drainTraceDispositions().count, 4)
        queue.removeAll()
        for _ in 1...100 { queue.enqueue(.init(x: 0, y: 0, isDown: false), nowNanoseconds: 100) }
        XCTAssertTrue(queue.drainTraceDispositions().isEmpty)
    }

    func testTerminalDispositionCannotBeRewrittenByLateInjection() throws {
        let clock = Clock()
        let timeline = VMPerformanceTimeline(startNanoseconds: 0, attributionEnabled: true) { clock.now }
        let id = try XCTUnwrap(timeline.beginInputTrace(event(), queuedAt: 1))
        timeline.recordInputDisposition(id, reason: "coalesced", atNanoseconds: 2)
        timeline.recordInputDisposition(id, reason: "injectedUncorrelated", atNanoseconds: 3)
        clock.now = 60_000_000_000
        XCTAssertEqual(timeline.snapshot().inputAttribution.first?.disposition, "coalesced")
        XCTAssertNil(timeline.snapshot().attributionCounts["injectedUncorrelated"])
    }

    func testExpiryAndResetRejectOldEpochAndReusedSequence() throws {
        let clock = Clock()
        let timeline = VMPerformanceTimeline(startNanoseconds: 0, attributionEnabled: true) { clock.now }
        let old = try XCTUnwrap(timeline.beginInputTrace(event(), queuedAt: 1))
        timeline.resetInputTrace()
        let new = try XCTUnwrap(timeline.beginInputTrace(event(), queuedAt: 2))
        XCTAssertNotEqual(old.epoch, new.epoch)
        XCTAssertEqual(old.sequence, new.sequence)
        timeline.recordInputDisposition(old, reason: "injectedUncorrelated", atNanoseconds: 3)
        clock.now = 10_000_000_003
        timeline.recordInputDisposition(new, reason: "injectedUncorrelated", atNanoseconds: clock.now)
        XCTAssertEqual(timeline.snapshot().inputAttribution.map(\.disposition), ["reset", "expiredUncorrelated"])
    }

    func testInputHistoryBoundAndCumulativeEvictionCounts() {
        let timeline = VMPerformanceTimeline(startNanoseconds: 0, attributionEnabled: true) { 1000 }
        for _ in 1...300 { _ = timeline.beginInputTrace(event(), queuedAt: 1) }
        let snapshot = timeline.snapshot()
        XCTAssertEqual(snapshot.inputAttribution.count, 256)
        XCTAssertEqual(snapshot.attributionCounts["queued"], 300)
        XCTAssertEqual(snapshot.attributionCounts["capacityEvicted"], 44)
    }

    func testReorderedGuestArrivalJoinsOnlyExactIdentityAndClock() throws {
        let events = try [trace(frame), trace(touch)]
        let sample = try XCTUnwrap(GuestFrameStageSample.samples(from: events).first)
        XCTAssertEqual(sample.inputAssociation, "temporalOnly")
        XCTAssertEqual(sample.handlerMilliseconds, 0.1)
        XCTAssertEqual(sample.inputToRenderMilliseconds, 1)
        XCTAssertEqual(sample.renderToSubmitMilliseconds, 1)
        XCTAssertEqual(sample.submitToCommitMilliseconds, 0.5)
        XCTAssertEqual(sample.commitToPresentCallbackMilliseconds, 0.5)
        XCTAssertEqual(GuestFrameStageSample.samples(from: events.reversed()), [sample])
    }

    func testMissingInputOrWrongEpochDoesNotInventCausality() throws {
        let events = try [trace(frame), trace(touch.replacingOccurrences(of: "\"epoch\":7", with: "\"epoch\":8"))]
        let sample = try XCTUnwrap(GuestFrameStageSample.samples(from: events).first)
        XCTAssertEqual(sample.inputAssociation, "unmatched")
        XCTAssertNil(sample.handlerMilliseconds)
        XCTAssertNil(sample.inputToRenderMilliseconds)
        XCTAssertEqual(sample.renderToSubmitMilliseconds, 1)
    }

    func testExpiredInputContextAndUnorderedStageTimesAreRejected() throws {
        let stale = frame.replacingOccurrences(of: "\"renderUs\":2000", with: "\"renderUs\":3000000")
        XCTAssertTrue(try GuestFrameStageSample.samples(from: [trace(stale)]).isEmpty)
        let noCausalHint = frame.replacingOccurrences(of: "temporalOnly", with: "causal")
        XCTAssertEqual(try GuestFrameStageSample.samples(from: [trace(noCausalHint), trace(touch)]).first?.inputAssociation, "unmatched")
        let wrongTime = frame.replacingOccurrences(of: "\"inputUs\":1000", with: "\"inputUs\":999")
        XCTAssertNil(try GuestFrameStageSample.samples(from: [trace(wrongTime), trace(touch)]).first?.handlerMilliseconds)
    }

    func testConflictingDuplicateFrameOrTouchCannotSupplyStages() throws {
        let other = frame.replacingOccurrences(of: "\"guestUs\":4000", with: "\"guestUs\":4001")
        XCTAssertTrue(try GuestFrameStageSample.samples(from: [trace(frame), trace(other)]).isEmpty)
        let otherTouch = touch.replacingOccurrences(of: "\"handlerEndUs\":1100", with: "\"handlerEndUs\":1200")
        XCTAssertNil(try GuestFrameStageSample.samples(from: [trace(frame), trace(touch), trace(otherTouch)]).first?.handlerMilliseconds)
        XCTAssertEqual(try GuestFrameStageSample.samples(from: [trace(frame), trace(frame)]).count, 1)
    }

    func testCommitSequenceWrapUsesFrameAndEpochIdentityNotOrdering() throws {
        let wrapped = frame.replacingOccurrences(of: "\"sequence\":4294967295", with: "\"sequence\":0")
            .replacingOccurrences(of: "\"frameID\":20", with: "\"frameID\":21")
        let reset = frame.replacingOccurrences(of: "\"epoch\":7", with: "\"epoch\":8")
        let samples = try GuestFrameStageSample.samples(from: [trace(reset), trace(wrapped), trace(frame), trace(touch)])
        XCTAssertEqual(samples.map(\.sequence), [.max, 0, .max])
        XCTAssertEqual(samples.map(\.inputAssociation), ["temporalOnly", "temporalOnly", "unmatched"])
    }

    func testDecoderResynchronizesAfterPartialRecordAndRetainsLegacy() throws {
        var decoder = GuestGraphicsTraceDecoder()
        XCTAssertTrue(decoder.append(Array("\u{1e}PINECONE_TRACE {\"event\":\"tou".utf8)).isEmpty)
        let events = decoder.append(Array(("\u{1e}PINECONE_TRACE " + touch + "\n").utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.inputSequence, 3)
        XCTAssertTrue(decoder.append(Array("\u{1e}PINECONE_TRACE ".utf8) + [UInt8](repeating: 65, count: 4096) + [10]).isEmpty)
        XCTAssertEqual(decoder.append(Array("PINECONE_TRACE {\"event\":\"touch\",\"guestUs\":1}\n".utf8)).count, 1)
    }

    func testGuestRawRingBoundAndHistoricalReportCompatibility() throws {
        let timeline = VMPerformanceTimeline(startNanoseconds: 0, attributionEnabled: true) { 0 }
        for _ in 1...400 { timeline.recordGuestGraphics(try trace(frame)) }
        XCTAssertEqual(timeline.snapshot().guestGraphics.count, 256)
        XCTAssertEqual(timeline.snapshot().guestFrameStages.count, 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline.snapshot())) as? [String: Any])
        for key in ["inputAttribution", "guestFrameStages", "attributionCounts", "inputFrameCorrelation"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(VMPerformanceTimelineSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.inputFrameCorrelation, "unknown: historical report")
        XCTAssertTrue(decoded.inputAttribution.isEmpty)
    }
}
