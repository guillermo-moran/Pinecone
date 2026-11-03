import Foundation

public struct UARTProgressWatchdogSnapshot: Sendable, Equatable {
    public let timedOut: Bool
    public let completed: Bool
    public let reachedMilestones: [String]
    public let nextMilestone: String?
    public let lastProgressNanoseconds: UInt64
    public let remainingNanoseconds: UInt64
}

/// A wall-clock watchdog renewed only by ordered, meaningful UART markers.
/// Arbitrary bytes and repeated log spam intentionally do not extend it.
public final class UARTProgressWatchdog: @unchecked Sendable {
    public static let lineageOSMilestones = [
        "Booting Linux",
        "Linux version ",
        "Kernel command line:",
        "Run /init as init process",
        "init: second stage started!",
        "init: starting service 'servicemanager'",
        "SurfaceFlinger: Connecting display",
        "SystemServerTiming: StartSystemUI",
        "init: processing action (sys.boot_completed=1)"
    ]

    public let timeoutNanoseconds: UInt64
    public let milestones: [String]

    private let lock = NSLock()
    private let milestoneBytes: [[UInt8]]
    private let maximumMarkerLength: Int
    private var recentBytes: [UInt8] = []
    private var reachedCount = 0
    private var lastProgressNanoseconds: UInt64

    public init(
        timeoutNanoseconds: UInt64,
        milestones: [String] = UARTProgressWatchdog.lineageOSMilestones,
        startedAtNanoseconds: UInt64
    ) {
        precondition(timeoutNanoseconds > 0)
        precondition(!milestones.isEmpty)
        precondition(milestones.allSatisfy { !$0.isEmpty })
        self.timeoutNanoseconds = timeoutNanoseconds
        self.milestones = milestones
        self.milestoneBytes = milestones.map { Array($0.utf8) }
        self.maximumMarkerLength = milestoneBytes.map(\.count).max() ?? 1
        self.lastProgressNanoseconds = startedAtNanoseconds
    }

    /// Feeds one UART byte. A later marker may skip markers absent from the log,
    /// allowing different kernel/init logging configurations to make progress.
    public func observe(byte: UInt8, atNanoseconds now: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        recentBytes.append(byte)
        if recentBytes.count > maximumMarkerLength {
            recentBytes.removeFirst(recentBytes.count - maximumMarkerLength)
        }

        var furthestMatch: Int?
        if reachedCount < milestoneBytes.count {
            for index in reachedCount..<milestoneBytes.count
            where recentBytes.ends(with: milestoneBytes[index]) {
                furthestMatch = index
            }
        }
        if let furthestMatch {
            reachedCount = furthestMatch + 1
            lastProgressNanoseconds = max(lastProgressNanoseconds, now)
        }
    }

    public func snapshot(atNanoseconds now: UInt64) -> UARTProgressWatchdogSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = now >= lastProgressNanoseconds
            ? now - lastProgressNanoseconds
            : 0
        let completed = reachedCount == milestones.count
        let remaining = completed
            ? UInt64.max
            : elapsed >= timeoutNanoseconds
                ? 0
                : timeoutNanoseconds - elapsed
        return UARTProgressWatchdogSnapshot(
            timedOut: !completed && elapsed >= timeoutNanoseconds,
            completed: completed,
            reachedMilestones: Array(milestones.prefix(reachedCount)),
            nextMilestone: reachedCount < milestones.count ? milestones[reachedCount] : nil,
            lastProgressNanoseconds: lastProgressNanoseconds,
            remainingNanoseconds: remaining
        )
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool {
        guard suffix.count <= count else { return false }
        return self[(count - suffix.count)...].elementsEqual(suffix)
    }
}
