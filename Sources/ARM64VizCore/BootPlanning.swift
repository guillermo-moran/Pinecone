import Foundation

public enum BootUseCase: String, Codable, CaseIterable {
    case toyUART
    case mobileOS
    case linuxDirect
    case aosp
    case bsd
    case rtos
    case rawARM64Binary
    case proprietaryBoundary
}

public enum BootAdapterStatus: String, Codable {
    case runnable
    case loadable
    case planned
    case disabled
    case boundaryOnly
}

public enum BootArtifactKind: String, Codable, CaseIterable {
    case arm64KernelImage
    case initrd
    case deviceTreeBlob
    case diskImage
    case rootFilesystem
    case androidSystemImage
    case androidVendorImage
    case androidProductImage
    case androidSuperImage
    case rawARM64Binary
    case mobileOSImage
    case mobileAppBundle
    case metadataManifest
    case restrictedPackage
    case unknown
}

public struct BootArtifactDescriptor: Codable, Equatable {
    public let name: String
    public let byteCount: UInt64
    public let kind: BootArtifactKind

    public init(name: String, byteCount: UInt64, kind: BootArtifactKind? = nil) {
        self.name = name
        self.byteCount = byteCount
        self.kind = kind ?? BootArtifactClassifier.classify(name: name)
    }
}

public struct BootAdapterDescriptor: Codable, Equatable {
    public let identifier: String
    public let displayName: String
    public let useCase: BootUseCase
    public let status: BootAdapterStatus
    public let requiredArtifactKinds: [BootArtifactKind]
    public let optionalArtifactKinds: [BootArtifactKind]
    public let notes: [String]

    public init(
        identifier: String,
        displayName: String,
        useCase: BootUseCase,
        status: BootAdapterStatus,
        requiredArtifactKinds: [BootArtifactKind],
        optionalArtifactKinds: [BootArtifactKind] = [],
        notes: [String] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.useCase = useCase
        self.status = status
        self.requiredArtifactKinds = requiredArtifactKinds
        self.optionalArtifactKinds = optionalArtifactKinds
        self.notes = notes
    }
}

public struct BootPlan: Codable, Equatable {
    public let adapter: BootAdapterDescriptor
    public let matchesArtifacts: Bool
    public let canLaunchNow: Bool
    public let findings: [String]
    public let warnings: [String]
    public let nextSteps: [String]

    public init(
        adapter: BootAdapterDescriptor,
        matchesArtifacts: Bool,
        canLaunchNow: Bool,
        findings: [String],
        warnings: [String],
        nextSteps: [String]
    ) {
        self.adapter = adapter
        self.matchesArtifacts = matchesArtifacts
        self.canLaunchNow = canLaunchNow
        self.findings = findings
        self.warnings = warnings
        self.nextSteps = nextSteps
    }
}

public protocol BootPlanningAdapter {
    var descriptor: BootAdapterDescriptor { get }
    func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan
}

public enum BootArtifactClassifier {
    public static func classify(name: String) -> BootArtifactKind {
        let lowercased = name.lowercased()
        let lastPathComponent = URL(fileURLWithPath: lowercased).lastPathComponent

        if ProprietaryGuestPolicy.defaultDeniedIdentifierSuffixes.contains(where: { lastPathComponent.hasSuffix($0) }) {
            return .restrictedPackage
        }

        if lastPathComponent.hasSuffix(".mosimg") || lastPathComponent.hasSuffix(".mobileos") {
            return .mobileOSImage
        }

        if lastPathComponent.hasSuffix(".dtb") || lastPathComponent.hasSuffix(".dtbo") {
            return .deviceTreeBlob
        }

        if lastPathComponent.contains("initrd") ||
            lastPathComponent.contains("ramdisk") ||
            lastPathComponent.hasSuffix(".cpio") ||
            lastPathComponent.hasSuffix(".cpio.gz") {
            return .initrd
        }

        if lastPathComponent == "image" ||
            lastPathComponent.contains("vmlinuz") ||
            lastPathComponent.contains("kernel") ||
            lastPathComponent.hasSuffix(".elf") {
            return .arm64KernelImage
        }

        if lastPathComponent == "system.img" {
            return .androidSystemImage
        }

        if lastPathComponent == "vendor.img" {
            return .androidVendorImage
        }

        if lastPathComponent == "product.img" {
            return .androidProductImage
        }

        if lastPathComponent == "super.img" {
            return .androidSuperImage
        }

        if lastPathComponent.hasSuffix(".app.js") || lastPathComponent.hasSuffix(".mobile.js") {
            return .mobileAppBundle
        }

        if lastPathComponent.hasSuffix(".json") {
            if lastPathComponent.contains("apps") || lastPathComponent.contains("mobile") {
                return .mobileAppBundle
            }
            return .metadataManifest
        }

        if lastPathComponent.hasSuffix(".bin") {
            return .rawARM64Binary
        }

        if lastPathComponent.hasSuffix(".img") ||
            lastPathComponent.hasSuffix(".raw") ||
            lastPathComponent.hasSuffix(".qcow2") {
            return .diskImage
        }

        return .unknown
    }
}

