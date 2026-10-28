import Foundation

/// Guest timestamps stay in their own monotonic clock domain. UART receive time
/// must never be substituted for guest processing or presentation time.
public struct GuestGraphicsTraceEvent: Codable, Equatable, Sendable {
    public let event: String
    public let guestUs: UInt64
    public let inputUs: UInt64?
    public let renderUs: UInt64?
    public let submitUs: UInt64?
    public let commitUs: UInt64?
    public let sequence: UInt32?
    public let apps: [String]?
    public var version: Int? = nil
    public var epoch: UInt64? = nil
    public var inputSequence: UInt64? = nil
    public var frameID: UInt64? = nil
    public var outputID: UInt64? = nil
    public var handlerEndUs: UInt64? = nil
    public var handlerCPUUs: UInt64? = nil
    public var renderCPUUs: UInt64? = nil
    public var submitCPUUs: UInt64? = nil
    public var commitCPUUs: UInt64? = nil
    public var eventTimeMsec: UInt32? = nil
    public var touchID: Int32? = nil
    public var phase: String? = nil
    public var association: String? = nil
    public var reason: String? = nil
}

public enum GuestGraphicsTraceRecord: Equatable, Sendable {
    case graphics(GuestGraphicsTraceEvent)
    case applicationPresented(String)
    case applicationLaunch(String)
    case applicationLifecycle(ApplicationLaunchEvent)
}

public struct GuestGraphicsTraceDecoder {
    private static let tracePrefix = Array("PINECONE_TRACE ".utf8)
    private static let launchPrefix = Array("Pinecone app launch requested:".utf8)
    private static let presentedPrefix = Array("\u{1e}PINECONE_APP_PRESENTED ".utf8)
    private static let lifecyclePrefix = Array("\u{1e}PINECONE_APP_LIFECYCLE ".utf8)
    private var line: [UInt8] = []
    private var dropping = false
    public init() {}

    public mutating func append(_ bytes: [UInt8]) -> [GuestGraphicsTraceEvent] {
        appendRecords(bytes).compactMap {
            if case .graphics(let event) = $0 { return event }
            return nil
        }
    }

    public mutating func appendRecords(_ bytes: [UInt8]) -> [GuestGraphicsTraceRecord] {
        var events: [GuestGraphicsTraceRecord] = []
        for byte in bytes {
            if byte == 0x1e {
                line.removeAll(keepingCapacity: true)
                dropping = false
            }
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                let traceLine = line.first == 0x1e ? Array(line.dropFirst()) : line
                if !dropping, traceLine.starts(with: Self.tracePrefix),
                   let event = try? JSONDecoder().decode(GuestGraphicsTraceEvent.self,
                       from: Data(traceLine.dropFirst(Self.tracePrefix.count))),
                   ["touch", "present", "dropped"].contains(event.event),
                   (event.apps?.count ?? 0) <= 8,
                   event.apps?.allSatisfy({ $0.utf8.count <= 95 }) ?? true {
                    events.append(.graphics(event))
                } else if !dropping, line.starts(with: Self.lifecyclePrefix),
                          let event = try? JSONDecoder().decode(ApplicationLaunchEvent.self,
                              from: Data(line.dropFirst(Self.lifecyclePrefix.count))), event.isValid {
                    events.append(.applicationLifecycle(event))
                } else if !dropping, line.starts(with: Self.presentedPrefix) {
                    let bytes = line.dropFirst(Self.presentedPrefix.count)
                    if !bytes.isEmpty && bytes.count <= 95 && bytes.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0) ||
                        (97...122).contains($0) || [45, 46, 95].contains($0)
                    }) {
                        events.append(.applicationPresented(String(decoding: bytes, as: UTF8.self)))
                    }
                } else if !dropping, line.starts(with: Self.launchPrefix) {
                    let name = String(decoding: line.dropFirst(Self.launchPrefix.count), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if ApplicationLaunchEvent.validID(name) { events.append(.applicationLaunch(name)) }
                }
                line.removeAll(keepingCapacity: true)
                dropping = false
            } else if !dropping {
                if line.count < 2048 { line.append(byte) }
                else { line.removeAll(keepingCapacity: true); dropping = true }
            }
        }
        return events
    }
}

