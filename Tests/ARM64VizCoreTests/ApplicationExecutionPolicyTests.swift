import Foundation
import XCTest
@testable import ARM64VizCore

final class ApplicationExecutionPolicyTests: XCTestCase {
    func testConsoleFilterPreservesPromptsAndUnknownPrefixes() {
        var filter = GuestControlConsoleFilter()
        for byte in "root # ".utf8 { XCTAssertEqual(filter.append([byte]), [byte]) }
        XCTAssertTrue(filter.append(Array("\u{1e}PINECONE_APP_LIFE".utf8)).isEmpty)
        XCTAssertTrue(filter.append(Array("CYCLE {invalid payload}\r\n".utf8)).isEmpty)
        let unknown = "\u{1e}PINECONE_APP_UNKNOWN x\n"
        XCTAssertEqual(filter.append(Array(unknown.utf8)), Array(unknown.utf8))
        XCTAssertTrue(filter.append(Array("\u{1e}PINE".utf8)).isEmpty)
        XCTAssertEqual(filter.append(Array("X root # ".utf8)), Array("\u{1e}PINEX root # ".utf8))
    }

    func testConsoleFilterResynchronizesAndBoundsDiscarding() {
        var filter = GuestControlConsoleFilter()
        XCTAssertTrue(filter.append(Array("\u{1e}PINECONE_APP_LIFECYCLE {truncated".utf8)).isEmpty)
        XCTAssertTrue(filter.append(Array("\u{1e}PINECONE_APP_PRESENTED editor-window\n".utf8)).isEmpty)
        XCTAssertEqual(filter.append(Array("root # ".utf8)), Array("root # ".utf8))
        XCTAssertTrue(filter.append(Array("\u{1e}PINECONE_APP_PRESENTED broken".utf8)).isEmpty)
        let unknown = "\u{1e}UNKNOWN root # "
        XCTAssertEqual(filter.append(Array(unknown.utf8)), Array(unknown.utf8))
        XCTAssertTrue(filter.append(Array("\u{1e}PINECONE_APP_LIFECYCLE ".utf8)).isEmpty)
        XCTAssertTrue(filter.append(Array(repeating: 120, count: 2048)).isEmpty)
        XCTAssertEqual(filter.append(Array("root # ".utf8)), Array("root # ".utf8))
    }

    func testConsoleFilterAtEveryPossibleChunkBoundary() throws {
        let bytes = try wire(event()) + Array("\u{1e}PINECONE_APP_PRESENTED editor-window\nroot # ".utf8)
        for split in 0...bytes.count {
            var filter = GuestControlConsoleFilter()
            let output = filter.append(Array(bytes[..<split])) + filter.append(Array(bytes[split...]))
            XCTAssertEqual(output, Array("root # ".utf8), "split \(split)")
        }
    }

    private func event(_ phase: ApplicationLaunchEvent.Phase = .requested, _ token: String = "launch-1",
                       desktop: String = "org.example.Editor.desktop",
                       aliases: [String] = ["org.example.Editor", "editor-window"]) -> GuestGraphicsTraceRecord {
        .applicationLifecycle(ApplicationLaunchEvent(event: phase, token: token, desktopID: desktop, appIDs: aliases))
    }

    private func wire(_ record: GuestGraphicsTraceRecord) throws -> [UInt8] {
        guard case .applicationLifecycle(let event) = record else { return [] }
        return Array("\u{1e}PINECONE_APP_LIFECYCLE ".utf8) + Array(try JSONEncoder().encode(event)) + [10]
    }

