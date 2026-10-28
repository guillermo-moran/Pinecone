/// Wire identities are deliberately limited to Phoc's presentation vocabulary.
/// Do not truncate or case-fold IDs: either can match the wrong application.
public struct ApplicationLaunchEvent: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case requested, launched, failed, cancelled
    }

    public let version: Int
    public let event: Phase
    public let token: String
    public let desktopID: String
    public let appIDs: [String]

    public init(version: Int = 1, event: Phase, token: String,
                desktopID: String, appIDs: [String]) {
        self.version = version
        self.event = event
        self.token = token
        self.desktopID = desktopID
        self.appIDs = appIDs
    }

    public var isValid: Bool {
        version == 1 && Self.validID(token) && Self.validID(desktopID) &&
            !appIDs.isEmpty && appIDs.count <= 8 && appIDs.allSatisfy(Self.validID) &&
            Set(appIDs).count == appIDs.count
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 95 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

/// Launch lifecycle correlation and bounded scheduling. No guest clock arithmetic,
/// CPU/backend selection, or graphics fence changes belong here. Call on the
/// runtime's existing lock/serial executor.
public struct ApplicationExecutionPolicy: Sendable {
    public enum Effect: Equatable, Sendable {
        case ignored, requested, presented, ended
    }

    private struct Launch: Sendable {
        let identity: ApplicationLaunchEvent
        let requestedAt: UInt64
        var launched: Bool
        var observedPresentation = false
        let legacy: Bool
    }

    public let watchdogNanoseconds: UInt64
    public let lifecycleRetentionNanoseconds: UInt64
    public static let maximumPendingLaunches = 16
    public static let maximumRememberedTokens = 256
    private var pending: [Launch] = []
    private var rememberedTokens: [String] = []
    private var recentStructured: [Launch] = []
    private var legacySequence: UInt64 = 0

    /// The short boost window does not discard launch identity. Retain it for a
    /// separate bounded interval so a slow first frame can still be reported.
    public init(watchdogNanoseconds: UInt64 = 12_000_000_000,
                lifecycleRetentionNanoseconds: UInt64 = 120_000_000_000) {
        self.watchdogNanoseconds = min(max(watchdogNanoseconds, 1), 15_000_000_000)
        self.lifecycleRetentionNanoseconds = min(
            max(lifecycleRetentionNanoseconds, self.watchdogNanoseconds), 120_000_000_000
        )
    }

    public var pendingCount: Int { pending.count }

    public mutating func isLatencySensitive(at now: UInt64) -> Bool {
        expire(at: now)
        return pending.contains {
            !$0.observedPresentation && now >= $0.requestedAt &&
                now - $0.requestedAt < watchdogNanoseconds
        }
    }

    /// Terminal callbacks are token-scoped. A late failure never cancels a newer
    /// launch of the same app. Replays cannot extend the original host deadline.
    @discardableResult
    public mutating func handle(_ record: GuestGraphicsTraceRecord, at now: UInt64) -> Effect {
        expire(at: now)
        switch record {
        case .applicationLifecycle(let event):
            guard event.isValid else { return .ignored }
            if event.event == .requested {
                guard !rememberedTokens.contains(event.token),
                      !pending.contains(where: { $0.identity.token == event.token }) else {
                    return .ignored
                }
                remember(event.token)
                let aliases = Set(event.appIDs)
                let legacy = pending.first { $0.legacy && !aliases.isDisjoint(with: $0.identity.appIDs) }
                pending.removeAll { $0.legacy && !aliases.isDisjoint(with: $0.identity.appIDs) }
                // Upgrading the legacy marker must not restart either clock.
                let launch = Launch(identity: event, requestedAt: legacy?.requestedAt ?? now,
                                    launched: false, legacy: false)
                recentStructured.append(launch)
                if recentStructured.count > Self.maximumRememberedTokens { recentStructured.removeFirst() }
                guard pending.count < Self.maximumPendingLaunches else { return .ignored }
                pending.append(launch)
                return .requested
            }
            guard let index = pending.firstIndex(where: {
                !$0.legacy && $0.identity.token == event.token &&
                    $0.identity.desktopID == event.desktopID && $0.identity.appIDs == event.appIDs
            }) else {
                if event.event == .failed || event.event == .cancelled,
                   !rememberedTokens.contains(event.token) {
                    remember(event.token)
                }
                return .ignored
            }
            if event.event == .launched {
                if pending[index].observedPresentation {
                    pending.remove(at: index)
                    return .presented
                }
                pending[index].launched = true
                return .ignored
            }
            pending.remove(at: index)
            return .ended

        case .applicationPresented(let appID):
            guard ApplicationLaunchEvent.validID(appID), let index = pending.firstIndex(where: {
                $0.identity.appIDs.contains(appID)
            }) else { return .ignored }
            // GIO's D-Bus callback can arrive after the first actual frame.
            // Keep that evidence, but do not confuse it with launch success.
            if !pending[index].launched {
                pending[index].observedPresentation = true
                return .ignored
            }
            // Phoc supplies an app ID, not a launch token/window ID. Consume only
            // the oldest matching launch; do not claim all instances presented.
            pending.remove(at: index)
            return .presented

        case .applicationLaunch(let name):
            guard ApplicationLaunchEvent.validID(name) else { return .ignored }
            let stem = name.hasSuffix(".desktop") ? String(name.dropLast(8)) : name
            let aliases = name == "settings" ? ["org.gnome.Settings", "gnome-control-center"] : [stem]
            guard aliases.allSatisfy(ApplicationLaunchEvent.validID),
                  !pending.contains(where: { !Set(aliases).isDisjoint(with: $0.identity.appIDs) }),
                  !recentStructured.contains(where: { !Set(aliases).isDisjoint(with: $0.identity.appIDs) }),
                  pending.count < Self.maximumPendingLaunches else { return .ignored }
            legacySequence &+= 1
            let event = ApplicationLaunchEvent(event: .requested, token: "legacy-\(legacySequence)",
                                               desktopID: name, appIDs: aliases)
            pending.append(Launch(identity: event, requestedAt: now, launched: true, legacy: true))
            return .requested

        case .graphics:
            // Optional telemetry, including dropped/present events, cannot
            // control scheduling or substitute for the unconditional marker.
            return .ignored
        }
    }

    public mutating func cancelAll() {
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func remember(_ token: String) {
        rememberedTokens.append(token)
        if rememberedTokens.count > Self.maximumRememberedTokens { rememberedTokens.removeFirst() }
    }

    private mutating func expire(at now: UInt64) {
        let timeout = lifecycleRetentionNanoseconds
        pending.removeAll { now < $0.requestedAt || now - $0.requestedAt >= timeout }
        recentStructured.removeAll { now < $0.requestedAt || now - $0.requestedAt >= timeout }
    }
}
