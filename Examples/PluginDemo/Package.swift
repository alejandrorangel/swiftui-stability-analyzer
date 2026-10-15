// swift-tools-version: 6.0
import PackageDescription

// Applies the stability plugin to a SwiftUI target: `swift build` (or building in Xcode) reports the warnings.
let package = Package(
    name: "PluginDemo",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "DemoViews", targets: ["DemoViews"])],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "DemoViews",
            plugins: [.plugin(name: "SwiftUIStabilityPlugin", package: "swiftui-stability-analyzer")]
        ),
    ]
)
