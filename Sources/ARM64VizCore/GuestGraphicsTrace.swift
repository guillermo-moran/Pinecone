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
}

public enum GuestGraphicsTraceRecord: Equatable, Sendable {
    case graphics(GuestGraphicsTraceEvent)
    case applicationPresented(String)
    case applicationLaunch(String)
}

public struct GuestGraphicsTraceDecoder {
    private static let tracePrefix = Array("PINECONE_TRACE ".utf8)
    private static let launchPrefix = Array("Pinecone app launch requested:".utf8)
    private static let presentedPrefix = Array("\u{1e}PINECONE_APP_PRESENTED ".utf8)
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
                if !dropping, line.starts(with: Self.tracePrefix),
                   let event = try? JSONDecoder().decode(GuestGraphicsTraceEvent.self,
                       from: Data(line.dropFirst(Self.tracePrefix.count))),
                   ["touch", "present", "dropped"].contains(event.event),
                   (event.apps?.count ?? 0) <= 8,
                   event.apps?.allSatisfy({ $0.utf8.count <= 95 }) ?? true {
                    events.append(.graphics(event))
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
                    if !name.isEmpty { events.append(.applicationLaunch(name)) }
                }
                line.removeAll(keepingCapacity: true)
                dropping = false
            } else if byte != 13, !dropping {
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
}
