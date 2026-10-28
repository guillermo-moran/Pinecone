import Foundation

public enum VMPerformanceMilestone: String, Codable, CaseIterable, Sendable {
    case guestExecutionStarted
    case shellPrompt
    case interactiveWorkloadStarted
    case interactiveWorkloadReady
    case firstVisibleFrame
    case applicationLaunchRequested
    case applicationFirstVisibleFrame
    case applicationSurfacePresented
}

public struct VMFramePipelineSnapshot: Codable, Equatable, Sendable {
    public let frameSampleCount: Int
    public let commitToPublishP50Milliseconds: Double?
    public let commitToPublishP95Milliseconds: Double?
    public let publishToPresentP50Milliseconds: Double?
    public let publishToPresentP95Milliseconds: Double?
    public let commitToPresentP50Milliseconds: Double?
    public let commitToPresentP95Milliseconds: Double?
    public let presentationIntervalP95Milliseconds: Double?
    public let damagedBytes: UInt64
    public let uploadedBytes: UInt64
}

public struct VMExecutionMilestoneSnapshot: Codable, Equatable, Sendable {
    public let primaryNativeSteps: Int
    public let primaryFallbackSteps: Int
    public let secondarySteps: UInt64
    public let secondaryNativeSteps: UInt64
    public let secondaryFallbackSteps: UInt64

    public init(
        primaryNativeSteps: Int,
        primaryFallbackSteps: Int,
        secondarySteps: UInt64,
        secondaryNativeSteps: UInt64 = 0,
        secondaryFallbackSteps: UInt64 = 0
    ) {
        self.primaryNativeSteps = primaryNativeSteps
        self.primaryFallbackSteps = primaryFallbackSteps
        self.secondarySteps = secondarySteps
        self.secondaryNativeSteps = secondaryNativeSteps
        self.secondaryFallbackSteps = secondaryFallbackSteps
    }
}

public struct VMPerformanceTimelineSnapshot: Codable, Equatable, Sendable {
    public let elapsedMilliseconds: [String: Double]
    public let executionAtMilestones: [String: VMExecutionMilestoneSnapshot]
    public let touchLatencyP50Milliseconds: Double?
    public let touchLatencyP95Milliseconds: Double?
    public let touchSampleCount: Int
    public let framePipeline: VMFramePipelineSnapshot
    public var interactions: [VMInteractionSample] = []
    public var guestGraphics: [GuestGraphicsTraceEvent] = []
    public var inputAttribution: [VMInputAttributionSample] = []
    public var guestFrameStages: [GuestFrameStageSample] = []
    public var attributionCounts: [String: UInt64] = [:]
    public var inputFrameCorrelation: String = "unavailable: no shared input/frame identity"

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        elapsedMilliseconds = try values.decode([String: Double].self, forKey: .elapsedMilliseconds)
        executionAtMilestones = try values.decodeIfPresent(
            [String: VMExecutionMilestoneSnapshot].self, forKey: .executionAtMilestones) ?? [:]
        touchLatencyP50Milliseconds = try values.decodeIfPresent(Double.self, forKey: .touchLatencyP50Milliseconds)
        touchLatencyP95Milliseconds = try values.decodeIfPresent(Double.self, forKey: .touchLatencyP95Milliseconds)
        touchSampleCount = try values.decode(Int.self, forKey: .touchSampleCount)
        framePipeline = try values.decode(VMFramePipelineSnapshot.self, forKey: .framePipeline)
        interactions = try values.decodeIfPresent([VMInteractionSample].self, forKey: .interactions) ?? []
        guestGraphics = try values.decodeIfPresent([GuestGraphicsTraceEvent].self, forKey: .guestGraphics) ?? []
        inputAttribution = try values.decodeIfPresent([VMInputAttributionSample].self, forKey: .inputAttribution) ?? []
        guestFrameStages = try values.decodeIfPresent([GuestFrameStageSample].self, forKey: .guestFrameStages) ?? []
        attributionCounts = try values.decodeIfPresent([String: UInt64].self, forKey: .attributionCounts) ?? [:]
        inputFrameCorrelation = try values.decodeIfPresent(String.self, forKey: .inputFrameCorrelation)
            ?? "unknown: historical report"
    }

    public init(
        elapsedMilliseconds: [String: Double],
        executionAtMilestones: [String: VMExecutionMilestoneSnapshot] = [:],
        touchLatencyP50Milliseconds: Double?,
        touchLatencyP95Milliseconds: Double?,
        touchSampleCount: Int,
        framePipeline: VMFramePipelineSnapshot
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.executionAtMilestones = executionAtMilestones
        self.touchLatencyP50Milliseconds = touchLatencyP50Milliseconds
        self.touchLatencyP95Milliseconds = touchLatencyP95Milliseconds
        self.touchSampleCount = touchSampleCount
        self.framePipeline = framePipeline
    }
}

