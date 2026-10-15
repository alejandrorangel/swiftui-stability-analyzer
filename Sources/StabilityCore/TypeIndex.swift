import Foundation
import SwiftParser
import SwiftSyntax

/// A stored property as written in a type declaration.
struct StoredProperty {
    var name: String
    /// The declared type, or one inferred from a literal / initializer call / `@Environment(T.self)`.
    var type: TypeRef?
    var typeText: String
    var wrapper: String?
    var hasInitializer: Bool
    var line: Int
}

/// Every type declared in the analyzed sources, so a view's property types can be followed across files.
struct TypeDecl {
    enum Kind { case `struct`, `enum`, `class`, actor, `protocol`, alias }

    var name: String
    var kind: Kind
    /// Inherited types from the declaration and its extensions, module prefixes removed.
    var conformances: Set<String>
    var attributes: Set<String>
    var genericParameters: Set<String>
    var storedProperties: [StoredProperty] = []
    var enumPayloads: [TypeRef] = []
    var aliased: TypeRef?
    var file: String
    var line: Int
    /// Kept for views, whose bodies are scanned for findings.
    var members: MemberBlockSyntax?
    var converter: SourceLocationConverter?
    /// For classes: a line that looks like a high-frequency update source (display link, timer, sleep loop).
    var updateSource: (text: String, line: Int)?

    /// What SwiftUI compares before re-running this type's body, if anything.
    var viewKind: ViewKind? {
        if !conformances.isDisjoint(with: ViewKind.representableProtocols) { return .representable }
        if conformances.contains("ViewModifier") { return .modifier }
        if conformances.contains("View") { return .view }
        return nil
    }
    var isEquatable: Bool { !conformances.isDisjoint(with: ["Equatable", "Hashable", "Comparable"]) }
    var isObservable: Bool { attributes.contains("Observable") || attributes.contains("Model") }
}

public struct SourceFile: Sendable {
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

final class TypeIndex {
    private(set) var types: [String: TypeDecl] = [:]
    /// Views, modifiers and representables, including same-named ones from different `#if` branches.
    private(set) var views: [TypeDecl] = []
    /// Simple name → qualified names, for references written without their enclosing type.
    private var bySimpleName: [String: [String]] = [:]

    init(files: [SourceFile]) {
        var extensions: [(scope: [String], extended: String, conformances: Set<String>)] = []
        var all: [TypeDecl] = []
        for file in files {
            let tree = Parser.parse(source: file.text)
            let converter = SourceLocationConverter(fileName: file.path, tree: tree)
            let collector = DeclarationCollector(file: file.path, converter: converter)
            collector.walk(tree)
            for decl in collector.decls {
                all.append(decl)
                // `#if os(iOS) struct Probe: UIViewRepresentable #else struct Probe: View` declares a name twice;
                // name resolution uses the first, but every declaration is analyzed.
                guard types[decl.name] == nil else { continue }
                types[decl.name] = decl
                bySimpleName[String(decl.name.split(separator: ".").last!), default: []].append(decl.name)
            }
            extensions += collector.extensions
        }
        // Extensions are merged after every file is read: `extension Foo: Equatable` may come before `Foo`.
        for ext in extensions {
            guard let target = resolve(ext.extended, scope: ext.scope) else { continue }
            types[target]?.conformances.formUnion(ext.conformances)
            for i in all.indices where all[i].name == target {
                all[i].conformances.formUnion(ext.conformances)
            }
        }
        views = all.filter { $0.kind == .struct && $0.viewKind != nil }
            .sorted { ($0.name, $0.file, $0.line) < ($1.name, $1.file, $1.line) }
    }

    /// Resolves a name as Swift would, innermost scope first: inside `Outer`, `Inner` is `Outer.Inner`.
    func resolve(_ name: String, scope: [String]) -> String? {
        let name = stripModule(name)
        var prefix = scope
        while true {
            let candidate = (prefix + [name]).joined(separator: ".")
            if types[candidate] != nil { return candidate }
            if prefix.isEmpty { break }
            prefix.removeLast()
        }
        return bySimpleName[String(name.split(separator: ".").last!)]?.first
    }

}

public enum ViewKind: String, Codable, Sendable {
    case view, modifier, representable

    static let representableProtocols: Set<String> = [
        "UIViewRepresentable", "UIViewControllerRepresentable", "NSViewRepresentable", "NSViewControllerRepresentable",
    ]

    /// What re-runs when an input compares as changed.
    var entryPoint: String {
        switch self {
        case .view: "body"
        case .modifier: "body(content:)"
        case .representable: "update…(_:context:)"
        }
    }
}

private let knownModules: Set<String> = ["Swift", "SwiftUI", "SwiftUICore", "Foundation", "Observation", "Combine", "SwiftData", "UIKit", "AppKit", "CoreGraphics"]

func stripModule(_ name: String) -> String {
    let parts = name.split(separator: ".", maxSplits: 1)
    if parts.count == 2, knownModules.contains(String(parts[0])) { return String(parts[1]) }
    return name
}

private final class DeclarationCollector: SyntaxVisitor {
    let file: String
    let converter: SourceLocationConverter
    var decls: [TypeDecl] = []
    var extensions: [(scope: [String], extended: String, conformances: Set<String>)] = []
    private var scope: [String] = []

