import ARM64VizNative
import Foundation

public struct ARM64InstructionScanInput: Sendable {
    public let url: URL
    public let label: String

    public init(url: URL, label: String? = nil) {
        self.url = url
        self.label = label ?? url.path
    }
}

public struct ARM64UnsupportedInstructionSummary: Codable, Equatable, Sendable {
    public let opcode: String
    public let occurrences: UInt64
    public let fileCount: Int
    public let samples: [String]
}

public struct ARM64DecodedInstructionKindSummary: Codable, Equatable, Sendable {
    public let kind: UInt16
    public let occurrences: UInt64
}

public struct ARM64InstructionCoverageReport: Codable, Equatable, Sendable {
    public let scannedFiles: Int
    public let arm64ELFFiles: Int
    public let executableSections: Int
    public let instructionWords: UInt64
    public let decodedInstructionWords: UInt64
    public let unsupportedInstructionWords: UInt64
    public let malformedELFFiles: [String]
    public let decodedKinds: [ARM64DecodedInstructionKindSummary]
    public let unsupportedOpcodes: [ARM64UnsupportedInstructionSummary]

    public var decodedPercent: Double {
        guard instructionWords != 0 else { return 100 }
        return Double(decodedInstructionWords) * 100 / Double(instructionWords)
    }
}

public enum ARM64InstructionCoverageError: Error, CustomStringConvertible {
    case missingInput(String)
    case unreadableDirectory(String)

    public var description: String {
        switch self {
        case .missingInput(let path):
            return "instruction coverage input does not exist: \(path)"
        case .unreadableDirectory(let path):
            return "cannot enumerate instruction coverage directory: \(path)"
        }
    }
}

public final class ARM64InstructionCoverageScanner {
    private struct UnsupportedAccumulator {
        var occurrences: UInt64 = 0
        var files: Set<String> = []
        var samples: [String] = []
    }

    private struct MutableReport {
        var scannedFiles = 0
        var arm64ELFFiles = 0
        var executableSections = 0
        var instructionWords: UInt64 = 0
        var decodedInstructionWords: UInt64 = 0
        var unsupportedInstructionWords: UInt64 = 0
        var malformedELFFiles: [String] = []
        var decodedKinds: [UInt16: UInt64] = [:]
        var unsupported: [UInt32: UnsupportedAccumulator] = [:]
    }

    private struct ExecutableSection {
        let name: String
        let fileOffset: Int
        let byteCount: Int
        let virtualAddress: UInt64
    }

    private enum ELFParseResult {
        case notELF
        case notARM64
        case malformed
        case sections([ExecutableSection])
    }

    private let fileManager: FileManager
    private let sampleLimit: Int

    public init(sampleLimit: Int = 4, fileManager: FileManager = .default) {
        self.sampleLimit = max(0, sampleLimit)
        self.fileManager = fileManager
    }

