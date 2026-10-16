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
        let bodyReads = view.members.flatMap { members in view.converter.map { BodyReads.find(in: members, converter: $0) } } ?? [:]
        let properties = view.storedProperties.map { property in
            report(property, view: view, scope: scope, index: index, classifier: classifier, bodyReads: bodyReads, findings: &findings)
        }

        let worst = properties.filter(\.compared).map(\.stability).max() ?? .stable
        // Measured on iOS 27: SwiftUI uses an Equatable view's own `==`, with or without `.equatable()`.
        let skippable: Skippability = if view.isEquatable {
            .yes
        } else {
            switch worst {
            case .stable: .yes
            case .runtime, .unknown: .depends
            case .unstable: .no
            }
        }

        if let members = view.members, let converter = view.converter {
            let scanner = BodyScanner(converter: converter, members: members, index: index, scope: scope, owner: view.name)
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
        classifier: Classifier, bodyReads: [String: BodyReads.Read], findings: inout [Finding]
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
            // A class in @State only goes wrong when body reads it: SwiftUI doesn't re-run body when it changes.
            // Holding one to pass to children, or for event handlers only, is a deliberate pattern.
            if wrapper == "State", let referenced, [.class, .actor].contains(referenced.kind), !referenced.isObservable,
               let read = bodyReads[property.name] {
                if referenced.conformances.contains("ObservableObject") {
                    finding("state-observable-object", .warning,
                            "`\(property.name)` is an ObservableObject held in @State, and body reads `\(read.text)` (line \(read.line)), but @State doesn't subscribe to it: this view won't update when it publishes. Use @StateObject if it's created here, or read it in a child that observes it with @ObservedObject.")
                } else {
                    finding("state-plain-class", .warning,
                            "Body reads `\(read.text)` (line \(read.line)), but `\(referenced.name)` isn't observable, so changing it won't re-run body. Make it @Observable, or keep the value in @State itself.")
                }
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
                        "`\(property.name)` stores a view-building closure. Callers usually build content from their own state (`\(view.name) { Text(title) }`), which captures their `self`, so \(entryPoint) re-runs on every caller update. Store the built view instead (`let \(property.name): \(name)`, built in `init(@ViewBuilder \(property.name): () -> \(name))`).")
            } else if !view.isEquatable {
                finding("closure-property", .info,
                        "`\(property.name)` is a closure. SwiftUI compares closures by what they capture: a caller passing a closure that reads its own state (`self`) makes \(entryPoint) re-run on every caller update (see `closure-captures-self` at call sites). If that's unavoidable and this view is expensive, make it Equatable without the closure.")
            }
        }
        if case .named(let name, _) = type.unwrapped, stripModule(name) == "AnyView" {
            finding("any-view", .warning, "`\(property.name)` is an AnyView, which never compares equal (measured), so \(entryPoint) re-runs on every parent update. Prefer a generic `Content: View` parameter.")
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
    let index: TypeIndex
    let scope: [String]
    let owner: String
    /// The owner's properties and methods: referencing one inside a closure captures `self`.
    let memberNames: Set<String>
    let methodNames: Set<String>
    var findings: [Finding] = []

    init(converter: SourceLocationConverter, members: MemberBlockSyntax, index: TypeIndex, scope: [String], owner: String) {
        self.converter = converter
        self.index = index
        self.scope = scope
        self.owner = owner
        let decls = members.members.map(\.decl)
        methodNames = Set(decls.compactMap { $0.as(FunctionDeclSyntax.self)?.name.text })
        let properties = decls.compactMap { $0.as(VariableDeclSyntax.self) }
            .filter { !$0.modifiers.contains { $0.name.text == "static" } }
            .flatMap(\.bindings).compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
        // `let model = self.model` in `body` and then `{ model.select(1) }` captures the local copy, not `self`.
        let locals = LocalNames()
        for decl in decls {
            if let function = decl.as(FunctionDeclSyntax.self), let body = function.body { locals.walk(body) }
            if let variable = decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings { if let accessors = binding.accessorBlock { locals.walk(accessors) } }
            }
        }
        memberNames = methodNames.union(properties).subtracting(locals.names)
        super.init(viewMode: .sourceAccurate)
    }

    /// `Child(action: { flag.toggle() })`, `Child(action: noop)`, `Card { Text(title) }`: a closure argument that
    /// captures the caller's `self` differs on every caller update, so the child re-runs every time (measured).
    private func checkCapturedSelf(_ call: FunctionCallExprSyntax, child: String, line: Int) {
        var arguments: [(label: String, expr: ExprSyntax)] = call.arguments.map { ($0.label?.text ?? "_", $0.expression) }
        if let trailing = call.trailingClosure { arguments.append(("trailing closure", ExprSyntax(trailing))) }
        arguments += call.additionalTrailingClosures.map { ($0.label.text, ExprSyntax($0.closure)) }

        for (label, expr) in arguments {
            let reason: String?
            if let closure = expr.as(ClosureExprSyntax.self) {
                reason = SelfCaptureScanner.capture(in: closure, memberNames: memberNames).map { "reads `\($0)`" }
            } else if let reference = expr.as(DeclReferenceExprSyntax.self), methodNames.contains(reference.baseName.text) {
                reason = "is the method `\(reference.baseName.text)` of this view"
            } else if let member = expr.as(MemberAccessExprSyntax.self), member.base?.trimmedDescription == "self",
                      methodNames.contains(member.declName.baseName.text) {
                reason = "is the method `\(member.declName.baseName.text)` of this view"
            } else {
                reason = nil
            }
            guard let reason else { continue }
            let argument = label == "trailing closure" ? "its trailing closure" : "`\(label):`"
            findings.append(Finding(rule: "closure-captures-self", severity: .warning,
                                    message: "The closure passed to `\(child)` as \(argument) \(reason), so it captures `self` and differs whenever `\(owner)`'s own state or inputs change: `\(child)` re-runs each time. Capture only what it needs, e.g. `{ [model] in model.select(item) }`, or move the action to a model object.",
                                    line: line))
        }
    }

    // Nested types are reported as views of their own.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let line = node.startLocation(converter: converter).line
        let callee = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text

        // An Equatable child decides with its own `==`, which usually leaves closures out (measured).
        if let callee, let qualified = index.resolve(callee, scope: scope), let child = index.types[qualified],
           child.viewKind != nil, !child.isEquatable {
            checkCapturedSelf(node, child: callee, line: line)
        }
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

