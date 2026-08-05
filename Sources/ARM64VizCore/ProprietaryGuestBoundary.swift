import Foundation

public enum ProprietaryGuestMaterialKind: String, Codable, CaseIterable {
    case genericOSImage
    case kernelImage
    case ramdisk
    case bootConfiguration
    case deviceTree
    case driverPackage
    case firmwareBlob
    case bootROMCode
    case bootloaderCode
    case deviceKey
    case certificate
    case secureEnclaveSecret
    case activationMaterial
    case attestationMaterial
    case ipswArchive
}

public struct ProprietaryGuestMaterial: Codable, Equatable {
    public let kind: ProprietaryGuestMaterialKind
    public let identifier: String
    public let lawfulSourceDescription: String

    public init(
        kind: ProprietaryGuestMaterialKind,
        identifier: String,
        lawfulSourceDescription: String
    ) {
        self.kind = kind
        self.identifier = identifier
        self.lawfulSourceDescription = lawfulSourceDescription
    }
}

public struct ProprietaryGuestManifest: Codable, Equatable {
    public let guestName: String
    public let researchPurpose: String
    public let authorizationSummary: String
    public let externalServiceAccessAllowed: Bool
    public let materials: [ProprietaryGuestMaterial]

    public init(
        guestName: String,
        researchPurpose: String,
        authorizationSummary: String,
        externalServiceAccessAllowed: Bool = false,
        materials: [ProprietaryGuestMaterial]
    ) {
        self.guestName = guestName
        self.researchPurpose = researchPurpose
        self.authorizationSummary = authorizationSummary
        self.externalServiceAccessAllowed = externalServiceAccessAllowed
        self.materials = materials
    }
}

public struct ProprietaryGuestPolicyReport: Codable, Equatable {
    public let accepted: Bool
    public let guestName: String
    public let findings: [String]
    public let warnings: [String]
    public let boundaryMode: String

    public init(
        accepted: Bool,
        guestName: String,
        findings: [String],
        warnings: [String] = [],
        boundaryMode: String = ProprietaryGuestBoundaryMode.metadataOnly.rawValue
    ) {
        self.accepted = accepted
        self.guestName = guestName
        self.findings = findings
        self.warnings = warnings
        self.boundaryMode = boundaryMode
    }
}

public enum ProprietaryGuestBoundaryMode: String, Codable {
    case disabled
    case metadataOnly
}

public struct ARM64VizPreferences: Codable, Equatable {
    public let schemaVersion: Int
    public let proprietaryGuests: ProprietaryGuestPreferences
    public let audit: AuditPreferences

    public init(
        schemaVersion: Int = 1,
        proprietaryGuests: ProprietaryGuestPreferences = .hardenedDefaults,
        audit: AuditPreferences = .hardenedDefaults
    ) {
        self.schemaVersion = schemaVersion
        self.proprietaryGuests = proprietaryGuests
        self.audit = audit
    }

    public static let hardenedDefaults = ARM64VizPreferences()
}

public struct ProprietaryGuestPreferences: Codable, Equatable {
    public let boundaryMode: ProprietaryGuestBoundaryMode
    public let requireResearchPurpose: Bool
    public let requireAuthorizationSummary: Bool
    public let requireLawfulSourceDescription: Bool
    public let allowExternalServiceAccess: Bool
    public let deniedMaterialKinds: [ProprietaryGuestMaterialKind]
    public let deniedIdentifierSuffixes: [String]
    public let deniedIdentifierTerms: [String]

    public init(
        boundaryMode: ProprietaryGuestBoundaryMode = .metadataOnly,
        requireResearchPurpose: Bool = true,
        requireAuthorizationSummary: Bool = true,
        requireLawfulSourceDescription: Bool = true,
        allowExternalServiceAccess: Bool = false,
        deniedMaterialKinds: [ProprietaryGuestMaterialKind] = ProprietaryGuestPolicy.defaultRestrictedMaterialKinds,
        deniedIdentifierSuffixes: [String] = ProprietaryGuestPolicy.defaultDeniedIdentifierSuffixes,
        deniedIdentifierTerms: [String] = ProprietaryGuestPolicy.defaultDeniedIdentifierTerms
    ) {
        self.boundaryMode = boundaryMode
        self.requireResearchPurpose = requireResearchPurpose
        self.requireAuthorizationSummary = requireAuthorizationSummary
        self.requireLawfulSourceDescription = requireLawfulSourceDescription
        self.allowExternalServiceAccess = allowExternalServiceAccess
        self.deniedMaterialKinds = deniedMaterialKinds
        self.deniedIdentifierSuffixes = deniedIdentifierSuffixes
        self.deniedIdentifierTerms = deniedIdentifierTerms
    }

