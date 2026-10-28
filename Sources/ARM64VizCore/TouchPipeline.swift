import Foundation

public enum TouchPhase: String, Codable, Sendable {
    case down, move, up, cancel

    public var isDown: Bool { self == .down || self == .move }
}

/// Host-only identity. The v2 timestamp wire does not transport this identity.
public struct TouchTraceIdentity: Codable, Equatable, Hashable, Sendable {
    public let epoch: UInt64
    public let sequence: UInt64
}

public struct TouchQueueTraceDisposition: Equatable, Sendable {
    public let identity: TouchTraceIdentity
    public let reason: String
}

/// The optional fields preserve recordings containing only x/y/isDown.
public struct TimestampedTouchEvent: Codable, Equatable, Sendable {
    public let x: UInt32
    public let y: UInt32
    public let isDown: Bool
    public let timestampNanoseconds: UInt64?
    public let phase: TouchPhase?
    public let traceIdentity: TouchTraceIdentity?

    public init(x: UInt32, y: UInt32, isDown: Bool,
                timestampNanoseconds: UInt64? = nil, phase: TouchPhase? = nil,
                traceIdentity: TouchTraceIdentity? = nil) {
        self.x = x
        self.y = y
        self.isDown = isDown
        self.timestampNanoseconds = timestampNanoseconds
        self.phase = phase
        self.traceIdentity = traceIdentity
    }

    public init(x: UInt32, y: UInt32, phase: TouchPhase, timestampNanoseconds: UInt64) {
        self.init(x: x, y: y, isDown: phase.isDown,
                  timestampNanoseconds: timestampNanoseconds, phase: phase)
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, isDown, timestampNanoseconds, phase, traceIdentity
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(UInt32.self, forKey: .x)
        y = try values.decode(UInt32.self, forKey: .y)
        isDown = try values.decode(Bool.self, forKey: .isDown)
        // Invalid optional time data must not prevent delivery of a release.
        timestampNanoseconds = try? values.decode(UInt64.self, forKey: .timestampNanoseconds)
        phase = try values.decodeIfPresent(TouchPhase.self, forKey: .phase)
        // Telemetry must never prevent an otherwise valid release from decoding.
        traceIdentity = try? values.decode(TouchTraceIdentity.self, forKey: .traceIdentity)
        if let phase, phase.isDown != isDown {
            throw DecodingError.dataCorruptedError(forKey: .phase, in: values,
                                                   debugDescription: "Touch phase contradicts isDown")
        }
    }
}

public enum TouchTimestamp {
    /// Convert UIKit's uptime seconds via a clock pair, not a wall-clock epoch.
    public static func capture(_ timestamp: TimeInterval,
                               uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                               nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        guard timestamp.isFinite, uptime.isFinite, timestamp >= 0,
              uptime >= timestamp else { return nowNanoseconds }
        let age = (uptime - timestamp) * 1_000_000_000
        // The strict bound also prevents trapping Double-to-UInt64 conversion.
        guard age.isFinite, age >= 0, age < Double(UInt64.max),
              age <= Double(nowNanoseconds) else { return nowNanoseconds }
        let ageNanoseconds = UInt64(age)
        guard ageNanoseconds <= nowNanoseconds else { return nowNanoseconds }
        return nowNanoseconds - ageNanoseconds
    }
}

/// Single-contact FIFO. Externally synchronized by the runtime/device lock.
/// Only ordinary motion is evictable. A newly admitted down reserves two slots
/// for its final move and release; full edge-only queues reject whole gestures.
public struct TouchMotionQueue {
    private struct Entry {
        var event: TimestampedTouchEvent
        var finalMove = false
    }

    public let capacity: Int
    /// Opt in only before device frame ordinals are assigned. Device queues must
    /// retain the default so compaction cannot invalidate delivery targets.
    public let maximumPendingMotionSamplesPerGesture: Int?
    private var entries: [Entry] = []
    private var active = false
    private var rejectingContact = false
    private var lastPoint: (x: UInt32, y: UInt32)?
    private var lastTimestamp: UInt64 = 0
    public private(set) var discardedMotionCount = 0
    public private(set) var rejectedGestureCount = 0
    private var traceDispositions: [TouchQueueTraceDisposition] = []

    public init(capacity: Int = 256, maximumPendingMotionSamplesPerGesture: Int? = nil) {
        precondition(capacity >= 4)
        precondition(maximumPendingMotionSamplesPerGesture.map { $0 >= 2 } ?? true)
        self.capacity = capacity
        self.maximumPendingMotionSamplesPerGesture = maximumPendingMotionSamplesPerGesture
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var contactActive: Bool { active }

    @discardableResult
    public mutating func enqueue(_ event: TimestampedTouchEvent,
                                 nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        var accepted = false
        defer { if !accepted { noteDisposition(event, reason: "rejected") } }
        guard event.phase == nil || event.phase?.isDown == event.isDown else { return false }
        let phase = event.phase ?? (event.isDown ? (active ? .move : .down) : .up)
        if rejectingContact {
            if !event.isDown { rejectingContact = false }
            return false
        }
        switch phase {
        case .down:
            guard !active else { return false }
            makeRoom(limit: capacity - 3)
            guard count <= capacity - 3 else {
                rejectingContact = true
                rejectedGestureCount += 1
                return false
            }
            active = true
        case .move:
            guard active else { return false }
            makeRoom(limit: capacity - 3)
            guard count <= capacity - 3 else { return false }
        case .up, .cancel:
            guard active else { return false }
        }
        let timestamp = max(lastTimestamp, min(event.timestampNanoseconds ?? nowNanoseconds,
                                              nowNanoseconds))
        let sample = TimestampedTouchEvent(x: event.x, y: event.y, isDown: phase.isDown,
            timestampNanoseconds: timestamp, phase: phase, traceIdentity: event.traceIdentity)
        lastTimestamp = timestamp
        if phase == .up || phase == .cancel {
            if lastPoint?.x != event.x || lastPoint?.y != event.y {
                entries.append(Entry(event: TimestampedTouchEvent(x: event.x, y: event.y,
                    phase: .move, timestampNanoseconds: timestamp), finalMove: true))
            } else if let index = entries.indices.last, entries[index].event.phase == .move {
                entries[index].finalMove = true
            }
            active = false
            lastPoint = nil
        } else {
            lastPoint = (event.x, event.y)
        }
        entries.append(Entry(event: sample))
        if phase == .move { compactPendingMotionHistory() }
        accepted = true
        return true
    }

    public mutating func drainTraceDispositions() -> [TouchQueueTraceDisposition] {
        let result = traceDispositions
        traceDispositions.removeAll(keepingCapacity: true)
        return result
    }

    public mutating func popFirst() -> TimestampedTouchEvent? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst().event
    }