public struct VMInputAttributionSample: Codable, Equatable, Sendable {
    public let identity: TouchTraceIdentity
    public let phase: TouchPhase?
    public let captureNanoseconds: UInt64?
    public let queuedNanoseconds: UInt64
    public var injectedNanoseconds: UInt64?
    public var disposition: String
}

public final class VMPerformanceTimeline: @unchecked Sendable {
    private static let maximumTouchSamples = 256
    private static let maximumActivePresentationGapNanoseconds: UInt64 =
        1_000_000_000
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let startNanoseconds: UInt64
    private var milestones: [VMPerformanceMilestone: UInt64] = [:]
    private var executionAtMilestones: [
        VMPerformanceMilestone: VMExecutionMilestoneSnapshot
    ] = [:]
    private var touchLatencyNanoseconds: [UInt64] = []
    private var publishedFrames: [UInt64: (commit: UInt64, publish: UInt64)] = [:]
    private var commitToPublishNanoseconds: [UInt64] = []
    private var publishToPresentNanoseconds: [UInt64] = []
    private var commitToPresentNanoseconds: [UInt64] = []
    private var presentationIntervalsNanoseconds: [UInt64] = []
    private var lastPresentationNanoseconds: UInt64?
    private var interactionStartedNanoseconds: UInt64?
    private var damagedBytes: UInt64 = 0
    private var uploadedBytes: UInt64 = 0
    private var interactions: [VMInteractionSample] = []
    private var guestGraphics: [GuestGraphicsTraceEvent] = []
    private var pendingInteractions: [UInt64: (queued: UInt64, delivered: UInt64)] = [:]
    private let attributionEnabled: Bool
    private var inputEpoch: UInt64 = 1
    private var inputSequence: UInt64 = 0
    private var inputAttribution: [VMInputAttributionSample] = []
    private var attributionCounts: [String: UInt64] = [:]
    // Independent of scheduling boost deadlines. Expiry is not success/failure.
    private static let attributionLifetimeNanoseconds: UInt64 = 10_000_000_000

    public func beginInputTrace(_ event: TimestampedTouchEvent, queuedAt: UInt64) -> TouchTraceIdentity? {
        guard attributionEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        expireInputs(at: queuedAt)
        if inputSequence == UInt64.max { resetInputTraceLocked(reason: "sequenceWrap") }
        inputSequence += 1
        let identity = TouchTraceIdentity(epoch: inputEpoch, sequence: inputSequence)
        if inputAttribution.count == Self.maximumTouchSamples {
            let removed = inputAttribution.removeFirst()
            if Self.isPending(removed) { attributionCounts["capacityEvicted", default: 0] &+= 1 }
        }
        inputAttribution.append(.init(identity: identity, phase: event.phase,
            captureNanoseconds: event.timestampNanoseconds, queuedNanoseconds: queuedAt,
            disposition: "queued"))
        attributionCounts["queued", default: 0] &+= 1
        return identity
    }

    public func recordInputDisposition(_ identity: TouchTraceIdentity?, reason: String,
                                       atNanoseconds timestamp: UInt64) {
        guard attributionEnabled, let identity else { return }
        lock.lock()
        defer { lock.unlock() }
        expireInputs(at: timestamp)
        guard identity.epoch == inputEpoch,
              let index = inputAttribution.firstIndex(where: { $0.identity == identity }),
              Self.isPending(inputAttribution[index]),
              timestamp >= inputAttribution[index].queuedNanoseconds,
              ["injectedUncorrelated", "coalesced", "droppedMotion", "rejected"].contains(reason)
        else { return }
        if inputAttribution[index].disposition == reason { return }
        inputAttribution[index].disposition = reason
        if reason == "injectedUncorrelated" { inputAttribution[index].injectedNanoseconds = timestamp }
        attributionCounts[reason, default: 0] &+= 1
    }

    public func resetInputTrace() {
        lock.lock()
        resetInputTraceLocked(reason: "reset")
        publishedFrames.removeAll()
        pendingInteractions.removeAll()
        interactionStartedNanoseconds = nil
        lastPresentationNanoseconds = nil
        guestGraphics.removeAll()
        lock.unlock()
    }

    private func resetInputTraceLocked(reason: String) {
        for index in inputAttribution.indices where Self.isPending(inputAttribution[index]) {
            inputAttribution[index].disposition = reason
            attributionCounts[reason, default: 0] &+= 1
        }
        inputEpoch &+= 1
        if inputEpoch == 0 { inputEpoch = 1 }
        inputSequence = 0
    }

