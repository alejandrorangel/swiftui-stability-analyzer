import Foundation
import SwiftSyntax

public enum Analyzer {
    /// Analyzes every SwiftUI view declared in `files`. Types are resolved across all of them, so pass a whole
    /// module (or app) for the best results; anything outside is reported as `unknown`.
    public static func analyze(_ files: [SourceFile]) -> [ViewReport] {
        let index = TypeIndex(files: files)
        let classifier = Classifier(index: index)
        let suppressions = Dictionary(files.map { ($0.path, Suppressions(source: $0.text)) }, uniquingKeysWith: { a, _ in a })
        return index.views.map { view in
            var report = analyze(view, index: index, classifier: classifier)
            if let suppressions = suppressions[view.file] {
                let (kept, suppressed) = report.findings.reduce(into: ([Finding](), [Finding]())) { result, finding in
                    if suppressions.ignores(finding.rule, at: finding.line) {
                        result.1.append(finding)
                    } else {
                        result.0.append(finding)
                    }
                }
                report.findings = kept
                report.suppressed = suppressed
                report.stabilityWarningIgnored = suppressions.ignores("stability", at: view.line)
            }
            return report
        }
    }

    private static func analyze(_ view: TypeDecl, index: TypeIndex, classifier: Classifier) -> ViewReport {
        let scope = view.name.split(separator: ".").map(String.init)
        var findings: [Finding] = []
        let properties = view.storedProperties.map { property in
            report(property, view: view, scope: scope, index: index, classifier: classifier, findings: &findings)
        }

        let worst = properties.filter(\.compared).map(\.stability).max() ?? .stable
        let skippable: Skippability = switch worst {
        case .stable: .yes
        case .runtime, .unknown: .depends
        case .unstable: view.isEquatable ? .depends : .no
        }

        if let members = view.members, let converter = view.converter {
            let scanner = BodyScanner(converter: converter)
            scanner.walk(members)
            findings += scanner.findings
        }
        findings.sort { ($0.line, $0.rule) < ($1.line, $1.rule) }

        return ViewReport(
            name: view.name, kind: view.viewKind ?? .view, file: view.file, line: view.line, skippable: skippable,
            customEquality: view.isEquatable, properties: properties, findings: findings,
            suppressed: [], stabilityWarningIgnored: false
        )
    }

    /// Wrappers whose storage SwiftUI owns: not compared during diffing; they invalidate the view directly.
    private static let ownedWrappers: [String: String] = [
        "State": "owned by SwiftUI, not compared; writes re-run body",
        "StateObject": "owned by SwiftUI, not compared; any @Published change re-runs body",
        "EnvironmentObject": "not compared; any @Published change re-runs body",
        "Environment": "not compared; re-runs body when this environment value changes",
        "FocusState": "owned by SwiftUI, not compared",
        "AccessibilityFocusState": "owned by SwiftUI, not compared",
        "GestureState": "owned by SwiftUI, not compared",
        "AppStorage": "not compared; re-runs body when the defaults value changes",
        "SceneStorage": "not compared; re-runs body when the stored value changes",
        "Namespace": "owned by SwiftUI, not compared",
        "ScaledMetric": "not compared; re-runs body on Dynamic Type changes",
        "Query": "not compared; re-runs body when the fetched results change",
        "FetchRequest": "not compared; re-runs body when the fetched results change",
        "SectionedFetchRequest": "not compared; re-runs body when the fetched results change",
        "UIApplicationDelegateAdaptor": "owned by SwiftUI, not compared",
        "NSApplicationDelegateAdaptor": "owned by SwiftUI, not compared",
    ]

