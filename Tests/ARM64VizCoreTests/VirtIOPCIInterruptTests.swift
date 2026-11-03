import XCTest
@testable import ARM64VizCore

final class VirtIOPCIInterruptTests: XCTestCase {
    func testPCIISRReadAtomicallyConsumesPendingInterruptCauses() throws {
        let interrupts = SimpleInterruptController()
        let line: UInt32 = 71
        interrupts.setEnabled(line: line, enabled: true)
        let device = VirtualVirtIODevice(
            name: "virtio_block_interrupt_test",
            kind: .block,
            base: 0x0a00_0000,
            interruptLine: line,
            interruptController: interrupts,
            storageSize: 512
        )
        let transport = VirtIOPCIModernTransport(
            name: "virtio_pci_interrupt_test",
            base: 0x3100_0000,
            device: device
        )

        // Config changes and used-buffer notifications share the same ISR
        // byte and device lock.  A config interrupt is sufficient to verify
        // the transport performs the required atomic read-and-clear operation.
        try device.replaceStorage(Array(repeating: 0, count: 512))

        XCTAssertEqual(interrupts.peekPending(), line)
        XCTAssertEqual(
            try transport.read(offset: 0x2000, width: .byte),
            UInt64(VirtualVirtIODevice.configChangeInterrupt)
        )
        XCTAssertEqual(try device.read(offset: 0x060, width: .word), 0)
        XCTAssertNil(interrupts.peekPending())
        XCTAssertEqual(try transport.read(offset: 0x2000, width: .byte), 0)
    }
}
