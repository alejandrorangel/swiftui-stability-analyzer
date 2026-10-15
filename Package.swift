// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swiftui-stability-analyzer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "swiftui-stability", targets: ["swiftui-stability"]),
        .library(name: "StabilityCore", targets: ["StabilityCore"]),
        .plugin(name: "SwiftUIStabilityPlugin", targets: ["SwiftUIStabilityPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Command definitions only; analysis lives in StabilityCore so it can be tested on source strings.
        .executableTarget(
            name: "swiftui-stability",
            dependencies: [
                "StabilityCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "StabilityCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        // Runs the analyzer on a target's sources during the build; Xcode shows the results as inline warnings.
        .plugin(
            name: "SwiftUIStabilityPlugin",
            capability: .buildTool(),
            dependencies: ["swiftui-stability"]
        ),
        .testTarget(name: "StabilityCoreTests", dependencies: ["StabilityCore"]),
    ]
)
