// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "InputFrameAttributionRegression", targets: [
    .target(name: "ARM64VizCore"),
    .testTarget(name: "ARM64VizCoreTests", dependencies: ["ARM64VizCore"])
])