public struct VMInteractionSample: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let queueToDeviceMilliseconds: Double
    public let deviceToCommitMilliseconds: Double
    public let commitToPublishMilliseconds: Double
    public let publishToPresentMilliseconds: Double
    public let totalMilliseconds: Double
    /// Historical callers supplied only a generation and times, not causality.
    public var attribution: String? = nil
}

/// All durations here use the guest monotonic clock, never UART receive time.
/// Frame identity grounds render/submit/present stages, not an input response.
public struct GuestFrameStageSample: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let frameID: UInt64
    public let outputID: UInt64
    public let sequence: UInt32
    public let inputSequence: UInt64?
    public let inputAssociation: String
    public let handlerMilliseconds: Double?
    public let handlerCPUMilliseconds: Double?
    public let inputToRenderMilliseconds: Double?
    public let renderToSubmitMilliseconds: Double
    public let submitToCommitMilliseconds: Double
    public let commitToPresentCallbackMilliseconds: Double
    public let renderToSubmitCPUMilliseconds: Double?
    public let submitToCommitCPUMilliseconds: Double?

    public static func samples(from events: [GuestGraphicsTraceEvent]) -> [Self] {
        // Grouping by identity, not UART order, also rejects conflicting duplicates.
        struct Key: Hashable { let epoch: UInt64; let id: UInt64 }
        var touches: [Key: GuestGraphicsTraceEvent] = [:]
        var frames: [Key: GuestGraphicsTraceEvent] = [:]
        var conflicts = Set<Key>()
        var touchConflicts = Set<Key>()
        for event in events where event.version == 2 {
            guard let epoch = event.epoch, epoch != 0 else { continue }
            if event.event == "touch", let id = event.inputSequence, id != 0 {
                let key = Key(epoch: epoch, id: id)
                if let old = touches[key], old != event { touchConflicts.insert(key) }
                touches[key] = event
            } else if let id = event.frameID, id != 0 {
                let key = Key(epoch: epoch, id: id)
                if let old = frames[key], old != event { conflicts.insert(key) }
                frames[key] = event
            }
        }
        return frames.keys.sorted { ($0.epoch, $0.id) < ($1.epoch, $1.id) }.compactMap { key in
            guard !conflicts.contains(key), let frame = frames[key], frame.event == "present",
                  let output = frame.outputID, output != 0, let sequence = frame.sequence,
                  let render = frame.renderUs, let submit = frame.submitUs,
                  let commit = frame.commitUs,
                  render <= submit, submit <= commit, commit <= frame.guestUs else { return nil }
            var handler: Double?
            var handlerCPU: Double?
            var inputToRender: Double?
            var association = frame.inputSequence == nil ? "none" : "unmatched"
            if frame.association == "temporalOnly", let id = frame.inputSequence,
               !touchConflicts.contains(Key(epoch: key.epoch, id: id)),
               let touch = touches[Key(epoch: key.epoch, id: id)],
               touch.guestUs == frame.inputUs, let end = touch.handlerEndUs,
               touch.guestUs <= end, end <= render, render - touch.guestUs <= 2_000_000 {
                handler = Double(end - touch.guestUs) / 1e3
                handlerCPU = touch.handlerCPUUs.map { Double($0) / 1e3 }
                inputToRender = Double(render - touch.guestUs) / 1e3
                association = "temporalOnly"
            }
            return Self(epoch: key.epoch, frameID: key.id, outputID: output,
                sequence: sequence, inputSequence: frame.inputSequence, inputAssociation: association,
                handlerMilliseconds: handler, handlerCPUMilliseconds: handlerCPU,
                inputToRenderMilliseconds: inputToRender,
                renderToSubmitMilliseconds: Double(submit - render) / 1e3,
                submitToCommitMilliseconds: Double(commit - submit) / 1e3,
                commitToPresentCallbackMilliseconds: Double(frame.guestUs - commit) / 1e3,
                renderToSubmitCPUMilliseconds: cpuSpan(frame.renderCPUUs, frame.submitCPUUs),
                submitToCommitCPUMilliseconds: cpuSpan(frame.submitCPUUs, frame.commitCPUUs))
        }
    }

    private static func cpuSpan(_ start: UInt64?, _ end: UInt64?) -> Double? {
        guard let start, let end, end >= start else { return nil }
        return Double(end - start) / 1e3
    }
}