    public mutating func drain(maxCount: Int = Int.max) -> [TimestampedTouchEvent] {
        let amount = min(count, max(0, maxCount))
        let result = entries.prefix(amount).map(\.event)
        entries.removeFirst(amount)
        return result
    }

    public mutating func removeAll() {
        self = Self(capacity: capacity,
                    maximumPendingMotionSamplesPerGesture: maximumPendingMotionSamplesPerGesture)
    }

    private mutating func compactPendingMotionHistory() {
        guard let limit = maximumPendingMotionSamplesPerGesture else { return }
        // Only the active contact's untransferred moves are eligible. A release
        // may append a distinct final point afterward; that point is protected.
        let start = entries.lastIndex { $0.event.phase != .move }.map { $0 + 1 } ?? 0
        let excess = entries.count - start - limit
        guard excess > 0 else { return }
        for entry in entries[start..<(start + excess)] {
            noteDisposition(entry.event, reason: "coalesced")
        }
        entries.removeSubrange(start..<(start + excess))
        discardedMotionCount += excess
    }

    private mutating func makeRoom(limit: Int) {
        while count > limit,
              let index = entries.firstIndex(where: { $0.event.phase == .move && !$0.finalMove }) {
            noteDisposition(entries[index].event, reason: "droppedMotion")
            entries.remove(at: index)
            discardedMotionCount += 1
        }
    }

    private mutating func noteDisposition(_ event: TimestampedTouchEvent, reason: String) {
        guard let identity = event.traceIdentity else { return }
        if traceDispositions.count == capacity { traceDispositions.removeFirst() }
        traceDispositions.append(.init(identity: identity, reason: reason))
    }
}

/// Reference implementation of the Linux patch's clock-domain conversion.
/// The host snapshot is latched while guest monotonic time is sampled. Retain
/// this pair across a burst: rebasing every event would recreate receipt jitter.
public struct TouchGuestClockMapping {
    public private(set) var hostAnchorNanoseconds: UInt64
    public private(set) var guestAnchorNanoseconds: UInt64
    public private(set) var lastTimestampNanoseconds: UInt64 = 0

    public init(hostAnchorNanoseconds: UInt64, guestAnchorNanoseconds: UInt64) {
        self.hostAnchorNanoseconds = hostAnchorNanoseconds
        self.guestAnchorNanoseconds = guestAnchorNanoseconds
    }

    /// Recalibrate only at a new contact (or recreate on device/PM reset).
    /// Keep the output floor so a new calibration cannot reorder gesture edges.
    public mutating func beginGesture(hostAnchorNanoseconds: UInt64, guestAnchorNanoseconds: UInt64) {
        self.hostAnchorNanoseconds = hostAnchorNanoseconds
        self.guestAnchorNanoseconds = guestAnchorNanoseconds
    }

    public mutating func map(_ captureNanoseconds: UInt64, guestNowNanoseconds: UInt64) -> UInt64 {
        let candidate: UInt64
        if captureNanoseconds > UInt64(Int64.max) {
            candidate = guestNowNanoseconds
        } else if captureNanoseconds <= hostAnchorNanoseconds {
            let age = hostAnchorNanoseconds - captureNanoseconds
            candidate = guestAnchorNanoseconds > age ? guestAnchorNanoseconds - age : 1
        } else {
            let delta = captureNanoseconds - hostAnchorNanoseconds
            let sum = guestAnchorNanoseconds.addingReportingOverflow(delta)
            candidate = sum.overflow ? guestNowNanoseconds : sum.partialValue
        }
        // Equal timestamps are valid (e.g. a final move followed by release).
        let result = max(lastTimestampNanoseconds, max(1, min(candidate, guestNowNanoseconds)))
        lastTimestampNanoseconds = result
        return result
    }
}

public enum TouchTimestampWire {
    public static let configSelect: UInt8 = 0x80
    public static let lowCode: UInt16 = 0x7f00
    public static let highCode: UInt16 = 0x7f01

    public static func words(_ timestamp: UInt64) -> (low: Int32, high: Int32) {
        (Int32(bitPattern: UInt32(truncatingIfNeeded: timestamp)),
         Int32(bitPattern: UInt32(truncatingIfNeeded: timestamp >> 32)))
    }
}