    public func scan(_ inputs: [ARM64InstructionScanInput]) throws -> ARM64InstructionCoverageReport {
        var report = MutableReport()
        for input in inputs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: input.url.path, isDirectory: &isDirectory) else {
                throw ARM64InstructionCoverageError.missingInput(input.url.path)
            }
            if isDirectory.boolValue {
                try scanDirectory(input, report: &report)
            } else {
                try scanFile(input.url, displayPath: input.label, report: &report)
            }
        }

        let unsupportedOpcodes = report.unsupported.map { opcode, accumulator in
            ARM64UnsupportedInstructionSummary(
                opcode: String(format: "0x%08x", opcode),
                occurrences: accumulator.occurrences,
                fileCount: accumulator.files.count,
                samples: accumulator.samples
            )
        }.sorted {
            if $0.occurrences != $1.occurrences {
                return $0.occurrences > $1.occurrences
            }
            return $0.opcode < $1.opcode
        }
        let decodedKinds = report.decodedKinds.map { kind, occurrences in
            ARM64DecodedInstructionKindSummary(kind: kind, occurrences: occurrences)
        }.sorted {
            if $0.occurrences != $1.occurrences {
                return $0.occurrences > $1.occurrences
            }
            return $0.kind < $1.kind
        }

        return ARM64InstructionCoverageReport(
            scannedFiles: report.scannedFiles,
            arm64ELFFiles: report.arm64ELFFiles,
            executableSections: report.executableSections,
            instructionWords: report.instructionWords,
            decodedInstructionWords: report.decodedInstructionWords,
            unsupportedInstructionWords: report.unsupportedInstructionWords,
            malformedELFFiles: report.malformedELFFiles.sorted(),
            decodedKinds: decodedKinds,
            unsupportedOpcodes: unsupportedOpcodes
        )
    }

    private func scanDirectory(
        _ input: ARM64InstructionScanInput,
        report: inout MutableReport
    ) throws {
        let resolvedRoot = input.url.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: input.url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw ARM64InstructionCoverageError.unreadableDirectory(input.url.path)
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                continue
            }
            let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            let relativePath = resolvedFile.hasPrefix(resolvedRoot + "/")
                ? String(resolvedFile.dropFirst(resolvedRoot.count))
                : "/" + fileURL.lastPathComponent
            let separator = relativePath.hasPrefix("/") ? "" : "/"
            try scanFile(
                fileURL,
                displayPath: input.label + separator + relativePath,
                report: &report
            )
        }
    }

    private func scanFile(
        _ url: URL,
        displayPath: String,
        report: inout MutableReport
    ) throws {
        report.scannedFiles += 1
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            return
        }

        switch parseExecutableSections(data) {
        case .notELF, .notARM64:
            return
        case .malformed:
            report.malformedELFFiles.append(displayPath)
            return
        case .sections(let sections):
            report.arm64ELFFiles += 1
            report.executableSections += sections.count
            scanInstructions(
                data,
                sections: sections,
                displayPath: displayPath,
                report: &report
            )
        }
    }

    private func scanInstructions(
        _ data: Data,
        sections: [ExecutableSection],
        displayPath: String,
        report: inout MutableReport
    ) {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for section in sections {
                let instructionCount = section.byteCount / 4
                for index in 0..<instructionCount {
                    let fileOffset = section.fileOffset + index * 4
                    let instruction = UInt32(bytes[fileOffset])
                        | (UInt32(bytes[fileOffset + 1]) << 8)
                        | (UInt32(bytes[fileOffset + 2]) << 16)
                        | (UInt32(bytes[fileOffset + 3]) << 24)
                    report.instructionWords += 1
                    var decoded = AVZNativeInstruction()
                    if avz_native_decode_instruction(instruction, &decoded) != 0 {
                        report.decodedInstructionWords += 1
                        report.decodedKinds[decoded.kind, default: 0] += 1
                        continue
                    }

                    report.unsupportedInstructionWords += 1
                    var accumulator = report.unsupported[instruction, default: UnsupportedAccumulator()]
                    accumulator.occurrences += 1
                    accumulator.files.insert(displayPath)
                    if accumulator.samples.count < sampleLimit {
                        let address = section.virtualAddress + UInt64(index * 4)
                        accumulator.samples.append(
                            "\(displayPath):\(section.name)+\(String(format: "0x%llx", address))"
                        )
                    }
                    report.unsupported[instruction] = accumulator
                }
            }
        }
    }

    private func parseExecutableSections(_ data: Data) -> ELFParseResult {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 64,
                  bytes[0] == 0x7f,
                  bytes[1] == 0x45,
                  bytes[2] == 0x4c,
                  bytes[3] == 0x46 else {
                return .notELF
            }
            guard bytes[4] == 2, bytes[5] == 1, readUInt16(bytes, at: 18) == 183 else {
                return .notARM64
            }
            let sectionEntrySize = readUInt16(bytes, at: 58)
            guard let sectionTableOffset = integerOffset(readUInt64(bytes, at: 40)),
                  sectionEntrySize >= 64 else {
                return .malformed
            }

            var sectionCount = UInt64(readUInt16(bytes, at: 60))
            var stringTableIndex = UInt64(readUInt16(bytes, at: 62))
            if sectionCount == 0 || stringTableIndex == 0xffff {
                guard contains(bytes, offset: sectionTableOffset, count: Int(sectionEntrySize)) else {
                    return .malformed
                }
                if sectionCount == 0 {
                    sectionCount = readUInt64(bytes, at: sectionTableOffset + 32)
                }
                if stringTableIndex == 0xffff {
                    stringTableIndex = UInt64(readUInt32(bytes, at: sectionTableOffset + 40))
                }
            }
            guard sectionCount <= UInt64(Int.max),
                  let tableByteCount = multipliedOffset(
                    Int(sectionCount),
                    Int(sectionEntrySize)
                  ),
                  contains(bytes, offset: sectionTableOffset, count: tableByteCount) else {
                return .malformed
            }

            var stringTableRange: Range<Int>?
            if stringTableIndex < sectionCount,
               let headerOffset = addedOffset(
                sectionTableOffset,
                Int(stringTableIndex) * Int(sectionEntrySize)
               ),
               let stringOffset = integerOffset(readUInt64(bytes, at: headerOffset + 24)),
               let stringSize = integerOffset(readUInt64(bytes, at: headerOffset + 32)),
               contains(bytes, offset: stringOffset, count: stringSize) {
                stringTableRange = stringOffset..<(stringOffset + stringSize)
            }

            var sections: [ExecutableSection] = []
            for index in 0..<Int(sectionCount) {
                guard let headerOffset = addedOffset(
                    sectionTableOffset,
                    index * Int(sectionEntrySize)
                ) else {
                    return .malformed
                }
                let type = readUInt32(bytes, at: headerOffset + 4)
                let flags = readUInt64(bytes, at: headerOffset + 8)
                guard type != 8, (flags & 0x4) != 0 else { continue }
                guard let fileOffset = integerOffset(readUInt64(bytes, at: headerOffset + 24)),
                      let byteCount = integerOffset(readUInt64(bytes, at: headerOffset + 32)),
                      contains(bytes, offset: fileOffset, count: byteCount) else {
                    return .malformed
                }
                let nameOffset = Int(readUInt32(bytes, at: headerOffset))
                let name = sectionName(bytes, table: stringTableRange, offset: nameOffset)
                sections.append(ExecutableSection(
                    name: name.isEmpty ? "<exec-\(index)>" : name,
                    fileOffset: fileOffset,
                    byteCount: byteCount,
                    virtualAddress: readUInt64(bytes, at: headerOffset + 16)
                ))
            }
            return .sections(sections)
        }
    }

    private func sectionName(
        _ bytes: UnsafeBufferPointer<UInt8>,
        table: Range<Int>?,
        offset: Int
    ) -> String {
        guard let table, offset >= 0, offset < table.count else { return "" }
        let start = table.lowerBound + offset
        var end = start
        while end < table.upperBound, bytes[end] != 0 {
            end += 1
        }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func readUInt16(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readUInt32(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private func readUInt64(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> UInt64 {
        UInt64(readUInt32(bytes, at: offset))
            | (UInt64(readUInt32(bytes, at: offset + 4)) << 32)
    }

    private func integerOffset(_ value: UInt64) -> Int? {
        value <= UInt64(Int.max) ? Int(value) : nil
    }

    private func addedOffset(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : value
    }

    private func multipliedOffset(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : value
    }

    private func contains(
        _ bytes: UnsafeBufferPointer<UInt8>,
        offset: Int,
        count: Int
    ) -> Bool {
        guard offset >= 0, count >= 0, offset <= bytes.count else { return false }
        return count <= bytes.count - offset
    }
}
