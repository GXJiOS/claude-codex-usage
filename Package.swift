// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaBar",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuotaBar",
            path: "Sources/QuotaBar",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "QuotaBarTests", dependencies: ["QuotaBar"], path: "Tests/QuotaBarTests")
    ]
)