public enum BootAdapterRegistry {
    public static let adapters: [any BootPlanningAdapter] = [
        ToyUARTPlanningAdapter(),
        MobileOSPlanningAdapter(),
        RawARM64BinaryPlanningAdapter(),
        RTOSPlanningAdapter(),
        LinuxDirectBootPlanningAdapter(),
        AOSPBootPlanningAdapter(),
        BSDDirectBootPlanningAdapter(),
        ProprietaryBoundaryPlanningAdapter()
    ]

    public static func descriptors() -> [BootAdapterDescriptor] {
        adapters.map(\.descriptor)
    }

    public static func plans(
        for artifacts: [BootArtifactDescriptor],
        preferences: ARM64VizPreferences = .hardenedDefaults
    ) -> [BootPlan] {
        adapters.map { $0.plan(for: artifacts, preferences: preferences) }
    }
}

public struct ToyUARTPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "toy-uart",
        displayName: "Toy UART Guest",
        useCase: .toyUART,
        status: .runnable,
        requiredArtifactKinds: [],
        notes: ["Runs the built-in toy ARM64 guest and virtual UART path."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        BootPlan(
            adapter: descriptor,
            matchesArtifacts: artifacts.isEmpty,
            canLaunchNow: artifacts.isEmpty,
            findings: artifacts.isEmpty ? [] : ["toy guest does not consume dropped boot images"],
            warnings: [],
            nextSteps: ["Run: swift run arm64viz run-toy"]
        )
    }
}

public struct MobileOSPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "mobile-os-image",
        displayName: "MobileOS Image",
        useCase: .mobileOS,
        status: .disabled,
        requiredArtifactKinds: [],
        optionalArtifactKinds: [.mobileOSImage, .mobileAppBundle, .metadataManifest],
        notes: ["Disabled. The active track is native Linux/postmarketOS bring-up."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        let restricted = restrictedArtifactFindings(artifacts, preferences: preferences)
        let supported = Set(descriptor.optionalArtifactKinds)
        let unsupported = artifacts.filter { !supported.contains($0.kind) }
        var findings = restricted
        for artifact in unsupported {
            findings.append("\(artifact.name) is not a MobileOS image, mobile app bundle, or metadata manifest")
        }

        return BootPlan(
            adapter: descriptor,
            matchesArtifacts: findings.isEmpty,
            canLaunchNow: false,
            findings: findings + [RuntimeDirection.javascriptMobileOSDisabledReason],
            warnings: artifacts.contains { $0.kind == .mobileAppBundle }
                ? ["JavaScript app bundles are archived with the disabled MobileOS track"]
                : ["MobileOS launch/build paths are disabled"],
            nextSteps: [
                "Prepare Linux: swift run arm64viz prepare-linux Image --postmarketos --initrd initrd.cpio.gz --disk rootfs.img",
                "Complete Linux-grade MMU permissions, interrupt priority/nesting, UART console, and virtio support"
            ]
        )
    }
}

public struct RawARM64BinaryPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "raw-arm64-binary",
        displayName: "Raw ARM64 Binary",
        useCase: .rawARM64Binary,
        status: .planned,
        requiredArtifactKinds: [.rawARM64Binary],
        optionalArtifactKinds: [.metadataManifest],
        notes: ["Will load a flat open ARM64 binary at a configured physical address."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        standardPlan(
            descriptor: descriptor,
            artifacts: artifacts,
            preferences: preferences,
            nextSteps: ["Add load address metadata.", "Map UART and RAM.", "Use the software backend for first execution."]
        )
    }
}

public struct RTOSPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "rtos-direct",
        displayName: "RTOS / Microkernel",
        useCase: .rtos,
        status: .planned,
        requiredArtifactKinds: [.arm64KernelImage],
        optionalArtifactKinds: [.deviceTreeBlob, .rawARM64Binary],
        notes: ["Suitable for Zephyr, FreeRTOS-style demos, seL4 research images, or teaching kernels."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        standardPlan(
            descriptor: descriptor,
            artifacts: artifacts,
            preferences: preferences,
            nextSteps: ["Define the image entry point.", "Add timer and UART device expectations.", "Keep MMU optional for early bring-up."]
        )
    }
}

public struct LinuxDirectBootPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "linux-direct",
        displayName: "Linux Direct Boot",
        useCase: .linuxDirect,
        status: .loadable,
        requiredArtifactKinds: [.arm64KernelImage],
        optionalArtifactKinds: [.initrd, .deviceTreeBlob, .diskImage, .rootFilesystem],
        notes: ["Loads open ARM64 Linux Image artifacts, stages initrd/disk storage, and passes x0 as an FDT pointer."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        standardPlan(
            descriptor: descriptor,
            artifacts: artifacts,
            preferences: preferences,
            nextSteps: [
                "Harden GIC/timer driver compatibility.",
                "Harden PL011 FIFO/control register behavior.",
                "Add virtio descriptor-ring execution for net/input/display.",
                "Expand MMU shareability, cacheability, and TLB maintenance."
            ]
        )
    }
}