    private static func isPending(_ input: VMInputAttributionSample) -> Bool {
        input.disposition == "queued" || input.disposition == "injectedUncorrelated"
    }

    private func expireInputs(at now: UInt64) {
        for index in inputAttribution.indices where Self.isPending(inputAttribution[index]) {
            let queued = inputAttribution[index].queuedNanoseconds
            if now >= queued, now - queued > Self.attributionLifetimeNanoseconds {
                inputAttribution[index].disposition = "expiredUncorrelated"
                attributionCounts["expiredUncorrelated", default: 0] &+= 1
            }
        }
    }

    public func recordGuestGraphics(_ event: GuestGraphicsTraceEvent) {
        guard attributionEnabled else { return }
        lock.lock()
        if guestGraphics.count == Self.maximumTouchSamples { guestGraphics.removeFirst() }
        guestGraphics.append(event)
        lock.unlock()
    }

    /// Compatibility-only temporal diagnostic. Never establishes input causality.
    public func recordTouchFrame(generation: UInt64, queued: UInt64, delivered: UInt64) {
        guard delivered >= queued else { return }
        lock.lock()
        if pendingInteractions.count >= Self.maximumTouchSamples,
           let oldest = pendingInteractions.keys.min() { pendingInteractions.removeValue(forKey: oldest) }
        pendingInteractions[generation] = (queued, delivered)
        lock.unlock()
    }

    public init(
        startNanoseconds: UInt64? = nil,
        attributionEnabled: Bool = false,
        clock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.clock = clock
        self.attributionEnabled = attributionEnabled
        self.startNanoseconds = startNanoseconds ?? clock()
        milestones[.guestExecutionStarted] = self.startNanoseconds
    }

    @discardableResult
    public func mark(
        _ milestone: VMPerformanceMilestone,
        execution: VMExecutionMilestoneSnapshot? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard milestones[milestone] == nil else { return false }
        milestones[milestone] = clock()
        if let execution {
            executionAtMilestones[milestone] = execution
        }
        return true
    }

    public func recordInteractionStarted(atNanoseconds timestamp: UInt64) {
        lock.lock()
        if interactionStartedNanoseconds == nil {
            interactionStartedNanoseconds = timestamp
        }
        lock.unlock()
    }

    public func recordTouchLatency(nanoseconds: UInt64) {
        lock.lock()
        if touchLatencyNanoseconds.count == Self.maximumTouchSamples {
            touchLatencyNanoseconds.removeFirst()
        }
        touchLatencyNanoseconds.append(nanoseconds)
        lock.unlock()
    }

    public func recordFramePublished(
        generation: UInt64,
        committedAtNanoseconds: UInt64,
        publishedAtNanoseconds: UInt64,
        damagedByteCount: Int
    ) {
        lock.lock()
        publishedFrames[generation] = (
            commit: committedAtNanoseconds,
            publish: publishedAtNanoseconds
        )
        if publishedAtNanoseconds >= committedAtNanoseconds {
            Self.append(
                publishedAtNanoseconds - committedAtNanoseconds,
                to: &commitToPublishNanoseconds
            )
        }
        damagedBytes &+= UInt64(max(0, damagedByteCount))
        trimPublishedFrames()
        lock.unlock()
    }

