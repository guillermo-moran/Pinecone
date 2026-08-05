// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "arm64viz",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "ARM64VizCore", targets: ["ARM64VizCore"]),
        .executable(name: "arm64viz", targets: ["arm64viz"])
    ],
    targets: [
        .target(
            name: "ARM64VizNative",
            cSettings: [
                .unsafeFlags(["-O3"], .when(configuration: .debug)),
                .unsafeFlags(["-O3"], .when(configuration: .release))
            ]
        ),
        .target(
            name: "ARM64VizCore",
            dependencies: ["ARM64VizNative"],
            swiftSettings: [
                .unsafeFlags([
                    "-O",
                    "-whole-module-optimization",
                    "-enforce-exclusivity=unchecked"
                ], .when(configuration: .release)),
                .unsafeFlags([
                    "-O",
                    "-enforce-exclusivity=unchecked"
                ], .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "arm64viz",
            dependencies: ["ARM64VizCore"]
        ),
        .testTarget(
            name: "ARM64VizCoreTests",
            dependencies: ["ARM64VizCore", "ARM64VizNative"]
        )
    ]
)
