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
