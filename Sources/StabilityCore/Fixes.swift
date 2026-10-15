import Foundation
import SwiftParser
import SwiftSyntax

/// Source fixes for the Xcode Source Editor Extension: each takes a file's text and the cursor line (1-based)
/// and returns the new text, or throws `FixError` with a message to show when there's nothing safe to do.
public enum Fixes {
    /// `Child(action: { model.select(item) })` → `{ [model] in model.select(item) }`: the closure captures the
    /// values it reads instead of the view's `self`, so it compares equal across updates (measured).
    public static func captureClosureDependencies(in source: String, line: Int) throws -> String {
        let file = ParsedFile(source)
        guard let closure = file.innermost(ClosureExprSyntax.self, at: line, where: { $0.parent?.is(LabeledExprSyntax.self) == true || $0.parent?.is(FunctionCallExprSyntax.self) == true }),
              let owner = file.innermost(StructDeclSyntax.self, containing: Syntax(closure)) else {
            throw FixError("Put the cursor on a closure passed to a view, e.g. `Row(onTap: { … })`.")
        }
        let members = MemberNames(owner.memberBlock)
        let usage = ClosureUsage(closure: closure, members: members)
        if let method = usage.methods.first {
            throw FixError("The closure calls `\(method)`, a method of `\(owner.name.text)`, so it needs `self`. Move the action to a model object (e.g. `model.\(method)()`), then run this again.")
        }
        if usage.capturesSelfExplicitly {
            throw FixError("The closure uses `self` explicitly; capture the values it needs instead.")
        }
        if let written = usage.written.first {
            throw FixError("The closure changes `\(written)`, so capturing a copy would break it. Move the change to a model object, or pass a Binding to the child.")
        }
        guard !usage.read.isEmpty else {
            throw FixError("This closure doesn't read anything from `\(owner.name.text)`: it already compares equal.")
        }
        let names = usage.read.joined(separator: ", ")
        if let signature = closure.signature {
            if let capture = signature.capture {
                let existing = capture.items.map(\.trimmedDescription)
                let insertion = (existing.isEmpty ? "" : ", ") + usage.read.filter { !existing.contains($0) }.joined(separator: ", ")
                return file.replacing(capture.rightSquare.positionAfterSkippingLeadingTrivia, length: 0, with: insertion)
            }
            return file.replacing(signature.positionAfterSkippingLeadingTrivia, length: 0, with: "[\(names)] ")
        }
        return file.replacing(closure.leftBrace.endPositionBeforeTrailingTrivia, length: 0, with: " [\(names)] in")
    }