    init(file: String, converter: SourceLocationConverter) {
        self.file = file
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    private func line(_ node: some SyntaxProtocol) -> Int {
        node.startLocation(converter: converter).line
    }

    private func add(
        _ kind: TypeDecl.Kind, name: TokenSyntax, inheritance: InheritanceClauseSyntax?,
        attributes: AttributeListSyntax, generics: GenericParameterClauseSyntax?, members: MemberBlockSyntax?,
        node: some SyntaxProtocol
    ) {
        var decl = TypeDecl(
            name: (scope + [name.text]).joined(separator: "."),
            kind: kind,
            conformances: conformances(inheritance),
            attributes: Set(attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }),
            genericParameters: Set(generics?.parameters.map(\.name.text) ?? []),
            file: file,
            line: line(node)
        )
        if let members {
            let items = flatten(members.members)
            decl.storedProperties = items.compactMap { $0.decl.as(VariableDeclSyntax.self) }
                .flatMap { storedProperties(of: $0) }
            if kind == .enum {
                decl.enumPayloads = items.compactMap { $0.decl.as(EnumCaseDeclSyntax.self) }
                    .flatMap(\.elements)
                    .flatMap { $0.parameterClause?.parameters.map { TypeRef($0.type) } ?? [] }
            }
            if kind == .struct {
                decl.members = members
                decl.converter = converter
            }
            if kind == .class || kind == .actor {
                decl.updateSource = updateSource(in: members)
            }
        }
        decls.append(decl)
    }

    /// Members, including those inside `#if` blocks (every branch: the analyzer doesn't know the build settings).
    private func flatten(_ items: MemberBlockItemListSyntax) -> [MemberBlockItemSyntax] {
        items.flatMap { item -> [MemberBlockItemSyntax] in
            guard let ifConfig = item.decl.as(IfConfigDeclSyntax.self) else { return [item] }
            return ifConfig.clauses.flatMap { clause -> [MemberBlockItemSyntax] in
                if case .decls(let nested) = clause.elements { return flatten(nested) }
                return []
            }
        }
    }

    private let updateSourcePattern = try! Regex(
        #"CADisplayLink|DispatchSourceTimer|Timer\.(publish|scheduledTimer)|Task\.sleep|\.sleep\(for:|\.sleep\(until:|displayLink"#
    )

    /// The first line of a class that looks like it drives frequent updates.
    private func updateSource(in members: MemberBlockSyntax) -> (text: String, line: Int)? {
        let firstLine = line(members)
        for (offset, text) in members.trimmedDescription.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = text.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            if let match = code.firstMatch(of: updateSourcePattern) {
                return (String(code[match.range]), firstLine + offset)
            }
        }
        return nil
    }

