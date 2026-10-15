import Foundation

/// `body` evaluations per view, read from an Instruments trace recorded with the "View Body (Legacy)" instrument.
///
/// Verified against StabilityLab's own counters: the trace's per-view counts match them exactly. The newer
/// "SwiftUI" instrument records nothing on the simulator, so it isn't used yet.
public struct BodyTrace: Codable, Sendable {
    public struct View: Codable, Sendable {
        /// As SwiftUI names it, generic arguments removed (`Card<Text>` → `Card`).
        public var name: String
        public var module: String
        public var count: Int
        /// Total time in `body`, in milliseconds.
        public var totalMilliseconds: Double
    }

    /// Recording length in seconds, when known.
    public var duration: Double?
    /// The app's own views (system modules left out), hottest (most total time) first.
    public var views: [View]

    public static let instrument = "View Body (Legacy)"
    static let schema = "swiftui-body-interval"
    static let systemModules: Set<String> = ["SwiftUI", "SwiftUICore", "UIKit", "UIKitCore", "AppKit", "Foundation"]

    /// Parses `xctrace export --xpath '…/table[@schema="swiftui-body-interval"]'` output.
    public init(exportXML data: Data, duration: Double? = nil) throws {
        let document = try XMLDocument(data: data)
        guard let schema = try document.nodes(forXPath: "//schema").first as? XMLElement else {
            throw TraceError.noBodyTable
        }
        let columns = (try schema.nodes(forXPath: "col/mnemonic")).compactMap(\.stringValue)
        guard let typeColumn = columns.firstIndex(of: "view-type"),
              let moduleColumn = columns.firstIndex(of: "view-module"),
              let durationColumn = columns.firstIndex(of: "duration") else {
            throw TraceError.unexpectedColumns(columns)
        }

        // Repeated values are written once with an `id` and referenced afterwards with `ref`.
        var values: [String: String] = [:]
        func value(_ element: XMLElement) -> String {
            if let ref = element.attribute(forName: "ref")?.stringValue { return values[ref] ?? "" }
            let text = element.stringValue ?? ""
            if let id = element.attribute(forName: "id")?.stringValue { values[id] = text }
            return text
        }

        var totals: [String: View] = [:]
        for case let row as XMLElement in try document.nodes(forXPath: "//row") {
            let cells = (row.children ?? []).compactMap { $0 as? XMLElement }.map(value)
            guard cells.count > max(typeColumn, moduleColumn, durationColumn) else { continue }
            let module = Self.moduleName(cells[moduleColumn])
            guard !Self.systemModules.contains(module) else { continue }
            let name = String(cells[typeColumn].prefix { $0 != "<" })
            let nanoseconds = Double(cells[durationColumn]) ?? 0
            totals[name, default: View(name: name, module: module, count: 0, totalMilliseconds: 0)].count += 1
            totals[name]!.totalMilliseconds += nanoseconds / 1_000_000
        }
        self.duration = duration
        views = totals.values.sorted { ($0.totalMilliseconds, $0.count, $1.name) > ($1.totalMilliseconds, $1.count, $0.name) }
    }

    /// `MyApp.debug.dylib` (Debug builds with previews enabled) → `MyApp`.
    static func moduleName(_ raw: String) -> String {
        raw.replacingOccurrences(of: ".debug.dylib", with: "")
    }
}

public enum TraceError: Error, CustomStringConvertible {
    case noBodyTable
    case unexpectedColumns([String])

    public var description: String {
        switch self {
        case .noBodyTable:
            "The trace has no View Body data. Record with `xctrace record --instrument \"\(BodyTrace.instrument)\"` (or the SwiftUI template in Instruments)."
        case .unexpectedColumns(let columns):
            "Unexpected View Body columns: \(columns.joined(separator: ", ")). This Xcode may have changed the instrument."
        }
    }
}