    func testPrimaryAndSecondaryPacingHaveIndependentBoundedWindows() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100,
                                                lifecycleRetentionNanoseconds: 1_000)
        XCTAssertEqual(policy.pacingSuppression(at: 0), .init(primary: false, secondary: false))
        policy.handle(event(), at: 10)
        XCTAssertEqual(policy.pacingSuppression(at: 109), .init(primary: true, secondary: true))
        XCTAssertEqual(policy.pacingSuppression(at: 110), .init(primary: true, secondary: false))
        policy.handle(event(.launched), at: 900)
        XCTAssertEqual(policy.pacingSuppression(at: 1_009), .init(primary: true, secondary: false))
        XCTAssertEqual(policy.pacingSuppression(at: 1_010), .init(primary: false, secondary: false))
        policy.handle(event(), at: 1_011)
        XCTAssertEqual(policy.pacingSuppression(at: 1_011), .init(primary: false, secondary: false))
    }

    func testOverlappingPresentationsConsumeDistinctPendingLaunches() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        policy.handle(event(), at: 10)
        policy.handle(event(.requested, "second"), at: 20)
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 30), .ignored)
        policy.handle(event(.launched, "second"), at: 40)
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 50), .presented)
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertEqual(policy.pacingSuppression(at: 50), .init(primary: false, secondary: false))
        XCTAssertEqual(policy.handle(event(.launched), at: 60), .presented)
        XCTAssertEqual(policy.pendingCount, 0)
    }

    func testNewLaunchBoostDoesNotRenewOlderPrimaryDeadline() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100,
                                                lifecycleRetentionNanoseconds: 1_000)
        policy.handle(event(), at: 10)
        policy.handle(event(.requested, "second"), at: 950)
        XCTAssertEqual(policy.pacingSuppression(at: 1_010), .init(primary: true, secondary: true))
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertEqual(policy.pacingSuppression(at: 1_050), .init(primary: true, secondary: false))
        policy.handle(event(.cancelled, "second"), at: 1_051)
        XCTAssertEqual(policy.pacingSuppression(at: 1_051), .init(primary: false, secondary: false))
    }

    func testPrimarySuppressionEndsOnAllTerminalPathsAfterShortBoost() {
        for terminal in [event(.failed), event(.cancelled), .applicationPresented("editor-window")] {
            var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
            policy.handle(event(), at: 10)
            policy.handle(event(.launched), at: 20)
            XCTAssertEqual(policy.pacingSuppression(at: 110), .init(primary: true, secondary: false))
            policy.handle(terminal, at: 120)
            XCTAssertEqual(policy.pacingSuppression(at: 120), .init(primary: false, secondary: false))
        }
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        policy.handle(event(), at: 10)
        policy.cancelAll()
        XCTAssertEqual(policy.pacingSuppression(at: 110), .init(primary: false, secondary: false))
        policy.handle(event(.launched), at: 111)
        XCTAssertEqual(policy.pacingSuppression(at: 111), .init(primary: false, secondary: false))
        policy.handle(event(.requested, "second"), at: 200)
        XCTAssertEqual(policy.pacingSuppression(at: 199), .init(primary: false, secondary: false))
    }

    func testAliasesAndUnrelatedPresentations() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        XCTAssertEqual(policy.handle(event(), at: 10), .requested)
        XCTAssertEqual(policy.handle(.applicationPresented("unrelated-window"), at: 11), .ignored)
        policy.handle(event(.launched), at: 12)
        for unrelated in ["org.gnome.Settings", "editor", "org.example.editor", "org.example.Editor.desktop"] {
            XCTAssertEqual(policy.handle(.applicationPresented(unrelated), at: 13), .ignored)
        }
        XCTAssertTrue(policy.isLatencySensitive(at: 20))
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 21), .presented)
        XCTAssertFalse(policy.isLatencySensitive(at: 21))
    }

    func testLaunchSuccessDoesNotMeanPresentedOrRenewTimeout() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        policy.handle(event(), at: 10)
        policy.handle(event(.launched), at: 99)
        policy.handle(event(.launched), at: 109)
        XCTAssertTrue(policy.isLatencySensitive(at: 109))
        XCTAssertFalse(policy.isLatencySensitive(at: 110))
        XCTAssertEqual(policy.handle(event(), at: 111), .ignored)
    }

    func testSlowLaunchSuppressesPacingWithoutExtendingPriorityQuantum() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100,
                                                lifecycleRetentionNanoseconds: 1_000)
        XCTAssertFalse(policy.isAwaitingPresentation(at: 0))
        policy.handle(event(), at: 10)
        policy.handle(event(.launched), at: 20)
        XCTAssertTrue(policy.isLatencySensitive(at: 109))
        XCTAssertFalse(policy.isLatencySensitive(at: 110))
        XCTAssertTrue(policy.isAwaitingPresentation(at: 110))
        policy.handle(.applicationPresented("unrelated-window"), at: 120)
        XCTAssertTrue(policy.isAwaitingPresentation(at: 120))
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 800), .presented)
        XCTAssertFalse(policy.isAwaitingPresentation(at: 800))
        XCTAssertFalse(policy.isLatencySensitive(at: 800))
    }

    func testPacingSuppressionEndsOnFailureCancellationTimeoutAndClockRollback() {
        for phase in [ApplicationLaunchEvent.Phase.failed, .cancelled] {
            var policy = ApplicationExecutionPolicy()
            policy.handle(event(), at: 10)
            XCTAssertTrue(policy.isAwaitingPresentation(at: 20))
            policy.handle(event(phase), at: 21)
            XCTAssertFalse(policy.isAwaitingPresentation(at: 21))
        }
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100,
                                                lifecycleRetentionNanoseconds: 1_000)
        policy.handle(event(), at: 10)
        policy.handle(event(.launched), at: 900)
        XCTAssertTrue(policy.isAwaitingPresentation(at: 1_009))
        XCTAssertFalse(policy.isAwaitingPresentation(at: 1_010))
        XCTAssertEqual(policy.handle(event(), at: 1_011), .ignored)
        XCTAssertFalse(policy.isAwaitingPresentation(at: 1_011))
        policy.handle(event(.requested, "second"), at: 2_000)
        XCTAssertFalse(policy.isAwaitingPresentation(at: 1_999))
        policy.handle(event(.requested, "third"), at: 3_000)
        policy.cancelAll()
        XCTAssertFalse(policy.isAwaitingPresentation(at: 3_001))
    }

    func testPresentationBeforeLaunchCallbackEndsPacingSuppression() {
        var policy = ApplicationExecutionPolicy()
        policy.handle(event(), at: 10)
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 20), .ignored)
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertFalse(policy.isAwaitingPresentation(at: 21))
        XCTAssertEqual(policy.handle(event(.launched), at: 22), .presented)
        XCTAssertFalse(policy.isAwaitingPresentation(at: 22))
    }

    func testLateSettingsPresentationAfterBoostDeadlineForStructuredAndLegacyRequests() {
        let second: UInt64 = 1_000_000_000
        for structured in [false, true] {
            var policy = ApplicationExecutionPolicy()
            let requested = event(.requested, "settings-late", desktop: "org.gnome.Settings.desktop",
                                  aliases: ["org.gnome.Settings", "gnome-control-center"])
            if structured {
                policy.handle(requested, at: 0)
                policy.handle(event(.launched, "settings-late", desktop: "org.gnome.Settings.desktop",
                                    aliases: ["org.gnome.Settings", "gnome-control-center"]), at: second)
            } else {
                policy.handle(.applicationLaunch("settings"), at: 0)
            }
            XCTAssertTrue(policy.isLatencySensitive(at: 12 * second - 1))
            XCTAssertFalse(policy.isLatencySensitive(at: 12 * second))
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertEqual(policy.handle(.applicationLaunch("settings"), at: 13 * second), .ignored)
            if structured { XCTAssertEqual(policy.handle(requested, at: 14 * second), .ignored) }
            XCTAssertEqual(policy.handle(.applicationPresented("unrelated-window"), at: 34 * second), .ignored)
            XCTAssertFalse(policy.isLatencySensitive(at: 34 * second))
            XCTAssertEqual(policy.handle(.applicationPresented("org.gnome.Settings"), at: 35 * second), .presented)
            XCTAssertEqual(policy.pendingCount, 0)
            XCTAssertFalse(policy.isLatencySensitive(at: 35 * second))
            if structured {
                XCTAssertEqual(policy.handle(requested, at: 36 * second), .ignored)
                XCTAssertEqual(policy.handle(.applicationLaunch("settings"), at: 37 * second), .ignored)
                XCTAssertFalse(policy.isLatencySensitive(at: 37 * second))
            }
        }
    }

    func testLateLaunchAndPresentationInEitherOrderDoNotReboost() {
        let second: UInt64 = 1_000_000_000
        for presentationFirst in [false, true] {
            var policy = ApplicationExecutionPolicy()
            policy.handle(event(), at: 0)
            XCTAssertFalse(policy.isLatencySensitive(at: 12 * second))
            let presented = GuestGraphicsTraceRecord.applicationPresented("editor-window")
            let first = presentationFirst ? presented : event(.launched)
            let last = presentationFirst ? event(.launched) : presented
            XCTAssertEqual(policy.handle(first, at: 34 * second), .ignored)
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertFalse(policy.isLatencySensitive(at: 34 * second))
            XCTAssertEqual(policy.handle(last, at: 35 * second), .presented)
            XCTAssertEqual(policy.pendingCount, 0)
            XCTAssertFalse(policy.isLatencySensitive(at: 35 * second))
        }
    }

    func testLateTerminalCallbacksDoNotCancelOrReboostNewerLaunch() {
        for phase in [ApplicationLaunchEvent.Phase.failed, .cancelled] {
            var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100, lifecycleRetentionNanoseconds: 1_000)
            policy.handle(event(), at: 0)
            XCTAssertFalse(policy.isLatencySensitive(at: 100))
            XCTAssertEqual(policy.handle(event(.requested, "newer"), at: 350), .requested)
            XCTAssertEqual(policy.handle(event(phase), at: 360), .ended)
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertTrue(policy.isLatencySensitive(at: 449))
            XCTAssertFalse(policy.isLatencySensitive(at: 450))
            XCTAssertEqual(policy.handle(event(phase), at: 460), .ignored)
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertFalse(policy.isLatencySensitive(at: 460))
            XCTAssertEqual(policy.handle(event(phase, "newer"), at: 470), .ended)
            XCTAssertEqual(policy.handle(event(.requested, "newer"), at: 480), .ignored)
            XCTAssertEqual(policy.pendingCount, 0)
            XCTAssertFalse(policy.isLatencySensitive(at: 480))
        }
    }

    func testLifecycleDeadlineIsIndependentAndNotExtendedByDuplicateCallbacks() {
        for presentationAt: UInt64 in [1_009, 1_010] {
            var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100, lifecycleRetentionNanoseconds: 1_000)
            policy.handle(event(), at: 10)
            policy.handle(event(.launched), at: 20)
            XCTAssertFalse(policy.isLatencySensitive(at: 110))
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertEqual(policy.handle(event(), at: 900), .ignored)
            XCTAssertEqual(policy.handle(event(.launched), at: 1_008), .ignored)
            XCTAssertFalse(policy.isLatencySensitive(at: 1_008))
            XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: presentationAt),
                           presentationAt == 1_009 ? .presented : .ignored)
            XCTAssertEqual(policy.pendingCount, 0)
            XCTAssertEqual(policy.handle(event(.launched), at: 1_011), .ignored)
            XCTAssertEqual(policy.handle(event(.failed), at: 1_012), .ignored)
            XCTAssertEqual(policy.handle(event(), at: 1_013), .ignored)
            XCTAssertFalse(policy.isLatencySensitive(at: 1_013))
        }
    }

    func testLegacyUpgradeDoesNotRestartBoostOrLifecycleRetention() {
        for upgradeAt: UInt64 in [30, 150] {
            var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100, lifecycleRetentionNanoseconds: 1_000)
            policy.handle(.applicationLaunch("settings"), at: 10)
            let request = event(.requested, "settings-upgrade", desktop: "org.gnome.Settings.desktop",
                                aliases: ["org.gnome.Settings", "gnome-control-center"])
            XCTAssertEqual(policy.handle(request, at: upgradeAt), .requested)
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertEqual(policy.isLatencySensitive(at: upgradeAt), upgradeAt < 110)
            XCTAssertEqual(policy.handle(.applicationLaunch("settings"), at: upgradeAt + 1), .ignored)
            XCTAssertFalse(policy.isLatencySensitive(at: 200))
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertFalse(policy.isLatencySensitive(at: 1_009))
            XCTAssertEqual(policy.pendingCount, 1)
            XCTAssertFalse(policy.isLatencySensitive(at: 1_010))
            XCTAssertEqual(policy.pendingCount, 0)
            XCTAssertEqual(policy.handle(request, at: 1_011), .ignored)
        }
    }

    func testReplayHistoryRemainsBoundedAndDuplicatesDoNotEvictRememberedTokens() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100, lifecycleRetentionNanoseconds: 1_000)
        for i in 0..<ApplicationExecutionPolicy.maximumRememberedTokens {
            policy.handle(event(.failed, "token-\(i)"), at: 0)
        }
        for _ in 0..<ApplicationExecutionPolicy.maximumRememberedTokens {
            XCTAssertEqual(policy.handle(event(.failed, "token-0"), at: 1_000), .ignored)
            XCTAssertEqual(policy.handle(event(.requested, "token-0"), at: 1_000), .ignored)
        }
        XCTAssertEqual(policy.pendingCount, 0)
        XCTAssertFalse(policy.isLatencySensitive(at: 1_000))
        // The 257th distinct token evicts only the oldest replay entry. This is
        // a bounded history, not an unbounded lifetime set of guest tokens.
        policy.handle(event(.failed, "overflow"), at: 1_001)
        XCTAssertEqual(policy.handle(event(.requested, "token-1"), at: 1_002), .ignored)
        XCTAssertEqual(policy.handle(event(.requested, "token-0"), at: 1_003), .requested)
        XCTAssertEqual(policy.pendingCount, 1)
    }

    func testRetainedLaunchExpiresOnClockWrapWithoutReboost() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100, lifecycleRetentionNanoseconds: 1_000)
        policy.handle(event(), at: UInt64.max - 500)
        policy.handle(event(.launched), at: UInt64.max - 499)
        XCTAssertFalse(policy.isLatencySensitive(at: UInt64.max))
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertEqual(policy.handle(event(), at: 0), .ignored)
        XCTAssertEqual(policy.pendingCount, 0)
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 1), .ignored)
        XCTAssertFalse(policy.isLatencySensitive(at: 1))
    }

    func testDuplicateRequestedDoesNotExtendDeadlineOrChangeIdentity() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        policy.handle(event(), at: 10)
        XCTAssertEqual(policy.handle(event(), at: 80), .ignored)
        XCTAssertEqual(policy.handle(event(aliases: ["wrong-app"]), at: 90), .ignored)
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertFalse(policy.isLatencySensitive(at: 110))
    }

    func testFailureAndCancellationAreTokenScopedIncludingLateFailure() {
        var policy = ApplicationExecutionPolicy()
        policy.handle(event(), at: 10)
        policy.handle(event(.requested, "launch-2"), at: 11)
        XCTAssertEqual(policy.handle(event(.failed), at: 12), .ended)
        XCTAssertEqual(policy.handle(event(.failed), at: 13), .ignored)
        XCTAssertEqual(policy.handle(event(.cancelled, "unknown"), at: 14), .ignored)
        XCTAssertEqual(policy.pendingCount, 1)
        XCTAssertEqual(policy.handle(event(.cancelled, "launch-2"), at: 15), .ended)
        XCTAssertFalse(policy.isLatencySensitive(at: 16))
        XCTAssertEqual(policy.handle(event(.launched), at: 17), .ignored)
        XCTAssertEqual(policy.handle(event(), at: 18), .ignored)
        policy.handle(event(.failed, "terminal-first"), at: 19)
        XCTAssertEqual(policy.handle(event(.requested, "terminal-first"), at: 20), .ignored)
    }

    func testMalformedIdentityCannotCancelKnownLaunch() {
        var policy = ApplicationExecutionPolicy()
        policy.handle(event(), at: 0)
        XCTAssertEqual(policy.handle(event(.failed, desktop: "other.desktop"), at: 1), .ignored)
        XCTAssertEqual(policy.handle(event(.cancelled, aliases: ["other"]), at: 2), .ignored)
        XCTAssertTrue(policy.isLatencySensitive(at: 3))
    }

    func testMultipleAppsAndSameAppInstancesStayIndependent() {
        var policy = ApplicationExecutionPolicy()
        policy.handle(event(), at: 0)
        policy.handle(event(.requested, "launch-2"), at: 1)
        policy.handle(event(.requested, "launch-3", desktop: "browser.desktop", aliases: ["browser"]), at: 2)
        policy.handle(event(.launched), at: 3)
        policy.handle(event(.launched, "launch-2"), at: 4)
        policy.handle(event(.launched, "launch-3", desktop: "browser.desktop", aliases: ["browser"]), at: 5)
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 6), .presented)
        XCTAssertEqual(policy.pendingCount, 2)
        XCTAssertEqual(policy.handle(event(.failed), at: 7), .ignored)
        policy.handle(.applicationPresented("browser"), at: 8)
        XCTAssertEqual(policy.pendingCount, 1)
        policy.handle(.applicationPresented("org.example.Editor"), at: 9)
        XCTAssertFalse(policy.isLatencySensitive(at: 10))
    }

    func testBoundedCapacityAndIndependentExpiry() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100, lifecycleRetentionNanoseconds: 1_000)
        for i in 0..<ApplicationExecutionPolicy.maximumPendingLaunches {
            XCTAssertEqual(policy.handle(event(.requested, "token-\(i)"), at: UInt64(i)), .requested)
        }
        XCTAssertEqual(policy.handle(event(.requested, "overflow"), at: 20), .ignored)
        XCTAssertEqual(policy.pendingCount, 16)
        XCTAssertTrue(policy.isLatencySensitive(at: 100))
        XCTAssertEqual(policy.pendingCount, 16)
        XCTAssertFalse(policy.isLatencySensitive(at: 115))
        XCTAssertEqual(policy.pendingCount, 16)
        XCTAssertEqual(policy.handle(event(.requested, "overflow"), at: 116), .ignored)
        XCTAssertEqual(policy.handle(event(.requested, "still-full"), at: 999), .ignored)
        XCTAssertFalse(policy.isLatencySensitive(at: 1_000))
        XCTAssertEqual(policy.pendingCount, 15)
        XCTAssertFalse(policy.isLatencySensitive(at: 1_015))
        XCTAssertEqual(policy.pendingCount, 0)
        XCTAssertEqual(policy.handle(event(.requested, "overflow"), at: 1_016), .ignored)
        XCTAssertEqual(policy.handle(event(.requested, "fresh"), at: 1_017), .requested)
        XCTAssertTrue(policy.isLatencySensitive(at: 1_017))
    }

    func testTimeBoundariesAndCancellation() {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        policy.handle(event(), at: UInt64.max - 50)
        XCTAssertTrue(policy.isLatencySensitive(at: UInt64.max))
        XCTAssertFalse(policy.isLatencySensitive(at: 0))
        XCTAssertEqual(policy.pendingCount, 0)
        XCTAssertEqual(policy.handle(event(), at: 0), .ignored)
        policy.handle(event(.requested, "another"), at: 20)
        policy.cancelAll()
        XCTAssertFalse(policy.isLatencySensitive(at: 21))
        XCTAssertEqual(policy.handle(event(.requested, "another"), at: 22), .ignored)
        XCTAssertEqual(ApplicationExecutionPolicy().watchdogNanoseconds, 12_000_000_000)
        XCTAssertEqual(ApplicationExecutionPolicy(watchdogNanoseconds: .max).watchdogNanoseconds, 15_000_000_000)
        XCTAssertEqual(ApplicationExecutionPolicy().lifecycleRetentionNanoseconds, 120_000_000_000)
        XCTAssertEqual(ApplicationExecutionPolicy(lifecycleRetentionNanoseconds: .max).lifecycleRetentionNanoseconds,
                       120_000_000_000)
        XCTAssertEqual(ApplicationExecutionPolicy(watchdogNanoseconds: 100, lifecycleRetentionNanoseconds: 0)
            .lifecycleRetentionNanoseconds, 100)
    }

    func testLegacySettingsAndStructuredRequestDoNotDoubleBoostInEitherOrder() {
        let settings = event(.requested, "settings-1", desktop: "org.gnome.Settings.desktop",
                             aliases: ["org.gnome.Settings", "gnome-control-center"])
        for legacyFirst in [false, true] {
            var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
            if legacyFirst { policy.handle(.applicationLaunch("settings"), at: 0) }
            policy.handle(settings, at: 1)
            XCTAssertEqual(policy.handle(.applicationLaunch("settings"), at: 2), .ignored)
            XCTAssertEqual(policy.pendingCount, 1)
            policy.handle(event(.launched, "settings-1", desktop: "org.gnome.Settings.desktop",
                                aliases: ["org.gnome.Settings", "gnome-control-center"]), at: 3)
            policy.handle(.applicationPresented("gnome-control-center"), at: 4)
            XCTAssertEqual(policy.handle(.applicationLaunch("settings"), at: 5), .ignored)
            XCTAssertFalse(policy.isLatencySensitive(at: 5))
        }
        var legacy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        legacy.handle(.applicationLaunch("settings"), at: 0)
        XCTAssertEqual(legacy.handle(.applicationPresented("org.gnome.Settings"), at: 1), .presented)
        legacy.handle(.applicationLaunch("org.example.Viewer.desktop"), at: 2)
        XCTAssertEqual(legacy.handle(.applicationPresented("org.example.Viewer"), at: 3), .presented)
    }

    func testTraceDisabledPartialUARTAndResynchronization() throws {
        var decoder = GuestGraphicsTraceDecoder()
        var policy = ApplicationExecutionPolicy()
        let bytes = try wire(event()) + wire(event(.launched)) + Array("\u{1e}PINECONE_APP_PRESENTED editor-window\r\n".utf8)
        var effects: [ApplicationExecutionPolicy.Effect] = []
        for byte in bytes {
            effects += decoder.appendRecords([byte]).map { policy.handle($0, at: 1) }
        }
        XCTAssertEqual(effects, [.requested, .ignored, .presented])
        XCTAssertFalse(policy.isLatencySensitive(at: 2))
        let broken = Array((String(repeating: "x", count: 4000) + "\u{1e}PINECONE_APP_LIFECYCLE {\"bad\":").utf8)
        XCTAssertTrue(decoder.appendRecords(broken).isEmpty)
        XCTAssertEqual(decoder.appendRecords(try wire(event())), [event()])
    }

    func testPresentationBeforeDBusLaunchCallbackAndExistingWindowActivation() {
        var policy = ApplicationExecutionPolicy()
        policy.handle(event(), at: 0)
        XCTAssertEqual(policy.handle(.applicationPresented("editor-window"), at: 1), .ignored)
        XCTAssertFalse(policy.isLatencySensitive(at: 1))
        XCTAssertEqual(policy.handle(event(.launched), at: 2), .presented)
        XCTAssertFalse(policy.isLatencySensitive(at: 3))
        // Existing-window activation emits the same structured pair, including
        // the actual toplevel ID, without depending on a GIO launched signal.
        policy.handle(event(.requested, "activation", aliases: ["actual-wayland-id"]), at: 4)
        policy.handle(event(.launched, "activation", aliases: ["actual-wayland-id"]), at: 4)
        XCTAssertEqual(policy.handle(.applicationPresented("actual-wayland-id"), at: 5), .presented)
        XCTAssertFalse(policy.isLatencySensitive(at: 6))
        policy.handle(event(.requested, "missing-callback"), at: 7)
        policy.handle(.applicationPresented("editor-window"), at: 8)
        XCTAssertFalse(policy.isLatencySensitive(at: 12_000_000_007))
    }

    func testMalformedAndBoundedRecordsFailClosed() throws {
        var decoder = GuestGraphicsTraceDecoder()
        let invalid: [ApplicationLaunchEvent] = [
            .init(version: 2, event: .requested, token: "t", desktopID: "a", appIDs: ["a"]),
            .init(event: .requested, token: "", desktopID: "a", appIDs: ["a"]),
            .init(event: .requested, token: "t", desktopID: "../../a", appIDs: ["a"]),
            .init(event: .requested, token: "t", desktopID: "a", appIDs: []),
            .init(event: .requested, token: "t", desktopID: "a", appIDs: ["a", "a"]),
            .init(event: .requested, token: "t", desktopID: "a", appIDs: (0..<9).map { "app-\($0)" }),
        ] + ["bad app", "bad/ID", "bad\nID", "bad\u{1e}ID", "bad\"ID", "caf\u{e9}", String(repeating: "x", count: 96)].map {
            .init(event: .requested, token: "t", desktopID: "a", appIDs: [$0])
        }
        for item in invalid {
            XCTAssertTrue(decoder.appendRecords(try wire(.applicationLifecycle(item))).isEmpty)
            var policy = ApplicationExecutionPolicy()
            XCTAssertEqual(policy.handle(.applicationLifecycle(item), at: 0), .ignored)
        }
        for json in ["{}", "{", "{\"event\":\"unexpected\"}", String(repeating: "x", count: 2049)] {
            XCTAssertTrue(decoder.appendRecords(Array(("\u{1e}PINECONE_APP_LIFECYCLE " + json + "\n").utf8)).isEmpty)
        }
        XCTAssertTrue(decoder.appendRecords(Array("Pinecone app launch requested: bad app\n".utf8)).isEmpty)
        XCTAssertTrue(decoder.appendRecords(Array("\u{1e}PINECONE_APP_PRESENTED bad\rid\n".utf8)).isEmpty)
        var injected = try wire(event())
        let index = try XCTUnwrap(injected.firstIndex(of: 45))
        injected.insert(13, at: index)
        XCTAssertTrue(decoder.appendRecords(injected).isEmpty)
        XCTAssertEqual(decoder.appendRecords(try wire(event(aliases: [String(repeating: "a", count: 95)]))).count, 1)
    }

    func testOptionalGraphicsRecordsCannotCompleteOrExtendLaunch() throws {
        var policy = ApplicationExecutionPolicy(watchdogNanoseconds: 100)
        var decoder = GuestGraphicsTraceDecoder()
        policy.handle(event(), at: 0)
        policy.handle(event(.launched), at: 1)
        for phase in ["present", "dropped", "touch"] {
            let records = decoder.appendRecords(Array("PINECONE_TRACE {\"event\":\"\(phase)\",\"guestUs\":999,\"apps\":[\"editor-window\"]}\n".utf8))
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(policy.handle(try XCTUnwrap(records.first), at: 99), .ignored)
        }
        XCTAssertFalse(policy.isLatencySensitive(at: 100))
    }
}
