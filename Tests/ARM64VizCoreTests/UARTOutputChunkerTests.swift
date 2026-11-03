import XCTest
@testable import ARM64VizCore

final class UARTOutputChunkerTests: XCTestCase {
    func testFlushesCompleteLineAsOneChunk() {
        let chunker = UARTOutputChunker(maximumChunkBytes: 64)
        XCTAssertNil(chunker.append(0x61))
        XCTAssertNil(chunker.append(0x62))
        XCTAssertEqual(chunker.append(0x0a), Array("ab\n".utf8))
        XCTAssertEqual(chunker.drain(), [])
    }

    func testBoundsLongOutputWithoutNewline() {
        let chunker = UARTOutputChunker(maximumChunkBytes: 4)
        XCTAssertNil(chunker.append(1))
        XCTAssertNil(chunker.append(2))
        XCTAssertNil(chunker.append(3))
        XCTAssertEqual(chunker.append(4), [1, 2, 3, 4])
        XCTAssertNil(chunker.append(5))
        XCTAssertEqual(chunker.drain(), [5])
    }

    func testDrainPublishesPartialPromptOnlyOnce() {
        let chunker = UARTOutputChunker()
        for byte in "console:/ # ".utf8 {
            XCTAssertNil(chunker.append(byte))
        }
        XCTAssertEqual(chunker.drain(), Array("console:/ # ".utf8))
        XCTAssertEqual(chunker.drain(), [])
    }
}