    public static let hardenedDefaults = ProprietaryGuestPreferences()
}

public struct AuditPreferences: Codable, Equatable {
    public let requirePolicyReport: Bool
    public let logMaterialIdentifiersOnly: Bool
    public let requireHumanReviewBeforeNewGuestAdapter: Bool

    public init(
        requirePolicyReport: Bool = true,
        logMaterialIdentifiersOnly: Bool = true,
        requireHumanReviewBeforeNewGuestAdapter: Bool = true
    ) {
        self.requirePolicyReport = requirePolicyReport
        self.logMaterialIdentifiersOnly = logMaterialIdentifiersOnly
        self.requireHumanReviewBeforeNewGuestAdapter = requireHumanReviewBeforeNewGuestAdapter
    }

    public static let hardenedDefaults = AuditPreferences()
}

public enum ARM64VizPreferencesLoader {
    public static func load(from path: String?) throws -> ARM64VizPreferences {
        guard let path else {
            return .hardenedDefaults
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let preferences = try JSONDecoder().decode(ARM64VizPreferences.self, from: data)
        try validate(preferences)
        return preferences
    }

    public static func validate(_ preferences: ARM64VizPreferences) throws {
        guard preferences.schemaVersion == 1 else {
            throw VMError.policyViolation("unsupported preferences schemaVersion \(preferences.schemaVersion)")
        }

        if preferences.proprietaryGuests.allowExternalServiceAccess {
            throw VMError.policyViolation("preferences cannot allow external service access in this build")
        }

        let deniedKinds = Set(preferences.proprietaryGuests.deniedMaterialKinds)
        let missingKinds = ProprietaryGuestPolicy.defaultRestrictedMaterialKinds.filter { !deniedKinds.contains($0) }
        if !missingKinds.isEmpty {
            let names = missingKinds.map(\.rawValue).joined(separator: ", ")
            throw VMError.policyViolation("preferences cannot weaken restricted material kinds: \(names)")
        }

        let deniedSuffixes = Set(preferences.proprietaryGuests.deniedIdentifierSuffixes.map { $0.lowercased() })
        let missingSuffixes = ProprietaryGuestPolicy.defaultDeniedIdentifierSuffixes.filter {
            !deniedSuffixes.contains($0.lowercased())
        }
        if !missingSuffixes.isEmpty {
            throw VMError.policyViolation("preferences cannot weaken denied identifier suffixes: \(missingSuffixes.joined(separator: ", "))")
        }

        let deniedTerms = Set(preferences.proprietaryGuests.deniedIdentifierTerms.map { $0.lowercased() })
        let missingTerms = ProprietaryGuestPolicy.defaultDeniedIdentifierTerms.filter {
            !deniedTerms.contains($0.lowercased())
        }
        if !missingTerms.isEmpty {
            throw VMError.policyViolation("preferences cannot weaken denied identifier terms: \(missingTerms.joined(separator: ", "))")
        }
    }
}

public enum ProprietaryGuestPolicy {
    public static let defaultRestrictedMaterialKinds: [ProprietaryGuestMaterialKind] = [
        .firmwareBlob,
        .bootROMCode,
        .bootloaderCode,
        .deviceKey,
        .certificate,
        .secureEnclaveSecret,
        .activationMaterial,
        .attestationMaterial,
        .ipswArchive
    ]

    public static let defaultDeniedIdentifierSuffixes: [String] = [
        ".ipsw",
        ".im4p",
        ".im4m",
        ".img4",
        ".bbfw"
    ]

    public static let defaultDeniedIdentifierTerms: [String] = [
        "ipsw",
        "secure enclave",
        "sep secret",
        "activation",
        "attestation",
        "apns",
        "imessage"
    ]

