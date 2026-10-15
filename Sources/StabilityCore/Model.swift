/// How SwiftUI's view diffing treats a stored property, ordered from "never forces `body`" to "always does".
///
/// Mirrors the Compose analyzer's STABLE / RUNTIME / UNKNOWN / UNSTABLE. SwiftUI's rules are undocumented;
/// these follow the commonly observed behavior: Equatable values use `==`, other value types are compared
/// field by field, classes by identity, and closures practically never compare equal.
public enum Stability: String, Codable, Comparable, Sendable {
    /// Compares reliably: equal inputs let SwiftUI skip `body`.
    case stable
    /// Depends on a generic argument chosen by the caller.
    case runtime
    /// Can't be decided from the analyzed sources (another module, an existential, a custom wrapper).
    case unknown
    /// Compares as changed on (nearly) every parent update.
    case unstable

    var rank: Int {
        switch self {
        case .stable: 0
        case .runtime: 1
        case .unknown: 2
        case .unstable: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Whether SwiftUI can skip this view's `body` when its parent re-renders with equal inputs.
public enum Skippability: String, Codable, Comparable, Sendable {
    case yes
    /// Some inputs are runtime/unknown, or the view relies on its own `==`.
    case depends
    case no

    var rank: Int {
        switch self {
        case .yes: 0
        case .depends: 1
        case .no: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct PropertyReport: Codable, Equatable, Sendable {
    public var name: String
    public var type: String
    /// The property wrapper, without `@` (`State`, `ObservedObject`…).
    public var wrapper: String?
    public var stability: Stability
    public var reason: String
    /// False for storage SwiftUI owns (`@State`, `@Environment`…): it isn't compared, it invalidates directly.
    public var compared: Bool
    public var line: Int
}

public enum Severity: String, Codable, Sendable {
    case warning, info
}

public struct Finding: Codable, Equatable, Sendable {
    public var rule: String
    public var severity: Severity
    public var message: String
    public var line: Int
}

public struct ViewReport: Codable, Sendable {
    /// Qualified name, e.g. `Profile.Header` for a nested view.
    public var name: String
    public var file: String
    public var line: Int
    public var skippable: Skippability
    /// The view declares its own `==` (Equatable), which SwiftUI uses with `.equatable()`.
    public var customEquality: Bool
    public var properties: [PropertyReport]
    public var findings: [Finding]

    public var comparedProperties: [PropertyReport] { properties.filter(\.compared) }
}

/// A parsed type annotation, reduced to what the classifier needs.
indirect enum TypeRef: Hashable, Sendable {
    /// `Foo`, `Foo.Bar`, `Array<Int>` — the dotted name and its generic arguments.
    case named(String, [TypeRef])
    case optional(TypeRef)
    case array(TypeRef)
    case dictionary(TypeRef, TypeRef)
    case function
    case tuple([TypeRef])
    /// `any P`, `P & Q`.
    case existential(String)
    case metatype
    case unparsed(String)

    /// The type without `Optional`; `(() -> Void)?` is a function.
    var unwrapped: TypeRef {
        switch self {
        case .optional(let wrapped): wrapped.unwrapped
        case .named(let name, let args) where (name == "Optional" || name == "Swift.Optional") && args.count == 1:
            args[0].unwrapped
        default: self
        }
    }

    var isFunction: Bool {
        if case .function = unwrapped { return true }
        return false
    }
}
