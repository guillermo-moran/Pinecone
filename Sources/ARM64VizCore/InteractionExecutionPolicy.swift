import Foundation

/// Scheduling is independent of first-frame latency telemetry. A first frame
/// may be unrelated damage or only the first step of a response animation.
public struct InteractionExecutionPolicy: Sendable {
    public let watchdogNanoseconds: UInt64
    public let settleNanoseconds: UInt64
    private var contactDown = false
    private var inputAt: UInt64?
    private var responseAt: UInt64?

    public init(watchdogNanoseconds: UInt64 = 5_000_000_000,
                settleNanoseconds: UInt64 = 250_000_000) {
        self.watchdogNanoseconds = watchdogNanoseconds
        self.settleNanoseconds = settleNanoseconds
    }

    public mutating func input(at now: UInt64, isDown: Bool) {
        inputAt = now
        contactDown = isDown
        responseAt = nil
    }

    public mutating func frame(at now: UInt64) {
        guard isLatencySensitive(at: now), let inputAt, now >= inputAt else { return }
        responseAt = now
    }

    public func isLatencySensitive(at now: UInt64) -> Bool {
        guard let inputAt, now >= inputAt,
              now - inputAt < watchdogNanoseconds else { return false }
        if contactDown { return true }
        guard let responseAt else { return true }
        return now >= responseAt && now - responseAt < settleNanoseconds
    }
}

/// Shared by idle and duty-cycle waits. Capture the generation before checking
/// eligibility so activity between the decision and registration is not lost.
@available(macOS 10.15, iOS 13.0, *)
public final class HostWakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public var currentGeneration: UInt64 {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

    public func signal() {
        lock.lock()
        generation &+= 1
        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        lock.unlock()

        for continuation in pending {
            continuation.resume()
        }
    }

    public func wait(after observedGeneration: UInt64, timeoutNanoseconds: UInt64) async {
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard generation == observedGeneration, !Task.isCancelled,
                      timeoutNanoseconds > 0 else {
                    lock.unlock()
                    continuation.resume()
                    return
                }

                waiters[identifier] = continuation
                lock.unlock()

                let boundedTimeout = min(timeoutNanoseconds, UInt64(Int.max))
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + .nanoseconds(Int(boundedTimeout))
                ) { [weak self] in
                    self?.resumeWaiter(identifier)
                }
            }
        } onCancel: {
            self.resumeWaiter(identifier)
        }
    }

    private func resumeWaiter(_ identifier: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: identifier)
        lock.unlock()
        continuation?.resume()
    }
}
