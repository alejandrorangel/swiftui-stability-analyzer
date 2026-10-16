import Testing
@testable import StabilityCore

private func analyze(_ sources: String...) -> [String: ViewReport] {
    let files = sources.enumerated().map { SourceFile(path: "File\($0.offset).swift", text: $0.element) }
    return Dictionary(uniqueKeysWithValues: Analyzer.analyze(files).map { ($0.name, $0) })
}

private func property(_ report: ViewReport?, _ name: String) -> PropertyReport? {
    report?.properties.first { $0.name == name }
}

@Test func valueInputsAreSkippable() {
    let report = analyze("""
    struct V: View {
        let title: String
        let count: Int?
        let tags: [String: Date]
        var body: some View { Text(title) }
    }
    """)["V"]
    #expect(report?.skippable == .yes)
    #expect(report?.properties.map(\.stability) == [.stable, .stable, .stable])
}

/// Measured: a closure compares by what it captures, so it depends on the caller.
@Test func closuresDependOnTheCaller() {
    let report = analyze("""
    struct V: View {
        let action: (() -> Void)?
        var body: some View { EmptyView() }
    }
    """)["V"]
    #expect(report?.skippable == .depends)
    #expect(property(report, "action")?.stability == .runtime)
    #expect(report?.findings.map(\.rule) == ["closure-property"])
    #expect(report?.findings.first?.severity == .info)
}

/// Measured: AnyView re-runs on every parent update, even wrapping the same view.
@Test func anyViewIsUnstable() {
    let report = analyze("struct V: View { let content: AnyView; var body: some View { content } }")["V"]
    #expect(report?.skippable == .no)
    #expect(report?.findings.map(\.rule) == ["any-view"])
    #expect(report?.findings.first?.severity == .warning)
}

@Test func typesResolveAcrossFiles() {
    let views = analyze(
        "struct V: View { let model: Model; var body: some View { EmptyView() } }",
        "struct Model { var name: String; var handler: Handler }",
        "struct Handler { var body: AnyView }"
    )
    #expect(property(views["V"], "model")?.stability == .unstable)
    #expect(property(views["V"], "model")?.reason.contains("Handler.body") == true)
}

@Test func equatableInExtensionMakesAStructStable() {
    let views = analyze(
        "struct V: View { let model: Model; var body: some View { EmptyView() } }",
        "struct Model { var run: () -> Void }\nextension Model: Equatable { static func == (a: Model, b: Model) -> Bool { true } }"
    )
    #expect(views["V"]?.skippable == .yes)
}

@Test func viewConformanceInExtensionCounts() {
    let views = analyze("struct V { let x: Int }\nextension V: View { var body: some View { EmptyView() } }")
    #expect(views["V"]?.skippable == .yes)
}

@Test func nestedTypesResolveInScope() {
    let views = analyze("""
    struct Outer {
        struct Inner: View { let style: Style; var body: some View { EmptyView() } }
        enum Style { case a, b }
    }
    """)
    #expect(views["Outer.Inner"]?.skippable == .yes)
}

@Test func genericsAndUnknownsDepend() {
    let views = analyze("""
    struct V<Item>: View {
        let item: Item
        let external: SomeSDKType
        var body: some View { EmptyView() }
    }
    """)
    #expect(property(views["V"], "item")?.stability == .runtime)
    #expect(property(views["V"], "external")?.stability == .unknown)
    #expect(views["V"]?.skippable == .depends)
}

@Test func ownedWrappersAreNotCompared() {
    let views = analyze("""
    @Observable class Model {}
    struct V: View {
        @State private var on = false
        @Environment(Model.self) private var model
        @Environment(\\.dismiss) private var dismiss
        var body: some View { EmptyView() }
    }
    """)
    #expect(views["V"]?.comparedProperties.isEmpty == true)
    #expect(views["V"]?.skippable == .yes)
    #expect(property(views["V"], "model")?.type == "Model")
}

@Test func computedPropertiesAreNotInputs() {
    let views = analyze("""
    struct V: View {
        let x: Int
        var doubled: Int { x * 2 }
        var y: Int = 0 { didSet {} }
        static let shared: () -> Void = {}
        var body: some View { EmptyView() }
    }
    """)
    #expect(views["V"]?.properties.map(\.name) == ["x", "y"])
}

@Test func storedViewBuilderSuggestsStoringContent() {
    let views = analyze("""
    struct Card<Content: View>: View {
        let content: () -> Content
        var body: some View { content() }
    }
    """)
    #expect(views["Card"]?.findings.map(\.rule) == ["stored-view-builder"])
}

/// Measured on iOS 27: SwiftUI uses an Equatable view's `==` even without `.equatable()`.
@Test func customEqualityMakesAViewSkippable() {
    let views = analyze("""
    struct V: View, Equatable {
        let n: Int
        let action: () -> Void
        static func == (a: V, b: V) -> Bool { a.n == b.n }
        var body: some View { EmptyView() }
    }
    """)
    #expect(views["V"]?.skippable == .yes)
    #expect(views["V"]?.findings.isEmpty == true)
}

@Test func objectWrapperFindings() {
    let views = analyze("""
    final class Store: ObservableObject {}
    final class Cache {}
    struct V: View {
        @ObservedObject var store = Store()
        @State private var cache = Cache()
        var body: some View { EmptyView() }
    }
    """)
    // `cache` is never read in body, so holding it in @State is fine.
    #expect(Set(views["V"]?.findings.map(\.rule) ?? []) == ["observable-object", "observed-object-initialized"])
}

@Test func bodyPatterns() {
    let views = analyze("""
    struct V: View {
        let items: [String]
        var body: some View {
            ForEach(items.sorted(), id: \\.self) { Text($0) }
            ForEach(items.indices, id: \\.self) { Text(items[$0]) }
            AnyView(Text("x"))
        }
    }
    """)
    #expect(views["V"]?.findings.map(\.rule) == [
        "foreach-id-self", "foreach-inline-transform", "foreach-id-self", "foreach-indices", "any-view",
    ])
}

@Test func recursiveTypesTerminate() {
    let views = analyze("""
    indirect enum Tree { case leaf(Int), node([Tree]) }
    struct V: View { let tree: Tree; var body: some View { EmptyView() } }
    """)
    #expect(views["V"]?.skippable == .yes)
}

@Test func attributesThatArentWrappersAreIgnored() {
    let views = analyze("""
    struct V: View {
        @MainActor let action: () -> Void
        @available(iOS 18, *) let title: String
        @State @MainActor private var on = false
        var body: some View { EmptyView() }
    }
    """)
    #expect(views["V"]?.properties.map(\.wrapper) == [nil, nil, "State"])
    #expect(property(views["V"], "action")?.stability == .runtime)
}
