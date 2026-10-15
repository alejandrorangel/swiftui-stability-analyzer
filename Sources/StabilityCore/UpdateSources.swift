import SwiftSyntax

/// Finds a display link, timer or polling loop in a class that writes observed state on every tick, which
/// re-runs the body of each view observing it at that rate.
///
/// A tick source counts only if what it runs writes a tracked property (directly or through the class's own
/// methods). A write in a block that then leaves the loop (`finished = true; break`) is one-shot and doesn't count,
/// and a `sleep` outside any loop is a delay, not a tick.
struct UpdateSourceFinder {
    let tracked: Set<String>
    let converter: SourceLocationConverter
    /// Method bodies by base name (overloads merged).
    private var methods: [String: [Syntax]] = [:]

    init(members: [MemberBlockItemSyntax], tracked: Set<String>, converter: SourceLocationConverter) {
        self.tracked = tracked
        self.converter = converter
        for member in members {
            if let function = member.decl.as(FunctionDeclSyntax.self), let body = function.body {
                methods[function.name.text, default: []].append(Syntax(body))
            }
        }
        self.members = members
    }

    private let members: [MemberBlockItemSyntax]

    func find() -> (text: String, line: Int)? {
        guard !tracked.isEmpty else { return nil }
        let markers = MarkerScanner()
        for member in members { markers.walk(member) }
        for marker in markers.found {
            guard let region = region(for: marker) else { continue }
            if writesTrackedState(region) {
                return (marker.text, marker.node.startLocation(converter: converter).line)
            }
        }
        return nil
    }

    /// What a tick runs: the enclosing loop for a sleep; the whole statement for a display link or timer (its
    /// `#selector`, `sink` or handler closure).
    private func region(for marker: Marker) -> Syntax? {
        var node: Syntax? = marker.node.parent
        var statement: Syntax?
        while let current = node {
            if current.is(FunctionDeclSyntax.self) || current.is(InitializerDeclSyntax.self) || current.is(MemberBlockItemSyntax.self) {
                break
            }
            if marker.isSleep, current.is(WhileStmtSyntax.self) || current.is(RepeatStmtSyntax.self) || current.is(ForStmtSyntax.self) {
                return current
            }
            if statement == nil, current.is(CodeBlockItemSyntax.self) { statement = current }
            node = current.parent
        }
        if marker.isSleep { return nil }
        // A display link or timer stored in a property initializer: the statement is the declaration itself.
        return statement ?? node
    }

    private func writesTrackedState(_ region: Syntax) -> Bool {
        var visited: Set<String> = []
        var pending = [region]
        while let next = pending.popLast() {
            let scanner = WriteScanner(tracked: tracked, root: next)
            scanner.walk(next)
            if scanner.writes { return true }
            for call in scanner.calls where !visited.contains(call) {
                visited.insert(call)
                pending += methods[call] ?? []
            }
        }
        return false
    }
}

private struct Marker {
    var node: Syntax
    var text: String
    var isSleep: Bool
}

private final class MarkerScanner: SyntaxVisitor {
    var found: [Marker] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if ["CADisplayLink", "DispatchSourceTimer"].contains(node.baseName.text) {
            found.append(Marker(node: Syntax(node), text: node.baseName.text, isSleep: false))
        }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.declName.baseName.text
        let base = node.base?.trimmedDescription ?? ""
        if name == "sleep" {
            found.append(Marker(node: Syntax(node), text: "\(base).sleep", isSleep: true))
        } else if base == "Timer", ["publish", "scheduledTimer"].contains(name) {
            found.append(Marker(node: Syntax(node), text: "Timer.\(name)", isSleep: false))
        } else if base == "DispatchSource", name == "makeTimerSource" {
            found.append(Marker(node: Syntax(node), text: "DispatchSource.makeTimerSource", isSleep: false))
        }
        return .visitChildren
    }
}

/// Assignments to tracked properties, mutating calls on them, `objectWillChange.send()`, and the class's own
/// methods called (including `#selector(method)`).
private final class WriteScanner: SyntaxVisitor {
    let tracked: Set<String>
    let root: Syntax
    var writes = false
    var calls: Set<String> = []

    private static let mutatingMethods: Set<String> = [
        "append", "insert", "remove", "removeAll", "removeFirst", "removeLast", "removeValue", "updateValue",
        "toggle", "sort", "reverse", "shuffle", "formUnion", "formIntersection", "subtract", "merge", "popLast",
    ]

    init(tracked: Set<String>, root: Syntax) {
        self.tracked = tracked
        self.root = root
        super.init(viewMode: .sourceAccurate)
    }

    /// A block that ends by leaving (`break`, `return`, `throw`) runs once, not per tick.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        if Syntax(node) != root, let last = node.statements.last?.item,
           last.is(BreakStmtSyntax.self) || last.is(ReturnStmtSyntax.self) || last.is(ThrowStmtSyntax.self) {
            return .skipChildren
        }
        return .visitChildren
    }

    /// The parser doesn't fold operators: `x += 1` arrives as the sequence `[x, +=, 1]`.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() where index > 0 && isAssignmentOperator(element) {
            if let property = trackedRoot(elements[index - 1]), tracked.contains(property) {
                writes = true
            }
        }
        return writes ? .skipChildren : .visitChildren
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if isAssignmentOperator(node.operator), let property = trackedRoot(node.leftOperand), tracked.contains(property) {
            writes = true
        }
        return writes ? .skipChildren : .visitChildren
    }

    private func isAssignmentOperator(_ expr: ExprSyntax) -> Bool {
        if expr.is(AssignmentExprSyntax.self) { return true }
        guard let op = expr.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
        return op.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(op)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self) {
            calls.insert(callee.baseName.text)
        } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
            let name = member.declName.baseName.text
            if let base = member.base {
                if isSelf(base) {
                    calls.insert(name)
                } else if name == "send", base.trimmedDescription.hasSuffix("objectWillChange") {
                    writes = true
                } else if Self.mutatingMethods.contains(name), let property = trackedRoot(base), tracked.contains(property) {
                    writes = true
                }
            }
        }
        return writes ? .skipChildren : .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "selector", let target = node.arguments.first?.expression {
            let name = target.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                ?? target.as(DeclReferenceExprSyntax.self)?.baseName.text
            if let name { calls.insert(name) }
        }
        return .visitChildren
    }

    /// `x`, `self.x`, `self?.x.y`, `x[i]` → `x`.
    private func trackedRoot(_ expr: ExprSyntax) -> String? {
        var current = expr
        var lastMember: String?
        while true {
            if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
                lastMember = member.declName.baseName.text
                if isSelf(base) { return lastMember }
                current = base
            } else if let subscriptCall = current.as(SubscriptCallExprSyntax.self) {
                current = subscriptCall.calledExpression
            } else if let optional = current.as(OptionalChainingExprSyntax.self) {
                current = optional.expression
            } else if let forced = current.as(ForceUnwrapExprSyntax.self) {
                current = forced.expression
            } else if let reference = current.as(DeclReferenceExprSyntax.self) {
                return reference.baseName.text
            } else {
                return nil
            }
        }
    }

    private func isSelf(_ expr: ExprSyntax) -> Bool {
        var expr = expr
        if let optional = expr.as(OptionalChainingExprSyntax.self) { expr = optional.expression }
        if let forced = expr.as(ForceUnwrapExprSyntax.self) { expr = forced.expression }
        return expr.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
    }
}