/// `// swiftui-stability:ignore [rule, rule…] — reason` silences findings.
///
/// - On a comment-only line, it applies to the first code line after its contiguous `//` block (so the reason can
///   wrap over several lines), and to any attribute-only lines that start that declaration.
/// - At the end of a code line, it applies to that line.
///
/// Without rules it silences all of them; `stability` silences the "can't skip" warning on a declaration.
struct Suppressions {
    private var rulesByLine: [Int: Set<String>] = [:]
    private static let all = "*"

    init(source: String) {
        guard source.contains("swiftui-stability:ignore") else { return }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() {
            guard let comment = line.range(of: "//"),
                  let directive = line[comment.upperBound...].range(of: "swiftui-stability:ignore") else { continue }
            let rules = line[directive.upperBound...]
                .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                .prefix { !$0.hasPrefix("-") && !$0.hasPrefix("—") && !$0.hasPrefix("(") }
            let set = rules.isEmpty ? [Self.all] : Set(rules)
            // Line numbers are 1-based.
            guard line.hasPrefix("//") else {
                rulesByLine[index + 1, default: []].formUnion(set)
                continue
            }
            var target = index + 1
            while target < lines.count, lines[target].hasPrefix("//") { target += 1 }
            // A blank line ends the comment block: the directive isn't attached to any code.
            guard target < lines.count, !lines[target].isEmpty else { continue }
            rulesByLine[target + 1, default: []].formUnion(set)
            // `@MainActor` on its own line before `@StateObject var x`: the finding is on the declaration line.
            while target + 1 < lines.count, isAttributeOnly(lines[target]) {
                target += 1
                rulesByLine[target + 1, default: []].formUnion(set)
            }
        }
    }

    private func isAttributeOnly(_ line: String) -> Bool {
        line.hasPrefix("@") && !line.contains(" var ") && !line.contains(" let ")
            && !line.contains("struct ") && !line.contains("class ") && !line.contains("func ")
    }

    func ignores(_ rule: String, at line: Int) -> Bool {
        guard let rules = rulesByLine[line] else { return false }
        return rules.contains(rule) || rules.contains(Self.all)
    }
}

/// Finds the first reference to the enclosing view's members (or `self`) inside a closure, ignoring names the
/// closure binds itself (parameters, locals, capture list).
private final class SelfCaptureScanner: SyntaxVisitor {
    let memberNames: Set<String>
    var shadowed: Set<String> = []
    var found: String?