    private func conformances(_ clause: InheritanceClauseSyntax?) -> Set<String> {
        Set(clause?.inheritedTypes.map { stripModule($0.type.trimmedDescription) } ?? [])
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        add(.struct, name: node.name, inheritance: node.inheritanceClause, attributes: node.attributes,
            generics: node.genericParameterClause, members: node.memberBlock, node: node)
        scope.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { scope.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        add(.class, name: node.name, inheritance: node.inheritanceClause, attributes: node.attributes,
            generics: node.genericParameterClause, members: node.memberBlock, node: node)
        scope.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { scope.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        add(.actor, name: node.name, inheritance: node.inheritanceClause, attributes: node.attributes,
            generics: node.genericParameterClause, members: node.memberBlock, node: node)
        scope.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { scope.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        add(.enum, name: node.name, inheritance: node.inheritanceClause, attributes: node.attributes,
            generics: node.genericParameterClause, members: node.memberBlock, node: node)
        scope.append(node.name.text)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { scope.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        add(.protocol, name: node.name, inheritance: node.inheritanceClause, attributes: node.attributes,
            generics: nil, members: nil, node: node)
        return .skipChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        add(.alias, name: node.name, inheritance: nil, attributes: node.attributes,
            generics: node.genericParameterClause, members: nil, node: node)
        decls[decls.count - 1].aliased = TypeRef(node.initializer.value)
        return .skipChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = node.extendedType.trimmedDescription
        extensions.append((scope, extended, conformances(node.inheritanceClause)))
        scope.append(stripModule(extended))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { scope.removeLast() }

    // Locals inside functions and closures aren't members; skip them.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

    private func storedProperties(of variable: VariableDeclSyntax) -> [StoredProperty] {
        let modifiers = Set(variable.modifiers.map(\.name.text))
        guard modifiers.isDisjoint(with: ["static", "class"]) else { return [] }
        let wrapperAttribute = variable.attributes.compactMap { $0.as(AttributeSyntax.self) }.first
        let wrapper = wrapperAttribute.map { stripModule($0.attributeName.trimmedDescription) }

        return variable.bindings.compactMap { binding -> StoredProperty? in
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return nil }
            if let accessors = binding.accessorBlock?.accessors {
                switch accessors {
                case .getter: return nil
                case .accessors(let list):
                    let observers: Set<String> = ["willSet", "didSet"]
                    if !list.allSatisfy({ observers.contains($0.accessorSpecifier.text) }) { return nil }
                }
            }
            var type = binding.typeAnnotation.map { TypeRef($0.type) }
            var typeText = binding.typeAnnotation?.type.trimmedDescription
            if type == nil, let value = binding.initializer?.value, let inferred = inferType(value) {
                (type, typeText) = inferred
            }
            if type == nil, let inferred = wrapperAttribute.flatMap(metatypeArgument) {
                (type, typeText) = inferred
            }
            return StoredProperty(
                name: name, type: type, typeText: typeText ?? "?", wrapper: wrapper,
                hasInitializer: binding.initializer != nil, line: line(binding)
            )
        }
    }

    /// `let x = 0`, `= "a"`, `= Foo(...)`, `= { ... }`.
    private func inferType(_ expr: ExprSyntax) -> (TypeRef, String)? {
        if expr.is(IntegerLiteralExprSyntax.self) { return (.named("Int", []), "Int") }
        if expr.is(FloatLiteralExprSyntax.self) { return (.named("Double", []), "Double") }
        if expr.is(StringLiteralExprSyntax.self) { return (.named("String", []), "String") }
        if expr.is(BooleanLiteralExprSyntax.self) { return (.named("Bool", []), "Bool") }
        if expr.is(ClosureExprSyntax.self) { return (.function, "closure") }
        if let call = expr.as(FunctionCallExprSyntax.self),
           let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text.first?.isUppercase == true {
            return (.named(callee.baseName.text, []), callee.baseName.text)
        }
        return nil
    }

    /// `@Environment(Model.self) var model` declares its type only in the attribute.
    private func metatypeArgument(_ attribute: AttributeSyntax) -> (TypeRef, String)? {
        guard case .argumentList(let args) = attribute.arguments,
              let member = args.first?.expression.as(MemberAccessExprSyntax.self),
              member.declName.baseName.text == "self",
              let base = member.base?.trimmedDescription else { return nil }
        return (.named(base, []), base)
    }
}

extension TypeRef {
    init(_ syntax: TypeSyntax) {
        if let identifier = syntax.as(IdentifierTypeSyntax.self) {
            self = .named(identifier.name.text, Self.arguments(identifier.genericArgumentClause))
        } else if let member = syntax.as(MemberTypeSyntax.self) {
            let base = TypeRef(member.baseType)
            let baseName = if case .named(let name, _) = base { name } else { member.baseType.trimmedDescription }
            self = .named("\(baseName).\(member.name.text)", Self.arguments(member.genericArgumentClause))
        } else if let optional = syntax.as(OptionalTypeSyntax.self) {
            self = .optional(TypeRef(optional.wrappedType))
        } else if let iuo = syntax.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            self = .optional(TypeRef(iuo.wrappedType))
        } else if let array = syntax.as(ArrayTypeSyntax.self) {
            self = .array(TypeRef(array.element))
        } else if let dictionary = syntax.as(DictionaryTypeSyntax.self) {
            self = .dictionary(TypeRef(dictionary.key), TypeRef(dictionary.value))
        } else if syntax.is(FunctionTypeSyntax.self) {
            self = .function
        } else if let attributed = syntax.as(AttributedTypeSyntax.self) {
            self = TypeRef(attributed.baseType)
        } else if let tuple = syntax.as(TupleTypeSyntax.self) {
            let elements = tuple.elements.map { TypeRef($0.type) }
            // `(() -> Void)` is just parentheses.
            self = elements.count == 1 && tuple.elements.first?.firstName == nil ? elements[0] : .tuple(elements)
        } else if let someOrAny = syntax.as(SomeOrAnyTypeSyntax.self) {
            self = .existential(someOrAny.constraint.trimmedDescription)
        } else if syntax.is(CompositionTypeSyntax.self) {
            self = .existential(syntax.trimmedDescription)
        } else if syntax.is(MetatypeTypeSyntax.self) {
            self = .metatype
        } else {
            self = .unparsed(syntax.trimmedDescription)
        }
    }

    private static func arguments(_ clause: GenericArgumentClauseSyntax?) -> [TypeRef] {
        clause?.arguments.compactMap { argument in
            if case .type(let type) = argument.argument { return TypeRef(type) }
            return nil
        } ?? []
    }
}