public struct AOSPBootPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "aosp",
        displayName: "AOSP Android",
        useCase: .aosp,
        status: .planned,
        requiredArtifactKinds: [.arm64KernelImage, .initrd],
        optionalArtifactKinds: [.androidSystemImage, .androidVendorImage, .androidProductImage, .androidSuperImage, .diskImage],
        notes: ["Targets open AOSP-style artifacts without Google Mobile Services or vendor firmware blobs."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        standardPlan(
            descriptor: descriptor,
            artifacts: artifacts,
            preferences: preferences,
            nextSteps: ["Boot open Linux first.", "Add Android ramdisk and partition metadata.", "Model virtio block/net/input/display.", "Keep proprietary Google or vendor components out of scope."]
        )
    }
}

public struct BSDDirectBootPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "bsd-direct",
        displayName: "BSD ARM64",
        useCase: .bsd,
        status: .planned,
        requiredArtifactKinds: [.arm64KernelImage],
        optionalArtifactKinds: [.diskImage, .deviceTreeBlob],
        notes: ["Targets legally obtained FreeBSD, NetBSD, or OpenBSD ARM64 research images."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        standardPlan(
            descriptor: descriptor,
            artifacts: artifacts,
            preferences: preferences,
            nextSteps: ["Confirm guest boot ABI.", "Generate platform description.", "Add disk and network devices expected by the chosen BSD."]
        )
    }
}

public struct ProprietaryBoundaryPlanningAdapter: BootPlanningAdapter {
    public let descriptor = BootAdapterDescriptor(
        identifier: "proprietary-boundary",
        displayName: "Proprietary Guest Boundary",
        useCase: .proprietaryBoundary,
        status: .boundaryOnly,
        requiredArtifactKinds: [.metadataManifest],
        notes: ["Validates metadata only. It does not ingest, extract, decrypt, or boot proprietary OS packages."]
    )

    public init() {}

    public func plan(for artifacts: [BootArtifactDescriptor], preferences: ARM64VizPreferences) -> BootPlan {
        var findings = restrictedArtifactFindings(artifacts, preferences: preferences)
        let hasManifest = artifacts.contains { $0.kind == .metadataManifest }
        if !hasManifest {
            findings.append("metadata manifest is required for proprietary boundary review")
        }

        return BootPlan(
            adapter: descriptor,
            matchesArtifacts: hasManifest,
            canLaunchNow: false,
            findings: findings,
            warnings: [
                "boundary-only adapter never boots proprietary packages",
                "human legal and security review required before any new proprietary guest adapter"
            ],
            nextSteps: ["Validate metadata with validate-manifest.", "Use open guests for VM bring-up."]
        )
    }
}

private func standardPlan(
    descriptor: BootAdapterDescriptor,
    artifacts: [BootArtifactDescriptor],
    preferences: ARM64VizPreferences,
    nextSteps: [String]
) -> BootPlan {
    var findings = restrictedArtifactFindings(artifacts, preferences: preferences)
    let artifactKinds = Set(artifacts.map(\.kind))
    let missingKinds = descriptor.requiredArtifactKinds.filter { !artifactKinds.contains($0) }
    for kind in missingKinds {
        findings.append("missing required artifact kind \(kind.rawValue)")
    }

    let acceptedKinds = Set(descriptor.requiredArtifactKinds + descriptor.optionalArtifactKinds)
    let hasAcceptedArtifact = artifacts.isEmpty ? descriptor.requiredArtifactKinds.isEmpty : artifacts.contains {
        acceptedKinds.contains($0.kind)
    }

    return BootPlan(
        adapter: descriptor,
        matchesArtifacts: hasAcceptedArtifact && missingKinds.isEmpty,
        canLaunchNow: descriptor.status == .runnable && findings.isEmpty,
        findings: findings,
        warnings: warnings(for: descriptor.status),
        nextSteps: nextSteps
    )
}

private func warnings(for status: BootAdapterStatus) -> [String] {
    switch status {
    case .runnable:
        return []
    case .loadable:
        return ["adapter can prepare VM state; full guest execution awaits Linux-grade MMU/device/interrupt completeness"]
    case .planned:
        return ["adapter is planned but not implemented as a launcher"]
    case .disabled:
        return ["adapter is disabled for the current project direction"]
    case .boundaryOnly:
        return []
    }
}

private func restrictedArtifactFindings(
    _ artifacts: [BootArtifactDescriptor],
    preferences: ARM64VizPreferences
) -> [String] {
    let deniedSuffixes = preferences.proprietaryGuests.deniedIdentifierSuffixes.map { $0.lowercased() }
    let deniedTerms = preferences.proprietaryGuests.deniedIdentifierTerms.map { $0.lowercased() }

    return artifacts.flatMap { artifact -> [String] in
        var findings: [String] = []
        let name = artifact.name.lowercased()

        if artifact.kind == .restrictedPackage {
            findings.append("\(artifact.name) is a restricted package type")
        }

        for suffix in deniedSuffixes where name.hasSuffix(suffix) {
            findings.append("\(artifact.name) ends with denied suffix \(suffix)")
        }

        for term in deniedTerms where name.contains(term) {
            findings.append("\(artifact.name) contains denied term '\(term)'")
        }

        return findings
    }
}
