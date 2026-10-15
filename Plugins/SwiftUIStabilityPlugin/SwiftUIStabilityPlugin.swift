import Foundation
import PackagePlugin

/// Analyzes a target's SwiftUI views on each build that changes its sources, and reports the results as build
/// warnings (`file:line: warning:`), which Xcode shows inline in the editor and in the Issue navigator.
///
/// This is a build command, not a prebuild command: SwiftPM only lets prebuild commands run prebuilt binaries,
/// and this tool is built from source. Build commands normally run only when their inputs change, and their
/// warnings aren't replayed when they're skipped, so the tool touches a trigger file (one of its inputs) to run
/// on every build and keep the warnings visible.
///
/// A build command needs a declared output. Any output that isn't source becomes a resource (SwiftPM bundles it
/// into the app), so the declared output is a comment-only Swift file; the JSON report is written next to it
/// for agents and scripts.
@main
struct SwiftUIStabilityPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let files = target.sourceFiles(withSuffix: "swift").map(\.url)
        return try commands(tool: context.tool(named: "swiftui-stability").url, files: files,
                            workDirectory: context.pluginWorkDirectoryURL, targetName: target.name)
    }
}

private func commands(tool: URL, files: [URL], workDirectory: URL, targetName: String) -> [Command] {
    guard !files.isEmpty else { return [] }
    let stamp = workDirectory.appending(path: "\(targetName)+SwiftUIStability.swift")
    let report = workDirectory.appending(path: "\(targetName).stability.json")
    let trigger = workDirectory.appending(path: "\(targetName).stability.trigger")
    if !FileManager.default.fileExists(atPath: trigger.path()) {
        FileManager.default.createFile(atPath: trigger.path(), contents: nil)
    }
    return [
        .buildCommand(
            displayName: "SwiftUI stability: \(targetName)",
            executable: tool,
            arguments: ["analyze", "--format", "xcode", "--report", report.path(), "--stamp", stamp.path(),
                        "--trigger", trigger.path()] + files.map { $0.path() },
            inputFiles: files + [trigger],
            outputFiles: [stamp]
        ),
    ]
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension SwiftUIStabilityPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let files = target.inputFiles.filter { $0.type == .source && $0.url.pathExtension == "swift" }.map(\.url)
        return try commands(tool: context.tool(named: "swiftui-stability").url, files: files,
                            workDirectory: context.pluginWorkDirectoryURL, targetName: target.displayName)
    }
}
#endif
