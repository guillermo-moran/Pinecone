import XCTest
@testable import ARM64VizCore

final class InteractionExecutionPolicyTests: XCTestCase {
    func testControlMessagesAreHiddenWithoutDelayingShellPrompt() {
        var filter = GuestControlConsoleFilter()
        XCTAssertEqual(String(decoding: filter.append(Array("root # ".utf8)), as: UTF8.self), "root # ")
        XCTAssertEqual(filter.append(Array("\n\u{1e}PINECONE_APP_PRE".utf8)), [10])
        XCTAssertEqual(filter.append(Array("SENTED org.gnome.Settings\r\n".utf8)), [])
        XCTAssertEqual(String(decoding: filter.append(Array("Phosh ready\n".utf8)), as: UTF8.self), "Phosh ready\n")
        XCTAssertEqual(String(decoding: filter.append(Array("P".utf8)), as: UTF8.self), "P")
        XCTAssertEqual(filter.append(Array("\u{1e}PINECONE_APP_PRESENTED org.gnome.Settings\n".utf8)), [])
    }
    func testFirstFrameDoesNotEndGestureOrAnimation() {
        var policy = InteractionExecutionPolicy(watchdogNanoseconds: 5_000, settleNanoseconds: 250)
        policy.input(at: 100, isDown: true)
        policy.frame(at: 110)
        XCTAssertTrue(policy.isLatencySensitive(at: 500))
        policy.input(at: 510, isDown: false)
        policy.frame(at: 520)
        XCTAssertTrue(policy.isLatencySensitive(at: 521))
        policy.frame(at: 700)
        XCTAssertTrue(policy.isLatencySensitive(at: 940))
        XCTAssertFalse(policy.isLatencySensitive(at: 951))
    }

    func testUnrelatedFramesCannotRenewWatchdogForever() {
        var policy = InteractionExecutionPolicy(watchdogNanoseconds: 500, settleNanoseconds: 250)
        policy.input(at: 100, isDown: false)
        policy.frame(at: 550)
        XCTAssertFalse(policy.isLatencySensitive(at: 600))
        policy.frame(at: 601)
        XCTAssertFalse(policy.isLatencySensitive(at: 602))
        policy.input(at: 700, isDown: true)
        XCTAssertTrue(policy.isLatencySensitive(at: 701))
    }

    func testMissingFramesAndClockBoundaries() {
        var policy = InteractionExecutionPolicy(watchdogNanoseconds: 500)
        XCTAssertFalse(policy.isLatencySensitive(at: 0))
        policy.input(at: UInt64.max - 400, isDown: false)
        XCTAssertTrue(policy.isLatencySensitive(at: UInt64.max))
        XCTAssertFalse(policy.isLatencySensitive(at: 0))
    }

    func testControlPresentationIsIndependentOfTraceAndPreservesOrder() {
        var decoder = GuestGraphicsTraceDecoder()
        XCTAssertTrue(decoder.appendRecords(Array("\u{1e}PINECONE_APP_PRE".utf8)).isEmpty)
        let records = decoder.appendRecords(Array(("SENTED org.gnome.Settings\r\n" +
            "Pinecone app launch requested: settings\n" +
            "\u{1e}PINECONE_APP_PRESENTED org.gnome.Settings\n").utf8))
        XCTAssertEqual(records, [.applicationPresented("org.gnome.Settings"),
            .applicationLaunch("settings"), .applicationPresented("org.gnome.Settings")])
        XCTAssertTrue(decoder.appendRecords(Array("\u{1e}PINECONE_APP_PRESENTED invalid app\n".utf8)).isEmpty)
        XCTAssertTrue(decoder.appendRecords(Array("\u{1e}PINECONE_APP_PRESENTED \n".utf8)).isEmpty)
    }
}
