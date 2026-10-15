import Testing
@testable import StabilityCore

private func baseline(_ source: String) -> Baseline {
    Baseline(reports: Analyzer.analyze([SourceFile(path: "V.swift", text: source)]))
}

@Test func baselineRoundTrips() throws {
    let original = baseline("""
    struct V<T>: View {
        let title: String
        let map: [String: Int]
        let item: T
        let onTap: () -> Void
        var body: some View { EmptyView() }
    }
    """)
    let parsed = try Baseline(parsing: original.render())
    #expect(parsed == original)
}

@Test func becomingUnstableIsARegression() {
    let before = baseline("struct V: View { let a: Int; var body: some View { EmptyView() } }")
    let after = baseline("struct V: View { let a: () -> Int; var body: some View { EmptyView() } }")
    let changes = before.changes(to: after)
    #expect(changes.map(\.line) == ["~ V: skippable yes → skippable no", "~ V.a: Int stable → () -> Int unstable"])
    #expect(changes.allSatisfy { $0.regression })
}

@Test func improvementsAndRemovalsAreNotRegressions() {
    let before = baseline("""
    struct V: View { let a: () -> Int; var body: some View { EmptyView() } }
    struct Old: View { var body: some View { EmptyView() } }
    """)
    let after = baseline("struct V: View { let a: Int; var body: some View { EmptyView() } }")
    let changes = before.changes(to: after)
    #expect(!changes.isEmpty)
    #expect(changes.allSatisfy { !$0.regression })
}

@Test func newUnskippableViewIsARegression() {
    let before = baseline("")
    let after = baseline("struct V: View { let a: () -> Void; var body: some View { EmptyView() } }")
    #expect(before.changes(to: after).map(\.regression) == [true])
}

@Test func malformedBaselineThrows() {
    #expect(throws: BaselineError.self) { _ = try Baseline(parsing: "V\n  nonsense") }
}
