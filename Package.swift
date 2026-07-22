// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "wisp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WispKit", targets: ["WispKit"]),
        .executable(name: "wisp", targets: ["Wisp"]),
    ],
    targets: [
        .target(
            name: "WispKit",
            path: "Sources/WispKit"
        ),
        .executableTarget(
            name: "Wisp",
            dependencies: ["WispKit"],
            path: "Sources/Wisp"
        ),
        // Dependency-free test runner (this repo supports toolchains that
        // ship neither XCTest nor the swift-testing runtime).
        .executableTarget(
            name: "WispTests",
            dependencies: ["WispKit"],
            path: "Tests/WispTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
