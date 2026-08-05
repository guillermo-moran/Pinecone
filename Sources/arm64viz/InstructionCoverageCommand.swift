import ARM64VizCore
import Foundation

enum InstructionCoverageCommand {
    private struct Options {
        var paths: [String] = []
        var sampleLimit = 4
        var maxOpcodes = 50
        var emitJSON = false
        var expandAPKs = true
    }

    static func run(arguments: [String]) throws {
        let options = try parse(arguments)
        guard !options.paths.isEmpty else {
            throw VMError.deviceError("audit-instructions requires at least one ELF, directory, or APK path")
        }

        let fileManager = FileManager.default
        var scanInputs: [ARM64InstructionScanInput] = []
        var archives: [URL] = []
        for path in options.paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw ARM64InstructionCoverageError.missingInput(url.path)
            }
            if options.expandAPKs {
                let discovered = try discoverAPKs(at: url, isDirectory: isDirectory.boolValue)
                if !discovered.isEmpty {
                    archives.append(contentsOf: discovered)
                    continue
                }
            }
            scanInputs.append(ARM64InstructionScanInput(url: url))
        }

        var temporaryRoot: URL?
        if !archives.isEmpty {
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("arm64viz-instruction-audit-\(UUID().uuidString)")
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            temporaryRoot = root
            try extractAPKs(archives.sorted { $0.path < $1.path }, into: root)
            scanInputs.append(ARM64InstructionScanInput(url: root, label: "rootfs"))
        }
        defer {
            if let temporaryRoot {
                try? fileManager.removeItem(at: temporaryRoot)
            }
        }

        let scanner = ARM64InstructionCoverageScanner(sampleLimit: options.sampleLimit)
        let report = try scanner.scan(scanInputs)
        if options.emitJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report))
            print("")
            return
        }
        printHumanReport(report, maxOpcodes: options.maxOpcodes)
    }

    private static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--json":
                options.emitJSON = true
            case "--no-expand-apks":
                options.expandAPKs = false
            case "--sample-limit", "--max-opcodes":
                let flag = arguments[index]
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      value >= 0 else {
                    throw VMError.deviceError("\(flag) requires a non-negative integer")
                }
                if flag == "--sample-limit" {
                    options.sampleLimit = value
                } else {
                    options.maxOpcodes = value
                }
            default:
                if arguments[index].hasPrefix("--") {
                    throw VMError.deviceError("unknown audit-instructions option: \(arguments[index])")
                }
                options.paths.append(arguments[index])
            }
            index += 1
        }
        return options
    }

    private static func discoverAPKs(at url: URL, isDirectory: Bool) throws -> [URL] {
        if !isDirectory {
            return url.pathExtension.lowercased() == "apk" ? [url] : []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ARM64InstructionCoverageError.unreadableDirectory(url.path)
        }
        var archives: [URL] = []
        for case let child as URL in enumerator where child.pathExtension.lowercased() == "apk" {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                archives.append(child)
            }
        }
        return archives
    }

    private static func extractAPKs(_ archives: [URL], into root: URL) throws {
        for (index, archive) in archives.enumerated() {
            if index == 0 || (index + 1).isMultiple(of: 25) || index + 1 == archives.count {
                fputs("[arm64viz] staging APK \(index + 1)/\(archives.count)\r", stderr)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["-xf", archive.path, "-C", root.path]
            process.standardOutput = FileHandle.nullDevice
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let detail = String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw VMError.deviceError(
                    "failed to extract \(archive.path)\(detail.isEmpty ? "" : ": \(detail)")"
                )
            }
        }
        if !archives.isEmpty {
            fputs("\n", stderr)
        }
    }

    private static func printHumanReport(
        _ report: ARM64InstructionCoverageReport,
        maxOpcodes: Int
    ) {
        let visible = Array(report.unsupportedOpcodes.prefix(maxOpcodes))
        let disassembly = disassemble(visible.map(\.opcode))
        print("ARM64 native instruction coverage")
        print("files: \(report.scannedFiles) (ARM64 ELF: \(report.arm64ELFFiles))")
        print("executable sections: \(report.executableSections)")
        print("instruction words: \(report.instructionWords)")
        print(String(
            format: "decoded: %llu (%.4f%%)",
            report.decodedInstructionWords,
            report.decodedPercent
        ))
        print("unsupported: \(report.unsupportedInstructionWords) words, \(report.unsupportedOpcodes.count) unique opcodes")
        if !report.decodedKinds.isEmpty {
            print("most frequent decoded operation kinds:")
            for summary in report.decodedKinds.prefix(25) {
                print("  kind \(summary.kind): \(summary.occurrences)")
            }
        }
        if !report.malformedELFFiles.isEmpty {
            print("malformed ELF files: \(report.malformedELFFiles.count)")
        }

        if !disassembly.isEmpty {
            var families: [String: UInt64] = [:]
            for summary in visible {
                guard let assembly = disassembly[summary.opcode] else { continue }
                let mnemonic = assembly.split(whereSeparator: { $0.isWhitespace }).first
                    .map(String.init) ?? "<unknown>"
                families[mnemonic, default: 0] += summary.occurrences
            }
            print("unsupported families among displayed opcodes:")
            for (mnemonic, count) in families.sorted(by: {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }).prefix(20) {
                print("  \(mnemonic): \(count)")
            }
        }

        for summary in visible {
            let assembly = disassembly[summary.opcode].map { "  \($0)" } ?? ""
            print("\n\(summary.opcode)  count=\(summary.occurrences) files=\(summary.fileCount)\(assembly)")
            for sample in summary.samples {
                print("  \(sample)")
            }
        }
        let hidden = report.unsupportedOpcodes.count - visible.count
        if hidden > 0 {
            print("\n... \(hidden) additional unsupported opcodes; increase --max-opcodes or use --json")
        }
    }

    private static func disassemble(_ opcodes: [String]) -> [String: String] {
        let candidates = [
            ProcessInfo.processInfo.environment["LLVM_MC"],
            "/opt/homebrew/opt/llvm/bin/llvm-mc",
            "/usr/local/opt/llvm/bin/llvm-mc"
        ].compactMap { $0 }
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }), !opcodes.isEmpty else {
            return [:]
        }

        return disassemble(opcodes, executable: executable)
    }

    private static func disassemble(
        _ opcodes: [String],
        executable: String
    ) -> [String: String] {
        guard !opcodes.isEmpty else { return [:] }

        let input = opcodes.compactMap { text -> String? in
            guard let raw = UInt32(text.dropFirst(2), radix: 16) else { return nil }
            return (0..<4).map {
                String(format: "0x%02x", (raw >> UInt32($0 * 8)) & 0xff)
            }.joined(separator: " ")
        }.joined(separator: "\n") + "\n"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-triple=aarch64", "-mattr=+v8.5a", "-disassemble"]
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            standardInput.fileHandleForWriting.write(Data(input.utf8))
            try standardInput.fileHandleForWriting.close()
            let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let lines = String(decoding: output, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.count == opcodes.count {
                return Dictionary(uniqueKeysWithValues: zip(opcodes, lines))
            }
            guard opcodes.count > 1 else { return [:] }
            let midpoint = opcodes.count / 2
            var result = disassemble(
                Array(opcodes[..<midpoint]),
                executable: executable
            )
            result.merge(disassemble(
                Array(opcodes[midpoint...]),
                executable: executable
            )) { current, _ in current }
            return result
        } catch {
            return [:]
        }
    }
}