    static func capture(in closure: ClosureExprSyntax, memberNames: Set<String>) -> String? {
        let scanner = SelfCaptureScanner(memberNames: memberNames)
        if let captures = closure.signature?.capture?.items {
            for item in captures {
                let text = item.trimmedDescription
                    .replacingOccurrences(of: "weak ", with: "").replacingOccurrences(of: "unowned ", with: "")
                let name = text.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
                if name == "self" { return "self" }
                scanner.shadowed.insert(name)
            }
        }
        scanner.walk(closure.statements)
        return scanner.found
    }

    private init(memberNames: Set<String>) {
        self.memberNames = memberNames
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        shadowed.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureParameterSyntax) -> SyntaxVisitorContinueKind {
        shadowed.insert((node.secondName ?? node.firstName).text)
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        shadowed.insert(node.identifier.text)
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard found == nil else { return .skipChildren }
        // `item.title`: `title` is a member of `item`, not of the view.
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id {
            return .visitChildren
        }
        var name = node.baseName.text
        if name.hasPrefix("$") || name.hasPrefix("_") { name.removeFirst() }
        if name == "self" || (memberNames.contains(name) && !shadowed.contains(name)) {
            found = name
        }
        return .visitChildren
    }
}

/// Names bound by `let` / `var` inside function and accessor bodies.
private final class LocalNames: SyntaxVisitor {
    var names: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.identifier.text)
        return .visitChildren
    }
}

/// Properties of the view's members read while `body` is computed (`box.offset`, `self.store.items`), by member
/// name, first read only. Reads inside event handlers (`on…` modifiers, `Button` actions, `task`, `Task {}`,
/// `action:` / `perform:` arguments) run later, so they don't count; passing the member itself (`Child(store:
/// store)`) isn't a read.
struct BodyReads {
    struct Read {
        var text: String
        var line: Int
    }

    static func find(in members: MemberBlockSyntax, converter: SourceLocationConverter) -> [String: Read] {
        let scanner = Scanner(converter: converter)
        scanner.walk(members)
        return scanner.reads
    }

    private final class Scanner: SyntaxVisitor {
        let converter: SourceLocationConverter
        var reads: [String: Read] = [:]

        init(converter: SourceLocationConverter) {
            self.converter = converter
            super.init(viewMode: .sourceAccurate)
        }

        // Nested types are separate views.
        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
            Self.isEventHandler(node) ? .skipChildren : .visitChildren
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            guard let base = node.base else { return .visitChildren }
            var name: String?
            if let reference = base.as(DeclReferenceExprSyntax.self), reference.baseName.text != "self" {
                name = reference.baseName.text
            } else if let inner = base.as(MemberAccessExprSyntax.self), inner.base?.trimmedDescription == "self" {
                name = inner.declName.baseName.text
            }
            if let name, reads[name] == nil {
                reads[name] = Read(text: node.trimmedDescription, line: node.startLocation(converter: converter).line)
            }
            return .visitChildren
        }

        static let handlerLabels: Set<String> = ["action", "perform", "onCommit", "onEditingChanged", "completion"]

        /// `.onTapGesture { }`, `.onChange(of:) { }`, `.task { }`, `Button { action } label: { }`, `Task { }`,
        /// `DragGesture().onChanged { }`, `Button(action: { })`.
        static func isEventHandler(_ closure: ClosureExprSyntax) -> Bool {
            if let argument = closure.parent?.as(LabeledExprSyntax.self), let label = argument.label?.text {
                return handlerLabels.contains(label) || label.hasPrefix("on")
            }
            let call: FunctionCallExprSyntax?
            if let direct = closure.parent?.as(FunctionCallExprSyntax.self) {
                call = direct
            } else if let labeled = closure.parent?.as(MultipleTrailingClosureElementSyntax.self) {
                // `label:` / `content:` trailing closures build views; `action:` doesn't.
                if handlerLabels.contains(labeled.label.text) { return true }
                return false
            } else {
                call = nil
            }
            guard let call else { return false }
            let name = call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                ?? call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""
            if name.hasPrefix("on") || name == "task" || name == "Task" || name == "withAnimation" { return true }
            // `Button("Title") { action }` and `Button { action } label: { … }`: the first trailing closure acts.
            if name == "Button", call.trailingClosure?.id == closure.id { return true }
            return false
        }
    }
}
