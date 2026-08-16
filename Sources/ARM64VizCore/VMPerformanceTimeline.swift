import Foundation

public enum VMPerformanceMilestone: String, Codable, CaseIterable, Sendable {
    case guestExecutionStarted
    case shellPrompt
    case interactiveWorkloadStarted
    case interactiveWorkloadReady
    case firstVisibleFrame
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

public struct VMPerformanceTimelineSnapshot: Codable, Equatable, Sendable {
    public let elapsedMilliseconds: [String: Double]
    public let touchLatencyP50Milliseconds: Double?
    public let touchLatencyP95Milliseconds: Double?
    public let touchSampleCount: Int
    public let framePipeline: VMFramePipelineSnapshot

    public init(
        elapsedMilliseconds: [String: Double],
        touchLatencyP50Milliseconds: Double?,
        touchLatencyP95Milliseconds: Double?,
        touchSampleCount: Int,
        framePipeline: VMFramePipelineSnapshot
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.touchLatencyP50Milliseconds = touchLatencyP50Milliseconds
        self.touchLatencyP95Milliseconds = touchLatencyP95Milliseconds
        self.touchSampleCount = touchSampleCount
        self.framePipeline = framePipeline
    }
}

public final class VMPerformanceTimeline: @unchecked Sendable {
    private static let maximumTouchSamples = 256
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let startNanoseconds: UInt64
    private var milestones: [VMPerformanceMilestone: UInt64] = [:]
    private var touchLatencyNanoseconds: [UInt64] = []
    private var publishedFrames: [UInt64: (commit: UInt64, publish: UInt64)] = [:]
    private var commitToPublishNanoseconds: [UInt64] = []
    private var publishToPresentNanoseconds: [UInt64] = []
    private var commitToPresentNanoseconds: [UInt64] = []
    private var presentationIntervalsNanoseconds: [UInt64] = []
    private var lastPresentationNanoseconds: UInt64?
    private var damagedBytes: UInt64 = 0
    private var uploadedBytes: UInt64 = 0

    public init(
        startNanoseconds: UInt64? = nil,
        clock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.clock = clock
        self.startNanoseconds = startNanoseconds ?? clock()
        milestones[.guestExecutionStarted] = self.startNanoseconds
    }

    @discardableResult
    public func mark(_ milestone: VMPerformanceMilestone) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard milestones[milestone] == nil else { return false }
        milestones[milestone] = clock()
        return true
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

    public func recordFramePresented(
        generation: UInt64,
        presentedAtNanoseconds: UInt64,
        uploadedByteCount: Int
    ) {
        lock.lock()
        if let frame = publishedFrames.removeValue(forKey: generation) {
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
        if let previous = lastPresentationNanoseconds,
           presentedAtNanoseconds > previous {
            Self.append(
                presentedAtNanoseconds - previous,
                to: &presentationIntervalsNanoseconds
            )
        }
        lastPresentationNanoseconds = presentedAtNanoseconds
        uploadedBytes &+= UInt64(max(0, uploadedByteCount))
        lock.unlock()
    }

    public func snapshot() -> VMPerformanceTimelineSnapshot {
        lock.lock()
        let milestoneCopy = milestones
        let touchCopy = touchLatencyNanoseconds
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
        return VMPerformanceTimelineSnapshot(
            elapsedMilliseconds: elapsed,
            touchLatencyP50Milliseconds: Self.percentile(touchCopy, fraction: 0.50),
            touchLatencyP95Milliseconds: Self.percentile(touchCopy, fraction: 0.95),
            touchSampleCount: touchCopy.count,
            framePipeline: framePipeline
        )
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