    /// Adds `Equatable` to the view under the cursor with a `==` that compares everything except closures and the
    /// storage SwiftUI owns. SwiftUI uses that `==` to decide whether to re-run `body` (measured, with or without
    /// `.equatable()`).
    public static func makeEquatable(in source: String, line: Int) throws -> String {
        let file = ParsedFile(source)
        guard let decl = file.innermost(StructDeclSyntax.self, at: line) else {
            throw FixError("Put the cursor inside the view's declaration.")
        }
        let conformances = decl.inheritanceClause?.inheritedTypes.map { stripModule($0.type.trimmedDescription) } ?? []
        if conformances.contains("Equatable") {
            throw FixError("`\(decl.name.text)` is already Equatable.")
        }
        let index = TypeIndex(files: [SourceFile(path: "buffer.swift", text: source)])
        let scope = decl.name.text
        var comparisons: [String] = []
        var skipped: [String] = []
        let owned: Set<String> = ["State", "StateObject", "Environment", "EnvironmentObject", "FocusState",
                                  "AccessibilityFocusState", "GestureState", "AppStorage", "SceneStorage",
                                  "Namespace", "ScaledMetric", "Query", "FetchRequest", "SectionedFetchRequest"]
        for property in index.types.values.first(where: { $0.name.hasSuffix(scope) && $0.line == file.line(of: decl) })?.storedProperties ?? [] {
            if let wrapper = property.wrapper, owned.contains(wrapper) { continue }
            if property.type?.isFunction == true {
                skipped.append(property.name)
                continue
            }
            let isObject: Bool = {
                if property.wrapper == "ObservedObject" || property.wrapper == "Bindable" { return true }
                guard case .named(let name, _)? = property.type?.unwrapped,
                      let qualified = index.resolve(name, scope: [scope]), let type = index.types[qualified] else { return false }
                return type.kind == .class || type.kind == .actor
            }()
            comparisons.append(isObject ? "lhs.\(property.name) === rhs.\(property.name)" : "lhs.\(property.name) == rhs.\(property.name)")
        }

        let indent = file.indentation(ofLineContaining: decl.structKeyword.positionAfterSkippingLeadingTrivia)
        let inner = indent + "    "
        let comparison = comparisons.isEmpty ? "true" : comparisons.joined(separator: "\n\(inner)        && ")
        var function = "\n"
        if !skipped.isEmpty {
            function += "\(inner)// Leaves out \(skipped.map { "`\($0)`" }.joined(separator: ", ")): a new closure shouldn't re-run body.\n"
        }
        function += "\(inner)nonisolated static func == (lhs: Self, rhs: Self) -> Bool {\n\(inner)    \(comparison)\n\(inner)}\n"

        // Before the closing brace's line, so the brace keeps its indentation.
        let brace = decl.memberBlock.rightBrace.positionAfterSkippingLeadingTrivia
        guard file.line(ofPosition: brace) > file.line(of: decl) else {
            throw FixError("Put `\(decl.name.text)`'s closing brace on its own line first.")
        }
        var result = file.replacing(AbsolutePosition(utf8Offset: file.offset(ofLine: file.line(ofPosition: brace))),
                                    length: 0, with: function)
        // The conformance: insert into the (already reparsed) declaration's inheritance clause.
        let updated = ParsedFile(result)
        guard let updatedDecl = updated.innermost(StructDeclSyntax.self, at: line) else { return result }
        if let clause = updatedDecl.inheritanceClause, let last = clause.inheritedTypes.last {
            result = updated.replacing(last.endPositionBeforeTrailingTrivia, length: 0, with: ", Equatable")
        } else {
            result = updated.replacing(updatedDecl.name.endPositionBeforeTrailingTrivia, length: 0, with: ": Equatable")
        }
        return result
    }

    static let printChanges = "let _ = Self._printChanges()"