    private static func report(
        _ property: StoredProperty, view: TypeDecl, scope: [String], index: TypeIndex,
        classifier: Classifier, findings: inout [Finding]
    ) -> PropertyReport {
        func finding(_ rule: String, _ severity: Severity, _ message: String) {
            findings.append(Finding(rule: rule, severity: severity, message: message, line: property.line))
        }
        /// ObservableObject invalidates the whole body on any `@Published` change; worse when that's every frame.
        func observableObjectFindings() {
            let referenced = referencedType()
            if let referenced, let source = referenced.updateSource {
                finding("frequent-updates", .warning,
                        "`\(property.name)` (\(referenced.name)) looks like it publishes on a timer or display link (`\(source.text)` at line \(source.line)), and every @Published change re-runs all of \(entryPoint). Move the fast-changing value into a small child view that observes it, or into an @Observable property read only there. Confirm with `let _ = Self._printChanges()` in body.")
            } else {
                finding("observable-object", .info,
                        "`\(property.name)` is an ObservableObject: any @Published change re-runs all of \(entryPoint). If it publishes often (playback, timers, scrolling, gestures), confirm with `let _ = Self._printChanges()` in body and move the fast-changing value into a child view or an @Observable property.")
            }
        }
        func referencedType() -> TypeDecl? {
            guard case .named(let name, _) = property.type?.unwrapped,
                  let qualified = index.resolve(name, scope: scope) else { return nil }
            return index.types[qualified]
        }

        let entryPoint = "`\(view.name).\((view.viewKind ?? .view).entryPoint)`"
        var result = PropertyReport(
            name: property.name, type: property.typeText, wrapper: property.wrapper,
            stability: .stable, reason: "", compared: true, line: property.line
        )

        if let wrapper = property.wrapper, let reason = ownedWrappers[wrapper] {
            result.compared = false
            result.reason = reason
            let referenced = referencedType()
            if wrapper == "Environment", referenced?.isObservable == true {
                result.reason = "not compared; re-runs body only when properties it reads change"
            }
            if ["StateObject", "EnvironmentObject"].contains(wrapper) {
                observableObjectFindings()
            }
            if ["State", "Environment"].contains(wrapper), let referenced, referenced.isObservable,
               let source = referenced.updateSource {
                finding("frequent-updates", .info,
                        "`\(property.name)` (\(referenced.name)) looks like it updates on a timer or display link (`\(source.text)` at line \(source.line)). Only views that read the changing property re-run, but each of those re-runs per update: keep those reads in small child views.")
            }
            if wrapper == "State", let referenced, [.class, .actor].contains(referenced.kind), !referenced.isObservable {
                finding("state-plain-class", .warning,
                        "`\(property.name)` holds the class `\(referenced.name)` in @State, but it isn't @Observable: SwiftUI won't see its mutations.")
            }
            return result
        }

        switch property.wrapper {
        case "ObservedObject":
            result.reason = "compared by identity; any @Published change re-runs body"
            observableObjectFindings()
            if property.hasInitializer {
                finding("observed-object-initialized", .warning,
                        "`\(property.name)` is created inline with @ObservedObject, so a new instance replaces it whenever the parent re-renders. Use @StateObject (or @State with an @Observable class).")
            }
            return result
        case "Binding":
            result.reason = "@Binding: SwiftUI compares bindings itself"
            return result
        case "Bindable":
            result.reason = "@Bindable: compared by identity, reads are tracked"
            return result
        case let wrapper?:
            result.stability = .unknown
            result.reason = "custom property wrapper @\(wrapper): SwiftUI compares the wrapper's storage"
            return result
        case nil:
            break
        }

        guard let type = property.type else {
            result.stability = .unknown
            result.reason = "type not written out; add a type annotation"
            return result
        }
        let classification = classifier.classify(type, generics: view.genericParameters, scope: scope)
        result.stability = classification.stability
        result.reason = classification.reason

        if type.isFunction {
            if case .named(let name, _)? = closureResult(property.typeText), view.genericParameters.contains(name) {
                finding("stored-view-builder", .warning,
                        "`\(property.name)` stores a view-building closure. Store the built view instead (`let \(property.name): \(name)`, built in `init(@ViewBuilder \(property.name): () -> \(name))`): a view value is compared, a closure never is.")
            } else if !view.isEquatable {
                finding("closure-property", .warning,
                        "`\(property.name)` is a closure, which never compares equal, so \(entryPoint) re-runs whenever its parent's body does. If that matters here, make the type Equatable without the closure and apply `.equatable()`.")
            }
        }
        if case .named(let name, _) = type.unwrapped, stripModule(name) == "AnyView" {
            finding("any-view", .info, "`\(property.name)` is an AnyView: SwiftUI loses the view's type and structural identity. Prefer a generic `Content: View` parameter.")
        }
        return result
    }