    @discardableResult
    public func recordFramePresented(
        generation: UInt64,
        presentedAtNanoseconds: UInt64,
        uploadedByteCount: Int
    ) -> Bool {
        lock.lock()
        var recordedInteraction = false
        var presentsInteraction = false
        if let frame = publishedFrames.removeValue(forKey: generation) {
            if let input = pendingInteractions.removeValue(forKey: generation),
               frame.commit >= input.delivered, frame.publish >= frame.commit,
               presentedAtNanoseconds >= frame.publish,
               presentedAtNanoseconds - input.queued <= Self.attributionLifetimeNanoseconds {
                if interactions.count == Self.maximumTouchSamples { interactions.removeFirst() }
                interactions.append(VMInteractionSample(
                    generation: generation,
                    queueToDeviceMilliseconds: Double(input.delivered - input.queued) / 1e6,
                    deviceToCommitMilliseconds: Double(frame.commit - input.delivered) / 1e6,
                    commitToPublishMilliseconds: Double(frame.publish - frame.commit) / 1e6,
                    publishToPresentMilliseconds: Double(presentedAtNanoseconds - frame.publish) / 1e6,
                    totalMilliseconds: Double(presentedAtNanoseconds - input.queued) / 1e6,
                    attribution: "temporalOnly"))
                recordedInteraction = true
            }
            presentsInteraction = interactionStartedNanoseconds.map {
                frame.commit >= $0 && presentedAtNanoseconds >= $0 &&
                presentedAtNanoseconds - $0 <= Self.attributionLifetimeNanoseconds
            } ?? false
            if presentedAtNanoseconds >= frame.publish {
                Self.append(
                    presentedAtNanoseconds - frame.publish,
                    to: &publishToPresentNanoseconds
                )
            }
            if presentedAtNanoseconds >= frame.commit {
                Self.append(
                    presentedAtNanoseconds - frame.commit,
                    to: &commitToPresentNanoseconds
                )
            }
        }
        publishedFrames = publishedFrames.filter { $0.key > generation }
        pendingInteractions = pendingInteractions.filter { $0.key > generation }
        if let previous = lastPresentationNanoseconds,
           presentedAtNanoseconds > previous,
           (presentsInteraction || presentedAtNanoseconds - previous <=
            Self.maximumActivePresentationGapNanoseconds) {
            let start = presentsInteraction
                ? max(previous, interactionStartedNanoseconds ?? previous) : previous
            Self.append(
                presentedAtNanoseconds - start,
                to: &presentationIntervalsNanoseconds
            )
        }
        if presentsInteraction { interactionStartedNanoseconds = nil }
        lastPresentationNanoseconds = presentedAtNanoseconds
        uploadedBytes &+= UInt64(max(0, uploadedByteCount))
        lock.unlock()
        return recordedInteraction
    }

    public func snapshot() -> VMPerformanceTimelineSnapshot {
        lock.lock()
        expireInputs(at: clock())
        let milestoneCopy = milestones
        let executionCopy = executionAtMilestones
        let touchCopy = touchLatencyNanoseconds
        let interactionCopy = interactions
        let guestCopy = guestGraphics
        let inputCopy = inputAttribution
        let attributionCountsCopy = attributionCounts
        let framePipeline = VMFramePipelineSnapshot(
            frameSampleCount: commitToPresentNanoseconds.count,
            commitToPublishP50Milliseconds: Self.percentile(commitToPublishNanoseconds, fraction: 0.50),
            commitToPublishP95Milliseconds: Self.percentile(commitToPublishNanoseconds, fraction: 0.95),
            publishToPresentP50Milliseconds: Self.percentile(publishToPresentNanoseconds, fraction: 0.50),
            publishToPresentP95Milliseconds: Self.percentile(publishToPresentNanoseconds, fraction: 0.95),
            commitToPresentP50Milliseconds: Self.percentile(commitToPresentNanoseconds, fraction: 0.50),
            commitToPresentP95Milliseconds: Self.percentile(commitToPresentNanoseconds, fraction: 0.95),
            presentationIntervalP95Milliseconds: Self.percentile(presentationIntervalsNanoseconds, fraction: 0.95),
            damagedBytes: damagedBytes,
            uploadedBytes: uploadedBytes
        )
        lock.unlock()

        let elapsed = milestoneCopy.reduce(into: [String: Double]()) { result, entry in
            result[entry.key.rawValue] = Double(entry.value &- startNanoseconds) / 1_000_000
        }
        var result = VMPerformanceTimelineSnapshot(
            elapsedMilliseconds: elapsed,
            executionAtMilestones: executionCopy.reduce(into: [:]) {
                $0[$1.key.rawValue] = $1.value
            },
            touchLatencyP50Milliseconds: Self.percentile(touchCopy, fraction: 0.50),
            touchLatencyP95Milliseconds: Self.percentile(touchCopy, fraction: 0.95),
            touchSampleCount: touchCopy.count,
            framePipeline: framePipeline
        )
        result.interactions = interactionCopy
        result.guestGraphics = guestCopy
        result.inputAttribution = inputCopy
        result.attributionCounts = attributionCountsCopy
        result.guestFrameStages = GuestFrameStageSample.samples(from: guestCopy)
        return result
    }

    private func trimPublishedFrames() {
        guard publishedFrames.count > Self.maximumTouchSamples else { return }
        for generation in publishedFrames.keys.sorted().prefix(
            publishedFrames.count - Self.maximumTouchSamples
        ) {
            publishedFrames.removeValue(forKey: generation)
        }
    }

    private static func append(_ value: UInt64, to samples: inout [UInt64]) {
        if samples.count == maximumTouchSamples {
            samples.removeFirst()
        }
        samples.append(value)
    }

    private static func percentile(_ samples: [UInt64], fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = min(
            sorted.count - 1,
            Int((Double(sorted.count - 1) * fraction).rounded(.up))
        )
        return Double(sorted[index]) / 1_000_000
    }
}