    /// Adds `let _ = Self._printChanges()` as the first line of the view's `body` (or a modifier's
    /// `body(content:)`), or removes it if it's there. SwiftUI then logs why each body run happened.
    public static func togglePrintChanges(in source: String, line: Int) throws -> String {
        let file = ParsedFile(source)
        guard let decl = file.innermost(StructDeclSyntax.self, at: line) else {
            throw FixError("Put the cursor inside a view's declaration.")
        }
        let body: CodeBlockItemListSyntax?
        let openingBrace: TokenSyntax?
        if let variable = decl.memberBlock.members.compactMap({ $0.decl.as(VariableDeclSyntax.self) })
            .first(where: { $0.bindings.first?.pattern.trimmedDescription == "body" }),
           case .getter(let items)? = variable.bindings.first?.accessorBlock?.accessors {
            body = items
            openingBrace = variable.bindings.first?.accessorBlock?.leftBrace
        } else if let function = decl.memberBlock.members.compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
            .first(where: { $0.name.text == "body" }), let block = function.body {
            body = block.statements
            openingBrace = block.leftBrace
        } else {
            body = nil
            openingBrace = nil
        }
        guard let body, let openingBrace else {
            throw FixError("`\(decl.name.text)` has no `body` to trace.")
        }

        if let first = body.first, first.trimmedDescription.hasPrefix(printChanges) {
            let start = first.positionAfterSkippingLeadingTrivia.utf8Offset
            let end = (first.semicolon?.endPosition ?? first.endPositionBeforeTrailingTrivia).utf8Offset
            let bytes = Array(source.utf8)
            let isBlank = { (byte: UInt8) in byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") }
            var lineStart = start
            while lineStart > 0, isBlank(bytes[lineStart - 1]) { lineStart -= 1 }
            var after = end
            while after < bytes.count, isBlank(bytes[after]) { after += 1 }
            if (lineStart == 0 || bytes[lineStart - 1] == UInt8(ascii: "\n")), after < bytes.count, bytes[after] == UInt8(ascii: "\n") {
                // On a line of its own: remove the line.
                return file.replacing(AbsolutePosition(utf8Offset: lineStart), length: after + 1 - lineStart, with: "")
            }
            return file.replacing(AbsolutePosition(utf8Offset: start), length: after - start, with: "")
        }

        guard let first = body.first else {
            return file.replacing(openingBrace.endPositionBeforeTrailingTrivia, length: 0, with: " \(printChanges)")
        }
        let firstLine = file.line(ofPosition: first.positionAfterSkippingLeadingTrivia)
        if firstLine == file.line(ofPosition: openingBrace.positionAfterSkippingLeadingTrivia) {
            // `var body: some View { Text("") }`
            return file.replacing(first.positionAfterSkippingLeadingTrivia, length: 0, with: "\(printChanges); ")
        }
        let indent = file.indentation(ofLineContaining: first.positionAfterSkippingLeadingTrivia)
        return file.replacing(first.positionAfterSkippingLeadingTrivia, length: 0, with: "\(printChanges)\n\(indent)")
    }

    /// Inserts `// swiftui-stability:ignore <rule> — ` above the line with a finding, for the reason to be typed.
    public static func ignoreFinding(in source: String, line: Int) throws -> String {
        let reports = Analyzer.analyze([SourceFile(path: "buffer.swift", text: source)])
        var rules = reports.flatMap(\.findings).filter { $0.line == line }.map(\.rule)
        if reports.contains(where: { $0.line == line && $0.skippable == .no }) { rules.append("stability") }
        guard !rules.isEmpty else {
            throw FixError("No stability finding on this line. (Findings that need other files, such as types declared elsewhere, aren't visible to the editor extension.)")
        }
        let file = ParsedFile(source)
        let lineStart = file.offset(ofLine: line)
        let bytes = Array(source.utf8)
        var end = lineStart
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        let indent = String(decoding: bytes[lineStart..<end], as: UTF8.self)
        var unique: [String] = []
        for rule in rules where !unique.contains(rule) { unique.append(rule) }
        return file.replacing(AbsolutePosition(utf8Offset: lineStart), length: 0,
                              with: "\(indent)// swiftui-stability:ignore \(unique.joined(separator: ", ")) — \n")
    }
}

public struct FixError: Error, CustomStringConvertible, LocalizedError {
    public var description: String
    public var errorDescription: String? { description }

    init(_ message: String) {
        description = message
    }
}

/// A parsed buffer with position helpers.
private struct ParsedFile {
    let source: String
    let tree: SourceFileSyntax
    let converter: SourceLocationConverter

    init(_ source: String) {
        self.source = source
        tree = Parser.parse(source: source)
        converter = SourceLocationConverter(fileName: "buffer.swift", tree: tree)
    }

    func line(of node: some SyntaxProtocol) -> Int {
        node.startLocation(converter: converter).line
    }

    func line(ofPosition position: AbsolutePosition) -> Int {
        converter.location(for: position).line
    }

    func offset(ofLine line: Int) -> Int {
        converter.position(ofLine: line, column: 1).utf8Offset
    }

    /// The innermost node of a type whose lines include `line`.
    func innermost<T: SyntaxProtocol>(_ type: T.Type, at line: Int, where filter: (T) -> Bool = { _ in true }) -> T? {
        let finder = LineFinder(line: line, converter: converter)
        finder.walk(tree)
        return finder.nodes.reversed().lazy.compactMap { $0.as(T.self) }.first(where: filter)
    }

    func innermost<T: SyntaxProtocol>(_ type: T.Type, containing node: Syntax) -> T? {
        var current = node.parent
        while let candidate = current {
            if let match = candidate.as(T.self) { return match }
            current = candidate.parent
        }
        return nil
    }

