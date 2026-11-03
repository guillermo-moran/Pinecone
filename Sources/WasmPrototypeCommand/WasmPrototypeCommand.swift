#if os(macOS)
import AppKit
import ARM64VizCore
import Foundation

@main
struct WasmPrototypeCommand {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let host = WebKitWasmPrototype()
        let window = NSWindow(contentRect:NSRect(x:40,y:40,width:520,height:180),
            styleMask:[.titled,.closable], backing:.buffered, defer:false)
        window.title = "Pinecone WebKit execution probe"
        window.contentView = host.webView
        window.makeKeyAndOrderFront(nil)
        Task { @MainActor in
            do {
                let arguments = Array(CommandLine.arguments.dropFirst())
                let count: UInt32
                if let flag = arguments.firstIndex(of:"--blocks"), flag + 1 < arguments.count,
                   let value = UInt32(arguments[flag+1]), value <= 100_000_000 { count = value }
                else { count = 2_000_000 }
                let program = try ARM64WasmProgram.sample()
                let registers = WasmPrototypeReference.sampleRegisters()
                if arguments.contains("--self-test") {
                    let summary = try await selfTest(host)
                    print(summary)
                    application.terminate(nil)
                    return
                }
                let reference = try WasmPrototypeReference.execute(program, blocks:count, registers:registers)
                try await host.load()
                fputs("WASM_EXECUTION_BEGIN\n", stderr)
                let report = try await host.run(program, blocks:count, registers:registers,
                    memorySeeds:[WasmPrototypeReference.codeSeed(program)])
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                struct Output: Encodable {
                    let matched: Bool
                    let guestInstructionsPerRound: UInt64
                    let reference: WasmPrototypeReferenceResult
                    let webKit: WasmPrototypeReport
                }
                let output = Output(matched:reference.matches(report), guestInstructionsPerRound:UInt64(count)*5,
                    reference:reference, webKit:report)
                FileHandle.standardOutput.write(try encoder.encode(output)); print("")
                if !output.matched { throw ARM64WasmError.invalid("Translated Wasm result differs from native interpreter") }
                if arguments.contains("--hold") { try await Task.sleep(nanoseconds:20_000_000_000) }
                application.terminate(nil)
            } catch {
                fputs("wasm-prototype: \(error)\n", stderr)
                exit(1)
            }
        }
        application.run()
        withExtendedLifetime(window) {}
    }

    @MainActor private static func selfTest(_ host: WebKitWasmPrototype) async throws -> String {
        func loop(_ body: [UInt32]) -> [UInt32] {
            body + [0x14000000 | (UInt32(truncatingIfNeeded: -body.count) & 0x03ffffff)]
        }
        let programs: [[UInt32]] = [
            try ARM64WasmProgram.sample().words,
            loop([0x11000400, 0x51000804, 0x528abcd5, 0x72a24695, 0xaa000085]),
            loop([0x910043ff, 0xd1000be7, 0xca00001f, 0xd503201f]),
            loop([0x39000020, 0x39400022, 0x79000420, 0x79400423]),
            loop([0xb9000020, 0xb9400022, 0xf9000420, 0xf9400423]),
            loop([0xf900003f, 0xf940003f])
        ]
        var cases = 0
        for words in programs {
            let p = try ARM64WasmProgram(words:words)
            for blocks: UInt32 in [0,1,8,31] {
                var registers = WasmPrototypeReference.sampleRegisters()
                registers[1] = 0x2001 // unaligned scalar loads/stores
                let reference = try WasmPrototypeReference.execute(p, blocks:blocks, registers:registers)
                let report = try await host.run(p, blocks:blocks, registers:registers)
                guard reference.matches(report) else {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    fputs("reference: \(String(decoding:try encoder.encode(reference),as:UTF8.self))\n",stderr)
                    fputs("wasm: \(String(decoding:try encoder.encode(report),as:UTF8.self))\n",stderr)
                    throw ARM64WasmError.invalid("Differential failure at case \(cases)")
                }
                cases += 1
            }
        }
        for address: UInt64 in [0x1_0000_2000, 65536 - 7, 0x1000] {
            let p = try ARM64WasmProgram.sample()
            var registers = WasmPrototypeReference.sampleRegisters(); registers[1] = address
            let report = try await host.run(p, blocks:1, registers:registers)
            guard report.trapped != nil, report.pc == "0000000000001004",
                  report.retiredInstructions == "0000000000000001" else {
                throw ARM64WasmError.invalid("Expected precise high-address/OOB/self-modifying-store rejection")
            }
            cases += 1
        }
        let p = try ARM64WasmProgram.sample()
        let registers = WasmPrototypeReference.sampleRegisters()
        let execution = Task { @MainActor in try await host.run(p, blocks:100_000_000, registers:registers) }
        try await Task.sleep(nanoseconds:50_000_000)
        execution.cancel()
        var cancelled = false
        do {
            _ = try await execution.value
        } catch {
            if error is CancellationError || String(describing:error) == "Prototype cancelled" { cancelled = true }
            else { throw error }
        }
        guard cancelled else { throw ARM64WasmError.invalid("Cancellation did not stop the worker") }
        let restarted = try await host.run(p, blocks:8, registers:registers)
        let reference = try WasmPrototypeReference.execute(p, blocks:8, registers:registers)
        guard reference.matches(restarted) else { throw ARM64WasmError.invalid("Worker did not restart after cancellation") }
        cases += 1
        return "WebKit executed \(cases) translated/reference and memory-trap cases successfully"
    }
}
#else
@main
struct WasmPrototypeCommand {
    static func main() { fatalError("The wasm-prototype CLI requires macOS; use the prototype screen on iOS") }
}
#endif
