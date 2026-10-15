import Foundation

public enum TextReport {
    /// Compact, one line per property, for people and agents.
    public static func render(_ reports: [ViewReport], unstableOnly: Bool = false) -> String {
        var lines: [String] = []
        for report in reports where !unstableOnly || report.skippable != .yes || !report.findings.isEmpty {
            let equality = report.customEquality ? "  (custom ==)" : ""
            let kind = report.kind == .view ? "" : "  (\(report.kind.rawValue))"
            lines.append("\(report.name)\(kind)  skippable: \(report.skippable.rawValue)\(equality)  \(report.file):\(report.line)")
            for property in report.properties where !unstableOnly || property.stability != .stable {
                let wrapper = property.wrapper.map { "@\($0) " } ?? ""
                let status = property.compared ? property.stability.rawValue : "owned"
                lines.append("  \(status.padding(toLength: 9, withPad: " ", startingAt: 0))\(wrapper)\(property.name): \(property.type)  — \(property.reason)")
            }
            for finding in report.findings {
                lines.append("  \(finding.severity.rawValue) [\(finding.rule)] line \(finding.line): \(finding.message)")
            }
            if !report.suppressed.isEmpty {
                lines.append("  (\(report.suppressed.count) suppressed: \(report.suppressed.map { "\($0.rule) line \($0.line)" }.joined(separator: ", ")))")
            }
            lines.append("")
        }
        lines.append(summary(reports))
        return lines.joined(separator: "\n")
    }

    public static func summary(_ reports: [ViewReport]) -> String {
        let count = { (s: Skippability) in reports.filter { $0.skippable == s }.count }
        let warnings = reports.flatMap(\.findings).filter { $0.severity == .warning }.count
        return "\(reports.count) views: \(count(.yes)) skippable, \(count(.depends)) depends, \(count(.no)) not skippable; \(warnings) warnings"
    }
}

/// `path:line:column: warning: message`, which Xcode shows inline when a build phase or build tool plugin
/// prints it (the same channel SwiftLint uses).
public enum XcodeDiagnostics {
    /// A readable summary for the build log (Xcode's Report navigator). Plain lines, not `file:line:` ones, so
    /// Xcode keeps them out of the Issue navigator.
    public static func summary(_ reports: [ViewReport], reportPath: String?) -> String {
        let count = { (s: Skippability) in reports.filter { $0.skippable == s }.count }
        let warnings = reports.flatMap(\.findings).filter { $0.severity == .warning }
        var lines = [
            "SwiftUI stability: \(reports.count) views: \(count(.yes)) skippable, \(count(.depends)) depend on their callers, \(count(.no)) can't skip. \(warnings.count + count(.no)) warning\(warnings.count + count(.no) == 1 ? "" : "s") in the Issue navigator.",
        ]
        let blocked = reports.filter { $0.skippable == .no && !$0.stabilityWarningIgnored }
        if !blocked.isEmpty {
            lines.append("Can't skip body (unstable inputs):")
            for report in blocked {
                let inputs = report.comparedProperties.filter { $0.stability == .unstable }
                    .map { "\($0.name): \($0.type)" }.joined(separator: ", ")
                lines.append("  \(report.name)  \(inputs)  (\((report.file as NSString).lastPathComponent):\(report.line))")
            }
        }
        var byRule: [String: Int] = [:]
        for finding in warnings { byRule[finding.rule, default: 0] += 1 }
        if !byRule.isEmpty {
            lines.append("Warnings by rule: " + byRule.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
        if let reportPath { lines.append("Full report (JSON): \(reportPath)") }
        return lines.joined(separator: "\n")
    }

    public static func render(_ reports: [ViewReport], includeInfo: Bool = false) -> String {
        let cwd = FileManager.default.currentDirectoryPath
        var lines: [String] = []
        for report in reports {
            // Xcode only links a diagnostic to the editor when the path is absolute.
            let file = report.file.hasPrefix("/") ? report.file : "\(cwd)/\(report.file)"
            if report.skippable == .no, !report.stabilityWarningIgnored {
                let unstable = report.comparedProperties.filter { $0.stability == .unstable }.map(\.name)
                lines.append("\(file):\(report.line):1: warning: `\(report.name)` can't skip \(report.kind.entryPoint); unstable inputs: \(unstable.joined(separator: ", ")) [stability]")
            }
            for finding in report.findings where includeInfo || finding.severity == .warning {
                let level = finding.severity == .warning ? "warning" : "note"
                lines.append("\(file):\(finding.line):1: \(level): \(finding.message) [\(finding.rule)]")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum JSON {
    public static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

public enum SourceFiles {
    private static let skippedDirectories: Set<String> = [".build", "DerivedData", "Pods", "Carthage", "node_modules", "SourcePackages"]

    /// Every `.swift` file under `paths` (files or directories), relative to the current directory when possible.
    public static func load(_ paths: [String], excluding excluded: [String] = []) throws -> [SourceFile] {
        let manager = FileManager.default
        let cwd = manager.currentDirectoryPath + "/"
        var files: [String] = []
        for path in paths {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
            }
            guard isDirectory.boolValue else {
                files.append(path)
                continue
            }
            let root = URL(fileURLWithPath: path)
            let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                if skippedDirectories.contains(url.lastPathComponent) || excluded.contains(where: url.path.contains) {
                    enumerator?.skipDescendants()
                    continue
                }
                if url.pathExtension == "swift" { files.append(url.path) }
            }
        }
        return try files.sorted().map { path in
            let display = path.hasPrefix(cwd) ? String(path.dropFirst(cwd.count)) : path
            return SourceFile(path: display, text: try String(contentsOfFile: path, encoding: .utf8))
        }
    }
}