/// The static prediction for a traced view, and how the measurement compares.
public struct RealityCheck: Codable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// Predicted to re-run with its parent, and it did run often.
        case confirmed
        /// Predicted to re-run, but it ran rarely: the parent doesn't update often, or the prediction is wrong.
        case notRerunning = "not-rerunning"
        /// Ran often without a prediction: its own state, observation or environment, or a changing input.
        case unexplained
        /// Neither predicted nor hot.
        case quiet
        /// Not in the analyzed sources.
        case notAnalyzed = "not-analyzed"
    }

    public struct Row: Codable, Sendable {
        public var view: BodyTrace.View
        public var verdict: Verdict
        /// Why the analyzer predicts a re-run, if it does.
        public var prediction: String?
        /// For unexplained rows: the likely drivers the analysis knows about.
        public var hint: String?
    }

    public var hotThreshold: Int
    public var rows: [Row]

    /// A view is hot when its body ran at least `hotThreshold` times.
    public init(trace: BodyTrace, reports: [ViewReport], hotThreshold: Int = 10) {
        self.hotThreshold = hotThreshold
        let byName = Dictionary(reports.map { ($0.name.split(separator: ".").last.map(String.init) ?? $0.name, $0) },
                                uniquingKeysWith: { first, _ in first })
        // Children that some call site passes a self-capturing closure, with the parent's name.
        var flagged: [String: String] = [:]
        for report in reports {
            for finding in report.findings where finding.rule == "closure-captures-self" {
                let child = finding.message.split(separator: "`").dropFirst().first.map(String.init) ?? ""
                flagged[child] = "\(report.name) passes a closure capturing `self` (line \(finding.line))"
            }
        }

        rows = trace.views.map { view in
            let hot = view.count >= hotThreshold
            guard let report = byName[view.name] else {
                return Row(view: view, verdict: .notAnalyzed, prediction: nil, hint: nil)
            }
            var prediction: String?
            if report.skippable == .no {
                let unstable = report.comparedProperties.filter { $0.stability == .unstable }.map(\.name)
                prediction = "skippable: no (\(unstable.joined(separator: ", ")))"
            } else if let reason = flagged[view.name] {
                prediction = reason
            }
            let verdict: Verdict = switch (prediction != nil, hot) {
            case (true, true): .confirmed
            case (true, false): .notRerunning
            case (false, true): .unexplained
            case (false, false): .quiet
            }
            return Row(view: view, verdict: verdict, prediction: prediction,
                       hint: verdict == .unexplained ? Self.hint(for: report) : nil)
        }
    }

    /// What can make a view re-run without the analyzer predicting it: state it owns or observes, or its inputs.
    static func hint(for report: ViewReport) -> String {
        let owned = report.properties.filter { !$0.compared }.map { "@\($0.wrapper ?? "") \($0.name)" }
        let observed = report.properties.filter { $0.compared && $0.wrapper == "ObservedObject" }.map { "@ObservedObject \($0.name)" }
        let inputs = report.comparedProperties.filter { $0.wrapper != "ObservedObject" }.map(\.name)
        var parts: [String] = []
        if !(owned + observed).isEmpty { parts.append("state it owns or observes: \((owned + observed).joined(separator: ", "))") }
        if !inputs.isEmpty { parts.append("\(parts.isEmpty ? "" : "or ")a changing input: \(inputs.joined(separator: ", "))") }
        return parts.isEmpty ? "no inputs or state: a parent rebuilds it with a new identity" : parts.joined(separator: "; ")
    }

    public func render(duration: Double?) -> String {
        var lines: [String] = []
        if let duration { lines.append(String(format: "Recorded %.1f s. Hot = %d or more body runs.\n", duration, hotThreshold)) }
        lines.append("Runs  Total ms  View                                Verdict")
        for row in rows {
            let name = row.view.name.padding(toLength: 34, withPad: " ", startingAt: 0)
            lines.append(String(format: "%4d  %8.2f  %@  %@", row.view.count, row.view.totalMilliseconds, name, row.verdict.rawValue)
                         + ((row.prediction ?? row.hint).map { "  — \($0)" } ?? ""))
        }
        let count = { (verdict: Verdict) in rows.filter { $0.verdict == verdict }.count }
        lines.append("")
        lines.append("\(count(.confirmed)) confirmed, \(count(.unexplained)) unexplained, \(count(.notRerunning)) predicted but not re-running, \(count(.quiet)) quiet, \(count(.notAnalyzed)) not analyzed")
        if count(.unexplained) > 0 {
            lines.append("Unexplained: hot without a predicted cause. Look for state the view owns or observes (@State, @Observable reads, @Environment) or an input that really changes; confirm with `let _ = Self._printChanges()`.")
        }
        return lines.joined(separator: "\n")
    }
}
