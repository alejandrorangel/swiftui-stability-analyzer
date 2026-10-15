import Foundation
import Testing
@testable import StabilityCore

/// The shape `xctrace export` writes for the View Body table: values are written once with an `id`, then `ref`d.
private let export = """
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[5]'><schema name="swiftui-body-interval">\
<col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>view-type</mnemonic></col>\
<col><mnemonic>view-module</mnemonic></col><col><mnemonic>severity</mnemonic></col></schema>
<row><start-time id="1">1</start-time><duration id="2">6250</duration><string id="3">MainMenuItemHost.RootView</string><string id="4">SwiftUI</string><event-concept id="5">Low</event-concept></row>
<row><start-time id="6">2</start-time><duration id="7">2000000</duration><string id="8">Parent</string><string id="9">MyApp.debug.dylib</string><event-concept ref="5"/></row>
<row><start-time id="10">3</start-time><duration id="11">500000</duration><string id="12">Row</string><string ref="9"/><event-concept ref="5"/></row>
<row><start-time id="13">4</start-time><duration ref="11"/><string ref="12"/><string ref="9"/><event-concept ref="5"/></row>
<row><start-time id="14">5</start-time><duration ref="11"/><string id="15">Card&lt;Text&gt;</string><string ref="9"/><event-concept ref="5"/></row>
</node></trace-query-result>
"""

@Test func parsesBodyIntervalsResolvingRefs() throws {
    let trace = try BodyTrace(exportXML: Data(export.utf8), duration: 3)
    #expect(trace.views.map(\.name) == ["Parent", "Row", "Card"])
    #expect(trace.views.map(\.count) == [1, 2, 1])
    #expect(trace.views[1].totalMilliseconds == 1.0)
    #expect(trace.views.allSatisfy { $0.module == "MyApp" })
}

@Test func missingTableIsReported() {
    #expect(throws: TraceError.self) {
        _ = try BodyTrace(exportXML: Data("<trace-query-result/>".utf8))
    }
}

@Test func realityCheckVerdicts() throws {
    let reports = Analyzer.analyze([SourceFile(path: "V.swift", text: """
    struct Row: View {
        let onTap: () -> Void
        var body: some View { EmptyView() }
    }
    struct Card: View {
        let content: AnyView
        var body: some View { content }
    }
    struct Parent: View {
        @State private var n = 0
        var body: some View { Row(onTap: { n += 1 }) }
    }
    """)])
    let view = { (name: String, count: Int) in BodyTrace.View(name: name, module: "MyApp", count: count, totalMilliseconds: 1) }
    var trace = try BodyTrace(exportXML: Data(export.utf8))
    trace.views = [view("Row", 40), view("Card", 2), view("Parent", 40), view("Other", 50)]

    let rows = RealityCheck(trace: trace, reports: reports).rows
    #expect(rows.map(\.verdict) == [.confirmed, .notRerunning, .unexplained, .notAnalyzed])
    #expect(rows[0].prediction?.contains("Parent passes a closure capturing `self`") == true)
    #expect(rows[2].hint?.contains("@State n") == true)
}
