import Testing
@testable import StabilityCore

private let screen = """
struct Screen: View {
    @State private var model = Model()
    @State private var selected = 0
    let items: [Int]

    var body: some View {
        ForEach(items, id: \\.self) { item in
            Row(title: "a", onTap: { model.select(item) })
        }
    }

    private func open() {}
}
"""

// MARK: capture

@Test func captureAddsACaptureList() throws {
    let fixed = try Fixes.captureClosureDependencies(in: screen, line: 8)
    #expect(fixed.contains("Row(title: \"a\", onTap: { [model] in model.select(item) })"))
}

@Test func captureExtendsAnExistingSignature() throws {
    let source = screen.replacingOccurrences(of: "{ model.select(item) }", with: "{ x in model.select(x + selected) }")
    #expect(try Fixes.captureClosureDependencies(in: source, line: 8).contains("{ [model, selected] x in model.select(x + selected) }"))

    let withList = screen.replacingOccurrences(of: "{ model.select(item) }", with: "{ [item] in model.select(item) }")
    #expect(try Fixes.captureClosureDependencies(in: withList, line: 8).contains("{ [item, model] in model.select(item) }"))
}

@Test func captureRefusesWritesAndMethods() {
    let writes = screen.replacingOccurrences(of: "{ model.select(item) }", with: "{ selected += 1 }")
    #expect(throws: FixError.self) { try Fixes.captureClosureDependencies(in: writes, line: 8) }
    let toggles = screen.replacingOccurrences(of: "{ model.select(item) }", with: "{ $selected.wrappedValue = 1 }")
    #expect(throws: FixError.self) { try Fixes.captureClosureDependencies(in: toggles, line: 8) }
    let method = screen.replacingOccurrences(of: "{ model.select(item) }", with: "{ open() }")
    do {
        _ = try Fixes.captureClosureDependencies(in: method, line: 8)
        Issue.record("expected an error")
    } catch let error as FixError {
        #expect(error.description.contains("`open`"))
    } catch {}
}

@Test func captureWithNothingToCapture() {
    let local = screen.replacingOccurrences(of: "{ model.select(item) }", with: "{ print(item) }")
    #expect(throws: FixError.self) { try Fixes.captureClosureDependencies(in: local, line: 8) }
}

@Test func captureResultClearsTheFinding() throws {
    let fixed = try Fixes.captureClosureDependencies(in: screen, line: 8)
    let rowView = "struct Row: View { let title: String; let onTap: () -> Void; var body: some View { Text(title) } }"
    let findings = Analyzer.analyze([SourceFile(path: "a.swift", text: fixed), SourceFile(path: "b.swift", text: rowView)])
        .flatMap(\.findings).filter { $0.rule == "closure-captures-self" }
    #expect(findings.isEmpty)
}

// MARK: Equatable

