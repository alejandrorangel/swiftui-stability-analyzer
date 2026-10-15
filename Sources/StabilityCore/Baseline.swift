import Foundation

/// The committed snapshot `dump` writes and `check` compares against, like the Compose analyzer's `.stability`
/// files. Paths and line numbers are left out so moving code doesn't churn the file.
///
///     ProfileView
///       skippable: no
///       user: User = stable
///       onTap: () -> Void = unstable
public struct Baseline: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var skippable: Skippability
        /// Compared properties only, by name: (type, stability).
        public var properties: [String: Property]
    }

    public struct Property: Equatable, Sendable {
        public var type: String
        public var stability: Stability
    }

    public var views: [String: Entry]

    static let header = "// SwiftUI stability baseline. Regenerate with `swiftui-stability dump`; checked by `swiftui-stability check`."

    public init(reports: [ViewReport]) {
        // Same-named declarations (different `#if` branches) get `#2`, `#3`… in declaration order.
        var seen: [String: Int] = [:]
        let keyed = reports.map { report -> (String, ViewReport) in
            seen[report.name, default: 0] += 1
            let count = seen[report.name]!
            return (count == 1 ? report.name : "\(report.name) #\(count)", report)
        }
        views = Dictionary(keyed.map { name, report in
            (name, Entry(
                skippable: report.skippable,
                properties: Dictionary(report.comparedProperties.map { ($0.name, Property(type: $0.type, stability: $0.stability)) },
                                       uniquingKeysWith: { first, _ in first })
            ))
        }, uniquingKeysWith: { first, _ in first })
    }

    public func render() -> String {
        var lines = [Self.header, ""]
        for name in views.keys.sorted() {
            let entry = views[name]!
            lines.append(name)
            lines.append("  skippable: \(entry.skippable.rawValue)")
            for property in entry.properties.keys.sorted() {
                let value = entry.properties[property]!
                lines.append("  \(property): \(value.type) = \(value.stability.rawValue)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public init(parsing text: String) throws(BaselineError) {
        views = [:]
        var current: String?
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("//") { continue }
            if !line.hasPrefix(" ") {
                current = line
                views[line] = Entry(skippable: .yes, properties: [:])
                continue
            }
            guard let view = current else { throw .malformed(line: number + 1) }
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("skippable: ") {
                guard let value = Skippability(rawValue: String(body.dropFirst("skippable: ".count))) else {
                    throw .malformed(line: number + 1)
                }
                views[view]!.skippable = value
            } else if let colon = body.range(of: ": "), let equals = body.range(of: " = ", options: .backwards),
                      let stability = Stability(rawValue: String(body[equals.upperBound...])) {
                let name = String(body[..<colon.lowerBound])
                views[view]!.properties[name] = Property(type: String(body[colon.upperBound..<equals.lowerBound]), stability: stability)
            } else {
                throw .malformed(line: number + 1)
            }
        }
    }
}

public enum BaselineError: Error, CustomStringConvertible {
    case malformed(line: Int)

    public var description: String {
        switch self {
        case .malformed(let line): "malformed baseline at line \(line)"
        }
    }
}

public struct BaselineChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, removed, changed }

    public var kind: Kind
    /// `ProfileView` or `ProfileView.onTap`.
    public var subject: String
    public var before: String?
    public var after: String?
    /// The change makes a view less skippable or a property less stable.
    public var regression: Bool

    /// `~ ProfileView.onTap: stable → unstable`, the Compose analyzer's notation.
    public var line: String {
        switch kind {
        case .added: "+ \(subject)\(after.map { " (\($0))" } ?? "")"
        case .removed: "- \(subject)"
        case .changed: "~ \(subject): \(before ?? "?") → \(after ?? "?")"
        }
    }
}

extension Baseline {
    /// What changed from `self` (the committed baseline) to `current`, regressions first.
    public func changes(to current: Baseline) -> [BaselineChange] {
        var changes: [BaselineChange] = []
        for name in Set(views.keys).union(current.views.keys).sorted() {
            switch (views[name], current.views[name]) {
            case (nil, let new?):
                // A new view that can't skip is still worth failing on.
                changes.append(.init(kind: .added, subject: name, before: nil, after: "skippable: \(new.skippable.rawValue)",
                                     regression: new.skippable == .no))
            case (_?, nil):
                changes.append(.init(kind: .removed, subject: name, before: nil, after: nil, regression: false))
            case (let old?, let new?):
                if old.skippable != new.skippable {
                    changes.append(.init(kind: .changed, subject: name, before: "skippable \(old.skippable.rawValue)",
                                         after: "skippable \(new.skippable.rawValue)", regression: new.skippable > old.skippable))
                }
                for property in Set(old.properties.keys).union(new.properties.keys).sorted() {
                    let subject = "\(name).\(property)"
                    switch (old.properties[property], new.properties[property]) {
                    case (nil, let added?):
                        changes.append(.init(kind: .added, subject: subject, before: nil, after: added.stability.rawValue,
                                             regression: added.stability == .unstable))
                    case (_?, nil):
                        changes.append(.init(kind: .removed, subject: subject, before: nil, after: nil, regression: false))
                    case (let before?, let after?) where before != after:
                        changes.append(.init(kind: .changed, subject: subject,
                                             before: "\(before.type) \(before.stability.rawValue)",
                                             after: "\(after.type) \(after.stability.rawValue)",
                                             regression: after.stability > before.stability))
                    default:
                        break
                    }
                }
            case (nil, nil):
                break
            }
        }
        return changes.sorted { $0.regression && !$1.regression }
    }
}
