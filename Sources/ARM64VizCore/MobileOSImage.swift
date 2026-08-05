import Foundation

public struct MobileOSBootPhase: Codable, Equatable {
    public let name: String
    public let detail: String

    public init(name: String, detail: String) {
        self.name = name
        self.detail = detail
    }
}

public struct MobileOSImageManifest: Codable, Equatable {
    public let format: String
    public let imageName: String
    public let version: String
    public let architecture: String
    public let loadAddress: GuestAddress
    public let entryPoint: GuestAddress
    public let uartBase: GuestAddress
    public let runtime: String
    public let verboseBoot: Bool
    public let phases: [MobileOSBootPhase]

    public init(
        format: String = MobileOSImage.formatIdentifier,
        imageName: String,
        version: String,
        architecture: String = "arm64",
        loadAddress: GuestAddress,
        entryPoint: GuestAddress,
        uartBase: GuestAddress,
        runtime: String,
        verboseBoot: Bool = false,
        phases: [MobileOSBootPhase]
    ) {
        self.format = format
        self.imageName = imageName
        self.version = version
        self.architecture = architecture
        self.loadAddress = loadAddress
        self.entryPoint = entryPoint
        self.uartBase = uartBase
        self.runtime = runtime
        self.verboseBoot = verboseBoot
        self.phases = phases
    }
}

public struct MobileOSImage: Codable, Equatable {
    public static let formatIdentifier = "mosimg64"
    public static let magic = Array("MOSIMG64".utf8)
    public static let containerVersion: UInt32 = 1

    public let manifest: MobileOSImageManifest
    public let payload: [UInt8]

    public init(manifest: MobileOSImageManifest, payload: [UInt8]) {
        self.manifest = manifest
        self.payload = payload
    }

    public static func developmentImage(
        runtime: String = "javascript",
        loadAddress: GuestAddress = ARM64VizMachineLayout.toyEntryPoint,
        uartBase: GuestAddress = ARM64VizMachineLayout.uartBase,
        verboseBoot: Bool = false
    ) -> MobileOSImage {
        let phases = [
            MobileOSBootPhase(name: "reset-vector", detail: "AArch64 reset vector entered from VM"),
            MobileOSBootPhase(name: "image-header", detail: "MobileOS image manifest accepted"),
            MobileOSBootPhase(name: "early-console", detail: "MMIO UART console online"),
            MobileOSBootPhase(name: "memory", detail: "physical memory map accepted"),
            MobileOSBootPhase(name: "devicetree", detail: "virtual device configuration accepted"),
            MobileOSBootPhase(name: "drivers", detail: "framebuffer touch block net drivers registered"),
            MobileOSBootPhase(name: "vfs", detail: "root filesystem mount point prepared"),
            MobileOSBootPhase(name: "init", detail: "init process scheduled"),
            MobileOSBootPhase(name: "runtime", detail: "\(runtime) app runtime selected"),
            MobileOSBootPhase(name: "login", detail: "tty0 shell ready")
        ]
        let manifest = MobileOSImageManifest(
            imageName: "MobileOS Development Image",
            version: "0.1.0",
            loadAddress: loadAddress,
            entryPoint: loadAddress,
            uartBase: uartBase,
            runtime: runtime,
            verboseBoot: verboseBoot,
            phases: phases
        )
        return MobileOSImage(
            manifest: manifest,
            payload: ToyUARTProgram.image(
                message: MobileOSImageBootTranscript.render(manifest: manifest),
                uartBase: uartBase
            )
        )
    }

    public func encodedArtifact() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifestBytes = [UInt8](try encoder.encode(manifest))
        guard UInt32(exactly: manifestBytes.count) != nil,
              UInt32(exactly: payload.count) != nil else {
            throw VMError.invalidSnapshot("MobileOS image is too large for the v1 container")
        }

        var bytes = Self.magic
        appendLittleEndian(Self.containerVersion, to: &bytes)
        appendLittleEndian(UInt32(manifestBytes.count), to: &bytes)
        appendLittleEndian(UInt32(payload.count), to: &bytes)
        bytes.append(contentsOf: manifestBytes)
        bytes.append(contentsOf: payload)
        return bytes
    }

    public static func decodeArtifact(_ bytes: [UInt8]) throws -> MobileOSImage {
        let minimumHeaderLength = magic.count + 12
        guard bytes.count >= minimumHeaderLength,
              Array(bytes[0..<magic.count]) == magic else {
            throw VMError.unsupportedGuest("not a MobileOS image container")
        }

        var cursor = magic.count
        let version = readUInt32(bytes, cursor: &cursor)
        guard version == containerVersion else {
            throw VMError.unsupportedGuest("unsupported MobileOS image version \(version)")
        }
        let manifestLength = Int(readUInt32(bytes, cursor: &cursor))
        let payloadLength = Int(readUInt32(bytes, cursor: &cursor))
        guard cursor + manifestLength + payloadLength == bytes.count else {
            throw VMError.invalidSnapshot("MobileOS image length fields do not match container size")
        }

        let manifestData = Data(bytes[cursor..<(cursor + manifestLength)])
        cursor += manifestLength
        let payload = Array(bytes[cursor..<(cursor + payloadLength)])
        let manifest = try JSONDecoder().decode(MobileOSImageManifest.self, from: manifestData)
        guard manifest.format == formatIdentifier else {
            throw VMError.unsupportedGuest("unexpected MobileOS image format \(manifest.format)")
        }
        return MobileOSImage(manifest: manifest, payload: payload)
    }

    private static func readUInt32(_ bytes: [UInt8], cursor: inout Int) -> UInt32 {
        defer { cursor += 4 }
        return UInt32(bytes[cursor])
            | UInt32(bytes[cursor + 1]) << 8
            | UInt32(bytes[cursor + 2]) << 16
            | UInt32(bytes[cursor + 3]) << 24
    }

    private func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xff))
        bytes.append(UInt8((value >> 8) & 0xff))
        bytes.append(UInt8((value >> 16) & 0xff))
        bytes.append(UInt8((value >> 24) & 0xff))
    }
}