    /// The `Content` in `() -> Content`, read from the written type.
    private static func closureResult(_ typeText: String) -> TypeRef? {
        guard let arrow = typeText.range(of: "->", options: .backwards) else { return nil }
        let result = typeText[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ")?"))
        return .named(result, [])
    }
}

/// Patterns inside a view's members that cost work or identity on every `body` evaluation.
private final class BodyScanner: SyntaxVisitor {
    let converter: SourceLocationConverter
    var findings: [Finding] = []

    init(converter: SourceLocationConverter) {
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    // Nested types are reported as views of their own.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let line = node.startLocation(converter: converter).line
        let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text

        if callee == "AnyView" {
            findings.append(Finding(rule: "any-view", severity: .info,
                                    message: "AnyView erases the view's type: SwiftUI can't diff it structurally. Prefer @ViewBuilder or `some View`.",
                                    line: line))
        }
        if callee == "ForEach" || callee == "List" {
            if let id = node.arguments.first(where: { $0.label?.text == "id" }),
               id.expression.trimmedDescription == "\\.self" {
                findings.append(Finding(rule: "foreach-id-self", severity: .info,
                                        message: "\(callee!)(id: \\.self) identifies rows by value: duplicate or edited values change identity and break animations. Prefer Identifiable or a stable id.",
                                        line: line))
            }
            if let data = node.arguments.first, data.label == nil {
                let text = data.expression.trimmedDescription
                if text.hasSuffix(".indices") || text.contains(".enumerated()") {
                    findings.append(Finding(rule: "foreach-indices", severity: .warning,
                                            message: "\(callee!) over `\(text)` ties row identity to position: inserting or deleting re-identifies every row after it.",
                                            line: line))
                } else if let transform = [".filter", ".sorted", ".map", ".compactMap", ".reversed()", ".prefix", ".shuffled()"]
                    .first(where: text.contains) {
                    findings.append(Finding(rule: "foreach-inline-transform", severity: .warning,
                                            message: "\(callee!) over `\(text)` runs \(transform) on every body evaluation and builds a new collection each time. Compute it once in the model.",
                                            line: line))
                }
            }
        }
        return .visitChildren
    }
}

/// `// swiftui-stability:ignore [rule, rule…]` silences findings on its own line and on the line after it.
/// Without rules it silences all of them; `stability` silences the "can't skip" warning on a declaration.
struct Suppressions {
    private var rulesByLine: [Int: Set<String>] = [:]
    private static let all = "*"

    init(source: String) {
        guard source.contains("swiftui-stability:ignore") else { return }
        for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let comment = line.range(of: "//"),
                  let directive = line[comment.upperBound...].range(of: "swiftui-stability:ignore") else { continue }
            let rules = line[directive.upperBound...]
                .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                .prefix { !$0.hasPrefix("-") && !$0.hasPrefix("—") }
            let set = rules.isEmpty ? [Self.all] : Set(rules)
            rulesByLine[index + 1, default: []].formUnion(set)
            rulesByLine[index + 2, default: []].formUnion(set)
        }
    }

    func ignores(_ rule: String, at line: Int) -> Bool {
        guard let rules = rulesByLine[line] else { return false }
        return rules.contains(rule) || rules.contains(Self.all)
    }
}
