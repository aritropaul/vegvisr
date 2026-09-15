// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vegvisr",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Worldgen", targets: ["Worldgen"]),
    ],
    targets: [
        .target(
            name: "Worldgen",
            path: "Sources/Worldgen",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(name: "parity", dependencies: ["Worldgen"], path: "Tests/parity"),
        .executableTarget(name: "snapshot", dependencies: ["Worldgen"], path: "Tests/snapshot"),
    ]
)