    func indentation(ofLineContaining position: AbsolutePosition) -> String {
        let start = offset(ofLine: line(ofPosition: position))
        let bytes = Array(source.utf8)
        var end = start
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    func replacing(_ position: AbsolutePosition, length: Int, with text: String) -> String {
        var bytes = Array(source.utf8)
        bytes.replaceSubrange(position.utf8Offset..<(position.utf8Offset + length), with: Array(text.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Every node whose lines include `line`, outermost first.
private final class LineFinder: SyntaxAnyVisitor {
    let line: Int
    let converter: SourceLocationConverter
    var nodes: [Syntax] = []

    init(line: Int, converter: SourceLocationConverter) {
        self.line = line
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
        let start = node.startLocation(converter: converter).line
        let end = node.endLocation(converter: converter).line
        guard start <= line, line <= end else { return .skipChildren }
        nodes.append(node)
        return .visitChildren
    }
}

/// A view's properties and methods; locals in its bodies shadow them (see `BodyScanner`).
struct MemberNames {
    let properties: Set<String>
    let methods: Set<String>

    init(_ members: MemberBlockSyntax) {
        let decls = members.members.map(\.decl)
        methods = Set(decls.compactMap { $0.as(FunctionDeclSyntax.self)?.name.text })
        properties = Set(decls.compactMap { $0.as(VariableDeclSyntax.self) }
            .filter { !$0.modifiers.contains { $0.name.text == "static" } }
            .flatMap(\.bindings).compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text })
            .subtracting(["body"])
    }
}

/// Which of the view's members a closure reads, writes or calls.
private final class ClosureUsage: SyntaxVisitor {
    let members: MemberNames
    var read: [String] = []
    var written: [String] = []
    var methods: [String] = []
    var capturesSelfExplicitly = false
    private var shadowed: Set<String> = []

    init(closure: ClosureExprSyntax, members: MemberNames) {
        self.members = members
        super.init(viewMode: .sourceAccurate)
        for item in closure.signature?.capture?.items ?? [] {
            let name = item.trimmedDescription.replacingOccurrences(of: "weak ", with: "")
                .replacingOccurrences(of: "unowned ", with: "")
                .split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if name == "self" { capturesSelfExplicitly = true }
            shadowed.insert(name)
        }
        if case .simpleInput(let parameters)? = closure.signature?.parameterClause {
            shadowed.formUnion(parameters.map(\.name.text))
        } else if case .parameterClause(let clause)? = closure.signature?.parameterClause {
            shadowed.formUnion(clause.parameters.map { ($0.secondName ?? $0.firstName).text })
        }
        walk(closure.statements)
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        shadowed.insert(node.identifier.text)
        return .visitChildren
    }

    override func visit(_ node: ClosureShorthandParameterSyntax) -> SyntaxVisitorContinueKind {
        shadowed.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() where index > 0 {
            let isAssignment = element.is(AssignmentExprSyntax.self)
                || (element.as(BinaryOperatorExprSyntax.self).map { op in
                    op.operator.text.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(op.operator.text)
                } ?? false)
            if isAssignment, let name = rootName(elements[index - 1]) { written.append(name) }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // `isOn.toggle()`, `items.append(x)`: mutating a member.
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base,
           ["toggle", "append", "insert", "remove", "removeAll", "removeLast", "removeFirst"].contains(member.declName.baseName.text),
           let name = rootName(base) {
            written.append(name)
        }
        return .visitChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.parent?.as(MemberAccessExprSyntax.self), member.declName.id == node.id { return .visitChildren }
        var name = node.baseName.text
        if name == "self" {
            capturesSelfExplicitly = true
            return .visitChildren
        }
        let projected = name.hasPrefix("$")
        if projected || name.hasPrefix("_") { name.removeFirst() }
        guard !shadowed.contains(name) else { return .visitChildren }
        if members.methods.contains(name) {
            if !methods.contains(name) { methods.append(name) }
        } else if members.properties.contains(name) {
            // `$flag` passes a binding that writes the view's state.
            if projected { written.append(name) } else if !read.contains(name) { read.append(name) }
        }
        return .visitChildren
    }

    /// `x`, `x.y`, `x[i]` → `x` when it's one of the view's properties.
    private func rootName(_ expr: ExprSyntax) -> String? {
        var current = expr
        while true {
            if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
                current = base
            } else if let subscriptCall = current.as(SubscriptCallExprSyntax.self) {
                current = subscriptCall.calledExpression
            } else if let reference = current.as(DeclReferenceExprSyntax.self) {
                let name = reference.baseName.text
                return members.properties.contains(name) && !shadowed.contains(name) ? name : nil
            } else {
                return nil
            }
        }
    }
}
