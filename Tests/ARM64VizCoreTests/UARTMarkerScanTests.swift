import XCTest
@testable import ARM64VizCore

final class UARTMarkerScanTests: XCTestCase {
    func testMarkerSplitAcrossWritesAndBatchedOutput() throws {
        let uart = VirtualUART(base: 0x1000)
        let marker = Array("ready ✓".utf8)
        var scanned = 0
        for byte in "unrelated log\nready ".utf8 {
            try uart.write(offset: 0, width: .word, value: UInt64(byte))
            XCTAssertFalse(uart.containsOutput(marker, scannedCount: &scanned))
        }
        // Other vCPUs can append several bytes between primary CPU checks.
        for byte in "✓\nafter the marker".utf8 {
            try uart.write(offset: 0, width: .word, value: UInt64(byte))
        }
        XCTAssertTrue(uart.containsOutput(marker, scannedCount: &scanned))
        XCTAssertEqual(scanned, uart.outputBytes.count)
    }

    func testNonmatchingScanAdvancesWithoutRevisitingOldMarker() throws {
        let uart = VirtualUART(base: 0x1000)
        var scanned = 0
        for byte in "old marker\n".utf8 {
            try uart.write(offset: 0, width: .word, value: UInt64(byte))
        }
        XCTAssertFalse(uart.containsOutput(Array("new".utf8), scannedCount: &scanned))
        try uart.write(offset: 0, width: .word, value: 120)
        XCTAssertFalse(uart.containsOutput(Array("old".utf8), scannedCount: &scanned))
        scanned = 0
        XCTAssertTrue(uart.containsOutput(Array("old".utf8), scannedCount: &scanned))
    }
}