    public static var restrictedMaterialKinds: Set<ProprietaryGuestMaterialKind> {
        Set(defaultRestrictedMaterialKinds)
    }

    public static func evaluate(
        _ manifest: ProprietaryGuestManifest,
        preferences: ARM64VizPreferences = .hardenedDefaults
    ) -> ProprietaryGuestPolicyReport {
        var findings: [String] = []
        var warnings: [String] = []
        let proprietaryPreferences = preferences.proprietaryGuests

        if proprietaryPreferences.boundaryMode == .disabled {
            findings.append("proprietary guest manifests are disabled by preferences")
        }

        if trimmed(manifest.guestName).isEmpty {
            findings.append("guestName is required")
        }

        if proprietaryPreferences.requireResearchPurpose && trimmed(manifest.researchPurpose).isEmpty {
            findings.append("researchPurpose is required")
        }

        if proprietaryPreferences.requireAuthorizationSummary && trimmed(manifest.authorizationSummary).isEmpty {
            findings.append("authorizationSummary is required")
        }

        if manifest.externalServiceAccessAllowed && !proprietaryPreferences.allowExternalServiceAccess {
            findings.append("external service access is not allowed by this research boundary")
        }

        if preferences.audit.requireHumanReviewBeforeNewGuestAdapter {
            warnings.append("new proprietary guest adapters require human legal and security review")
        }

        if preferences.audit.logMaterialIdentifiersOnly {
            warnings.append("audit logs should contain material identifiers only, not proprietary package contents")
        }

        let deniedKinds = Set(proprietaryPreferences.deniedMaterialKinds)
        let deniedSuffixes = proprietaryPreferences.deniedIdentifierSuffixes.map { $0.lowercased() }
        let deniedTerms = proprietaryPreferences.deniedIdentifierTerms.map { $0.lowercased() }

        for material in manifest.materials {
            if deniedKinds.contains(material.kind) {
                findings.append("\(material.kind.rawValue) is not accepted by this repository")
            }

            if trimmed(material.identifier).isEmpty {
                findings.append("material identifier is required for \(material.kind.rawValue)")
            }

            if proprietaryPreferences.requireLawfulSourceDescription && trimmed(material.lawfulSourceDescription).isEmpty {
                findings.append("lawfulSourceDescription is required for \(material.kind.rawValue)")
            }

            let searchableText = "\(material.identifier) \(material.lawfulSourceDescription)".lowercased()
            let identifier = material.identifier.lowercased()

            for suffix in deniedSuffixes where identifier.hasSuffix(suffix) {
                findings.append("material identifier '\(material.identifier)' ends with denied suffix \(suffix)")
            }

            for term in deniedTerms where searchableText.contains(term) {
                findings.append("material metadata for \(material.kind.rawValue) contains denied term '\(term)'")
            }
        }

        return ProprietaryGuestPolicyReport(
            accepted: findings.isEmpty,
            guestName: manifest.guestName,
            findings: findings,
            warnings: warnings,
            boundaryMode: proprietaryPreferences.boundaryMode.rawValue
        )
    }

    public static func validate(
        _ manifest: ProprietaryGuestManifest,
        preferences: ARM64VizPreferences = .hardenedDefaults
    ) throws {
        let report = evaluate(manifest, preferences: preferences)
        guard report.accepted else {
            throw VMError.policyViolation(report.findings.joined(separator: "; "))
        }
    }
}

public struct BoundaryOnlyProprietaryGuestAdapter: GuestBootAdapter {
    public let identifier = "boundary-only-proprietary-guest"
    public let manifest: ProprietaryGuestManifest
    public let preferences: ARM64VizPreferences

    public init(
        manifest: ProprietaryGuestManifest,
        preferences: ARM64VizPreferences = .hardenedDefaults
    ) {
        self.manifest = manifest
        self.preferences = preferences
    }

    public func load(into vm: VirtualMachine) throws -> BootConfiguration {
        try ProprietaryGuestPolicy.validate(manifest, preferences: preferences)
        throw VMError.unsupportedGuest(
            "this adapter validates proprietary guest metadata only; it does not ingest, extract, decrypt, or boot proprietary OS packages"
        )
    }
}

private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}
