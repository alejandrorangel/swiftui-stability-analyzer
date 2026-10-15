import Testing
@testable import StabilityCore

private func analyze(_ sources: String...) -> [ViewReport] {
    Analyzer.analyze(sources.enumerated().map { SourceFile(path: "File\($0.offset).swift", text: $0.element) })
}

@Test func viewModifiersAreAnalyzed() throws {
    let report = try #require(analyze("""
    struct TapToSeek: ViewModifier {
        let onTap: (Double) -> Void
        func body(content: Content) -> some View { content.onTapGesture { onTap(0) } }
    }
    """).first)
    #expect(report.kind == .modifier)
    #expect(report.skippable == .no)
    #expect(report.findings.map(\.rule) == ["closure-property"])
    #expect(report.findings.first?.message.contains("`TapToSeek.body(content:)`") == true)
}

@Test func representablesAreAnalyzed() throws {
    let report = try #require(analyze("""
    struct MapBox: UIViewRepresentable {
        let zoom: Double
        func makeUIView(context: Context) -> UIView { UIView() }
        func updateUIView(_ view: UIView, context: Context) {}
    }
    """).first)
    #expect(report.kind == .representable)
    #expect(report.skippable == .yes)
}

@Test func sameNameInBothIfBranchesReportsBoth() {
    let reports = analyze("""
    #if canImport(UIKit)
    struct Probe: UIViewRepresentable {
        let onScroll: (Double) -> Void
        func makeUIView(context: Context) -> UIView { UIView() }
        func updateUIView(_ view: UIView, context: Context) {}
    }
    #else
    struct Probe: View {
        let onScroll: (Double) -> Void
        var body: some View { EmptyView() }
    }
    #endif
    """)
    #expect(reports.map(\.kind) == [.representable, .view])
    #expect(Set(Baseline(reports: reports).views.keys) == ["Probe", "Probe #2"])
}

@Test func membersInsideIfBlocksAreInputs() {
    let reports = analyze("""
    struct Badge: View {
        let count: Int
        #if os(iOS)
        let onClear: () -> Void
        #else
        let onClear: (Int) -> Void
        #endif
        var body: some View { EmptyView() }
    }
    """)
    #expect(reports.first?.properties.map(\.name) == ["count", "onClear", "onClear"])
    #expect(reports.first?.skippable == .no)
}

@Test func ignoreCommentSuppressesARule() throws {
    let report = try #require(analyze("""
    final class Holder { weak var view: AnyObject? }
    struct Screen: View {
        // swiftui-stability:ignore state-plain-class — a reference holder; mutations must not re-render
        @State private var holder = Holder()
        @State private var other = Holder()
        var body: some View { EmptyView() }
    }
    """).first)
    #expect(report.suppressed.map(\.line) == [4])
    #expect(report.findings.map(\.line) == [5])
}

@Test func trailingIgnoreAndIgnoreAll() throws {
    let report = try #require(analyze("""
    struct Screen: View { // swiftui-stability:ignore stability
        let onTap: () -> Void // swiftui-stability:ignore
        var body: some View { EmptyView() }
    }
    """).first)
    #expect(report.findings.isEmpty)
    #expect(report.suppressed.map(\.rule) == ["closure-property"])
    #expect(report.stabilityWarningIgnored)
    #expect(!XcodeDiagnostics.render([report]).contains("can't skip"))
}

@Test func ignoringOneRuleKeepsOthers() throws {
    let report = try #require(analyze("""
    struct Screen: View {
        // swiftui-stability:ignore any-view
        let onTap: () -> Void
        var body: some View { EmptyView() }
    }
    """).first)
    #expect(report.findings.map(\.rule) == ["closure-property"])
}

@Test func observableObjectDrivenByADisplayLinkIsAWarning() throws {
    let reports = analyze(
        """
        final class Clock: ObservableObject {
            @Published var position = 0.0
            private var link: CADisplayLink?
            func start() { link = CADisplayLink(target: self, selector: #selector(tick)) }
            @objc private func tick() { position += 1 }
        }
        final class Settings: ObservableObject { @Published var tempo = 120 }
        """,
        """
        struct Player: View {
            @StateObject private var clock = Clock()
            @StateObject private var settings = Settings()
            var body: some View { EmptyView() }
        }
        """
    )
    let findings = try #require(reports.first?.findings)
    #expect(findings.map(\.rule) == ["frequent-updates", "observable-object"])
    #expect(findings[0].severity == .warning)
    #expect(findings[0].message.contains("`CADisplayLink` at line 4"))
}

@Test func observableModelWithASleepLoopIsInfo() throws {
    let reports = analyze("""
    @Observable final class Ticker {
        var now = 0.0
        func run() async { while true { now += 1; try? await Task.sleep(for: .milliseconds(16)) } }
    }
    struct Screen: View {
        @State private var ticker = Ticker()
        var body: some View { EmptyView() }
    }
    """)
    let finding = try #require(reports.first?.findings.first)
    #expect(finding.rule == "frequent-updates")
    #expect(finding.severity == .info)
}

@Test func commentedOutTimersDontCount() {
    let reports = analyze("""
    final class Store: ObservableObject {
        // Timer.publish(every: 1, on: .main, in: .common) was too chatty
        @Published var items: [String] = []
    }
    struct Screen: View {
        @ObservedObject var store: Store
        var body: some View { EmptyView() }
    }
    """)
    #expect(reports.first?.findings.map(\.rule) == ["observable-object"])
}

// frequent-updates fires only when a tick writes observed state.

private func frequentUpdates(_ model: String) -> [Finding] {
    let reports = analyze(model, """
    struct Screen: View {
        @StateObject private var model = Model()
        var body: some View { EmptyView() }
    }
    """)
    return reports.first?.findings.filter { $0.rule == "frequent-updates" } ?? []
}

@Test func loopThatPublishesThroughAMethodIsFlagged() {
    #expect(frequentUpdates("""
    final class Model: ObservableObject {
        @Published var x = 0.0
        func run() {
            Task {
                while !Task.isCancelled {
                    update(at: 1)
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }
        private func update(at time: Double) { apply(time) }
        private func apply(_ time: Double) { self.x = time }
    }
    """).count == 1)
}

@Test func watcherThatPublishesOnceIsNotFlagged() {
    #expect(frequentUpdates("""
    final class Model: ObservableObject {
        @Published var finished = false
        var position = 0.0
        func watch(end: Double) {
            Task {
                while true {
                    try? await Task.sleep(for: .milliseconds(100))
                    if position >= end {
                        finished = true
                        break
                    }
                    lastPolled = position
                }
            }
        }
        private var lastPolled = 0.0
    }
    """).isEmpty)
}

@Test func oneOffDelayIsNotATick() {
    #expect(frequentUpdates("""
    final class Model: ObservableObject {
        @Published var toast: String?
        func show(_ text: String) async {
            toast = text
            try? await Task.sleep(for: .seconds(2))
            toast = nil
        }
    }
    """).isEmpty)
}

@Test func timerSinkThatPublishesIsFlagged() {
    #expect(frequentUpdates("""
    final class Model: ObservableObject {
        @Published var elapsed = 0
        private var bag: Set<AnyCancellable> = []
        func start() {
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.elapsed += 1 }
                .store(in: &bag)
        }
    }
    """).first?.message.contains("`Timer.publish` at line 5") == true)
}

@Test func objectWillChangeSendCounts() {
    #expect(frequentUpdates("""
    final class Model: ObservableObject {
        @Published var unused = 0
        func run() async {
            while true {
                objectWillChange.send()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    """).count == 1)
}

@Test func observationIgnoredIsNotTracked() {
    let reports = analyze("""
    @Observable final class Model {
        var title = ""
        @ObservationIgnored var lastTick = 0.0
        func run() async {
            while true {
                lastTick += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
    struct Screen: View {
        @State private var model = Model()
        var body: some View { EmptyView() }
    }
    """)
    #expect(reports.first?.findings.isEmpty == true)
}

// Suppression placement.

private func closureFindingSuppressed(_ declaration: String) -> Bool {
    let report = analyze("struct Screen: View {\n\(declaration)\n    var body: some View { EmptyView() }\n}").first
    return report?.findings.isEmpty == true && report?.suppressed.map(\.rule) == ["closure-property"]
}

@Test func directiveAtTheTopOfAWrappedCommentApplies() {
    #expect(closureFindingSuppressed("""
        // swiftui-stability:ignore closure-property — the parent passes a stable method reference, and the
        // view is cheap: measured ~0.1 ms.
        let onTap: () -> Void
    """))
}

@Test func directiveInTheMiddleOfACommentBlockApplies() {
    #expect(closureFindingSuppressed("""
        /// The action to run.
        // swiftui-stability:ignore closure-property — intended
        /// Called on the main actor.
        let onTap: () -> Void
    """))
}

@Test func directiveAppliesThroughAttributeLines() {
    #expect(closureFindingSuppressed("""
        // swiftui-stability:ignore closure-property
        @MainActor
        let onTap: () -> Void
    """))
}

@Test func blankLineDetachesTheDirective() {
    #expect(!closureFindingSuppressed("""
        // swiftui-stability:ignore closure-property

        let onTap: () -> Void
    """))
}

@Test func trailingDirectiveAppliesOnlyToItsLine() {
    let report = analyze("""
    struct Screen: View {
        let a: () -> Void // swiftui-stability:ignore closure-property
        let b: () -> Void
        var body: some View { EmptyView() }
    }
    """).first
    #expect(report?.suppressed.map(\.line) == [2])
    #expect(report?.findings.map(\.line) == [3])
}