@Test func makeEquatableComparesAllButClosuresAndOwnedState() throws {
    let source = """
    final class Store {}
    struct Row: View {
        let title: String
        let count: Int
        let store: Store
        let onTap: () -> Void
        @State private var expanded = false

        var body: some View { Text(title) }
    }
    """
    #expect(try Fixes.makeEquatable(in: source, line: 3) == """
    final class Store {}
    struct Row: View, Equatable {
        let title: String
        let count: Int
        let store: Store
        let onTap: () -> Void
        @State private var expanded = false

        var body: some View { Text(title) }

        // Leaves out `onTap`: a new closure shouldn't re-run body.
        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title
                && lhs.count == rhs.count
                && lhs.store === rhs.store
        }
    }
    """)
}

@Test func makeEquatableRefusesWhenAlreadyEquatable() {
    #expect(throws: FixError.self) {
        try Fixes.makeEquatable(in: "struct V: View, Equatable {\n    let a: Int\n    var body: some View { EmptyView() }\n}", line: 2)
    }
}

// MARK: _printChanges

@Test func togglePrintChangesAddsAndRemoves() throws {
    let added = try Fixes.togglePrintChanges(in: screen, line: 3)
    #expect(added.contains("    var body: some View {\n        let _ = Self._printChanges()\n        ForEach("))
    #expect(try Fixes.togglePrintChanges(in: added, line: 3) == screen)
}

@Test func togglePrintChangesOnASingleLineBody() throws {
    let source = "struct V: View {\n    var body: some View { Text(\"a\") }\n}"
    let added = try Fixes.togglePrintChanges(in: source, line: 2)
    #expect(added == "struct V: View {\n    var body: some View { let _ = Self._printChanges(); Text(\"a\") }\n}")
    #expect(try Fixes.togglePrintChanges(in: added, line: 2) == source)
}

@Test func togglePrintChangesInAModifier() throws {
    let source = "struct M: ViewModifier {\n    func body(content: Content) -> some View {\n        content\n    }\n}"
    #expect(try Fixes.togglePrintChanges(in: source, line: 3).contains("{\n        let _ = Self._printChanges()\n        content"))
}

// MARK: ignore

@Test func ignoreInsertsTheRuleAbove() throws {
    let source = "struct V: View {\n    let content: AnyView\n    var body: some View { content }\n}"
    let fixed = try Fixes.ignoreFinding(in: source, line: 2)
    #expect(fixed.contains("    // swiftui-stability:ignore any-view — \n    let content: AnyView"))
    #expect(throws: FixError.self) { try Fixes.ignoreFinding(in: source, line: 3) }
}

// MARK: annotations

private let annotatable = """
@MainActor
struct Row: View {
    let title: String
    let model: ExternalModel
    let content: AnyView
    @State private var on = false

    var body: some View { content }
}
"""

@Test func annotationsMarkViewsAndPropertiesAndRoundTrip() throws {
    let annotated = try Fixes.toggleStabilityAnnotations(in: annotatable)
    let lines = annotated.components(separatedBy: "\n")
    #expect(lines[0] == "@MainActor")
    #expect(lines[1] == "struct Row: View { // ❌ can't skip: content")
    #expect(lines[2] == "    let title: String // 🟢 stable — Equatable value")
    #expect(lines[3].hasPrefix("    let model: ExternalModel // 🟡 unknown — `ExternalModel` is declared outside"))
    #expect(lines[4].hasPrefix("    let content: AnyView // 🔴 unstable — AnyView"))
    #expect(lines[5] == "    @State private var on = false // ⚪ owned — @State")
    #expect(lines[7] == "    var body: some View { content }")
    #expect(try Fixes.toggleStabilityAnnotations(in: annotated) == annotatable)
}

@Test func moduleReportsOverrideSingleFileVerdicts() throws {
    // Analyzed with the module, ExternalModel is an Equatable struct.
    let module = Analyzer.analyze([
        SourceFile(path: "Row.swift", text: annotatable),
        SourceFile(path: "Model.swift", text: "struct ExternalModel: Equatable { var id: Int }"),
    ])
    let annotated = try Fixes.toggleStabilityAnnotations(in: annotatable, moduleReports: module)
    #expect(annotated.contains("let model: ExternalModel // 🟢 stable — Equatable"))
}

@Test func annotationsLeaveOtherCommentsAlone() throws {
    let source = "struct V: View {\n    let a: Int // 🟢 my own note\n    var body: some View { EmptyView() }\n}"
    let annotated = try Fixes.toggleStabilityAnnotations(in: source)
    #expect(annotated.contains("let a: Int // 🟢 my own note // 🟢 stable"))
    #expect(try Fixes.toggleStabilityAnnotations(in: annotated) == source)
}

@Test func shortReasons() {
    #expect(Fixes.short("owned by SwiftUI, not compared; writes re-run body") == "owned by SwiftUI, not compared")
    #expect(Fixes.short("closure: equal unless the caller's closure captures changing state (e.g. its `self`)")
        == "closure: equal unless the caller's closure captures…")
}