public enum MobileOSImageBootTranscript {
    public static func render(manifest: MobileOSImageManifest) -> String {
        var lines = [
            "mobileos-image: name=\(manifest.imageName) version=\(manifest.version) format=\(manifest.format) verbose=\(manifest.verboseBoot ? 1 : 0)",
            "mobileos-image: arch=\(manifest.architecture) entry=\(manifest.entryPoint.hexString) load=\(manifest.loadAddress.hexString)"
        ]
        if manifest.verboseBoot {
            lines.append("mobileos-verbose: bootargs console=ttyAMA0 mobileos.runtime=\(manifest.runtime) mobileos.verbose=1")
            lines.append("mobileos-verbose: memory.ram_base=\(ARM64VizMachineLayout.ramBase.hexString) memory.ram_size=\(UInt64(ARM64VizMachineLayout.ramSize).hexString)")
            lines.append("mobileos-verbose: mmio.uart0=\(manifest.uartBase.hexString) mmio.fb0=\(ARM64VizMachineLayout.framebufferBase.hexString)")
            lines.append("mobileos-verbose: mmio.touch0=\(ARM64VizMachineLayout.touchBase.hexString) mmio.block0=\(ARM64VizMachineLayout.blockBase.hexString) mmio.net0=\(ARM64VizMachineLayout.networkBase.hexString)")
        }
        for (index, phase) in manifest.phases.enumerated() {
            lines.append("mobileos-phase[\(String(format: "%02d", index))]: \(phase.name) - \(phase.detail)")
            if manifest.verboseBoot {
                lines.append("mobileos-verbose: phase[\(String(format: "%02d", index))].status=ok phase[\(String(format: "%02d", index))].name=\(phase.name)")
            }
        }
        if manifest.verboseBoot {
            lines.append("mobileos-verbose: init.pid=1 tty=/dev/tty0 shell=/bin/msh")
            lines.append("mobileos-verbose: javascript.runtime=enabled apps.manifest=embedded-development")
        }
        lines.append("mobileos: app runtime=\(manifest.runtime)")
        lines.append("mobileos: boot image ready")
        lines.append("mobileos: shell ready")
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct MobileOSImageBootAdapter: GuestBootAdapter {
    public let identifier = "mobile-os-image"
    public let image: MobileOSImage

    public init(image: MobileOSImage = .developmentImage()) {
        self.image = image
    }

    public init(encodedArtifact bytes: [UInt8]) throws {
        self.image = try MobileOSImage.decodeArtifact(bytes)
    }

    public func load(into vm: VirtualMachine) throws -> BootConfiguration {
        try RuntimeDirection.requireJavaScriptMobileOSEnabled(operation: identifier)
        try vm.loadBinary(image.payload, at: image.manifest.loadAddress)
        vm.reset(entryPoint: image.manifest.entryPoint)
        return BootConfiguration(
            machineName: "arm64viz-mobile-os-image",
            entryPoint: image.manifest.entryPoint,
            ramBase: vm.memory.base,
            ramSize: UInt64(vm.memory.size),
            bootArguments: [
                "console=ttyAMA0",
                "mobileos.image=\(image.manifest.imageName.replacingOccurrences(of: " ", with: "-"))",
                "mobileos.runtime=\(image.manifest.runtime)",
                image.manifest.verboseBoot ? "mobileos.verbose=1" : nil
            ].compactMap { $0 }.joined(separator: " "),
            devices: vm.bootDevices
        )
    }
}

public enum MobileOSGuestDiagnostics {
    public static func report(
        image: MobileOSImage,
        uartOutput: String,
        framebufferChecksum: UInt64 = 0
    ) -> MobileOSKernelReport {
        MobileOSKernelReport(
            bootLog: uartOutput
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init),
            processes: [],
            apps: [],
            surfaces: [],
            touchDispatch: nil,
            framebufferChecksum: framebufferChecksum,
            unix: MobileOSUnixReport(
                processes: [],
                ptySessions: [],
                mountedPaths: [],
                supportedSyscalls: [],
                primaryPTYID: nil,
                primaryShellPID: nil
            )
        )
    }
}
