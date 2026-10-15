struct Classification: Equatable {
    var stability: Stability
    var reason: String
}

/// Decides how SwiftUI will compare a value of a given type when diffing a view.
final class Classifier {
    private let index: TypeIndex
    private var cache: [String: Classification] = [:]
    private var inProgress: Set<String> = []

    init(index: TypeIndex) {
        self.index = index
    }

    /// Equatable value types from the standard library, Foundation, CoreGraphics and SwiftUI.
    static let stableTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Double", "Float", "Float16", "CGFloat", "Bool", "String", "Character", "Substring", "Void", "Never",
        "Date", "URL", "UUID", "Data", "Decimal", "TimeInterval", "Duration", "Locale", "TimeZone", "Calendar",
        "DateComponents", "IndexPath", "IndexSet", "CharacterSet", "AttributedString", "PersonNameComponents",
        "ObjectIdentifier", "AnyHashable", "NSRange",
        "CGPoint", "CGSize", "CGRect", "CGVector", "CGAffineTransform",
        "Color", "Font", "Image", "Text", "LocalizedStringKey", "LocalizedStringResource", "Angle", "EdgeInsets",
        "UnitPoint", "Alignment", "HorizontalAlignment", "VerticalAlignment", "Edge", "Edge.Set", "Axis",
        "Axis.Set", "ContentMode", "ColorScheme", "DynamicTypeSize", "Visibility", "Gradient", "Material",
        "Font.Weight", "Font.Design", "Text.Alignment", "TextAlignment", "Prominence", "ControlSize",
    ]

    /// Classes from the SDK: compared by identity.
    static let referenceTypes: Set<String> = [
        "UIImage", "UIColor", "UIFont", "UIView", "UIViewController", "NSImage", "NSColor", "NSFont",
        "NSView", "NSViewController", "NSObject",
    ]

    func classify(_ type: TypeRef, generics: Set<String>, scope: [String]) -> Classification {
        switch type {
        case .function:
            // Measured (Validation/): SwiftUI compares a closure by its function and captured values. One that
            // captures nothing or only unchanged values compares equal; one that captures the caller's `self` doesn't.
            return .init(stability: .runtime, reason: "closure: equal unless the caller's closure captures changing state (e.g. its `self`)")
        case .optional(let wrapped), .array(let wrapped):
            return classify(wrapped, generics: generics, scope: scope)
        case .dictionary(let key, let value):
            return worst([key, value], generics: generics, scope: scope)
        case .tuple(let elements):
            return worst(elements, generics: generics, scope: scope)
        case .existential(let constraint):
            return .init(stability: .unknown, reason: "existential `any \(constraint)`: depends on the dynamic type")
        case .metatype:
            return .init(stability: .stable, reason: "metatype")
        case .unparsed(let text):
            return .init(stability: .unknown, reason: "unrecognized type `\(text)`")
        case .named(let rawName, let arguments):
            return classifyNamed(stripModule(rawName), arguments: arguments, generics: generics, scope: scope)
        }
    }

    private func classifyNamed(
        _ name: String, arguments: [TypeRef], generics: Set<String>, scope: [String]
    ) -> Classification {
        if generics.contains(name) {
            return .init(stability: .runtime, reason: "generic `\(name)`: depends on the caller's type")
        }
        if Self.stableTypes.contains(name) {
            return .init(stability: .stable, reason: "Equatable value")
        }
        if Self.referenceTypes.contains(name) {
            return .init(stability: .stable, reason: "class: compared by identity")
        }
        switch name {
        case "Optional", "Array", "Set", "ContiguousArray", "ArraySlice", "Range", "ClosedRange", "Dictionary":
            return worst(arguments, generics: generics, scope: scope)
        case "Binding":
            return .init(stability: .stable, reason: "Binding: SwiftUI compares bindings itself")
        case "AnyView":
            return .init(stability: .unstable, reason: "AnyView: never compares equal, even wrapping the same view")
        case "AnyShapeStyle", "AnyShape", "AnyTransition", "AnyLayout", "AnyGesture":
            return .init(stability: .unknown, reason: "type-erased `\(name)`")
        default:
            break
        }
        guard let qualified = index.resolve(name, scope: scope), let decl = index.types[qualified] else {
            return .init(stability: .unknown, reason: "`\(name)` is declared outside the analyzed sources")
        }
        if let cached = cache[qualified] { return cached }
        // A recursive type (`indirect enum Tree`) is as stable as its other members; assume stable meanwhile.
        if inProgress.contains(qualified) { return .init(stability: .stable, reason: "recursive") }
        inProgress.insert(qualified)
        let result = classify(decl)
        inProgress.remove(qualified)
        cache[qualified] = result
        return result
    }

    private func classify(_ decl: TypeDecl) -> Classification {
        let scope = decl.name.split(separator: ".").map(String.init)
        switch decl.kind {
        case .class, .actor:
            if decl.isObservable {
                return .init(stability: .stable, reason: "@Observable class: compared by identity, reads are tracked")
            }
            if decl.conformances.contains("ObservableObject") {
                return .init(stability: .stable, reason: "ObservableObject: compared by identity, changes unseen without @ObservedObject")
            }
            return .init(stability: .stable, reason: "class: compared by identity, mutations are invisible to SwiftUI")
        case .protocol:
            return .init(stability: .unknown, reason: "protocol `\(decl.name)`: depends on the dynamic type")
        case .alias:
            guard let aliased = decl.aliased else { return .init(stability: .unknown, reason: "typealias") }
            return classify(aliased, generics: decl.genericParameters, scope: Array(scope.dropLast()))
        case .struct, .enum:
            if decl.isEquatable {
                return .init(stability: .stable, reason: "Equatable")
            }
            let members = decl.kind == .struct ? decl.storedProperties.map { ($0.name, $0.type) } : decl.enumPayloads.map { ("payload", Optional($0)) }
            if members.isEmpty {
                return .init(stability: .stable, reason: decl.kind == .enum ? "enum without associated values" : "no stored properties")
            }
            var result = Classification(stability: .stable, reason: "all stored properties are stable")
            for (member, type) in members {
                let inner = type.map { classify($0, generics: decl.genericParameters, scope: scope) }
                    ?? .init(stability: .unknown, reason: "type not written out")
                if inner.stability > result.stability {
                    result = .init(stability: inner.stability, reason: "`\(decl.name).\(member)`: \(inner.reason)")
                }
            }
            return result
        }
    }

    private func worst(_ types: [TypeRef], generics: Set<String>, scope: [String]) -> Classification {
        types.map { classify($0, generics: generics, scope: scope) }
            .max { $0.stability < $1.stability } ?? .init(stability: .stable, reason: "Equatable value")
    }
}
