import SwiftUI

/// Re-renders `updates` times (its body reads `tick`), rebuilding every child with equal inputs, then prints the
/// body counts. Nothing on screen is interactive; `Validation/run.sh` reads the printed result.
struct ContentView: View {
    static let updates = 20

    @State private var tick = 0
    @State private var flag = true
    @State private var model = Model()
    @StateObject private var store = Store()
    @State private var observable = ObservableModel()

    var body: some View {
        let name = "captured"
        let number = Int("7")!  // computed at runtime, equal every time
        let heapString = longString(4)
        let sameModel = model
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("tick \(tick)").font(.headline)

                IntInput(value: 1)
                ShortStringInput(value: "short")
                HeapStringInput(value: longString(1))
                DateInput(value: Date(timeIntervalSince1970: 0))
                ArrayInput(values: [1, 2, 3])
                EquatableStructInput(value: Point(x: 1, y: 2))
                PlainPODStructInput(value: PlainSize(width: 1, height: 2))
                PlainStringStructInput(value: PlainLabel(text: longString(2)))
                EnumPayloadInput(value: .loaded(PlainLabel(text: longString(3))))
                ExistentialInput(value: NumberBadge(count: 1))

                ClosureNoCaptureInput(action: {})
                ClosureCapturingValueInput(action: { print(name) })
                ClosureCapturingObjectInput(action: { model.ping() })
                ClosureCapturingIntInput(action: { print(number) })
                ClosureCapturingHeapStringInput(action: { print(heapString) })
                ClosureCapturingSameObjectInput(action: { sameModel.ping() })
                ClosureCapturingParentInput(action: { print(flag) })
                ViewBuilderClosureCapturingInput(content: { Text(heapString) })
                MethodReferenceInput(action: model.ping)
                ParentMethodReferenceInput(action: noop)
                OptionalClosureNilInput(action: nil)
                StructWithClosureInput(row: PlainRow(title: "row", onTap: {}))

                SameObjectInput(model: model)
                NewObjectInput(model: Model())
                ObservedObjectInput(store: store)
                ObservableModelInput(model: observable)

                BindingInput(isOn: $flag)
                ConstantBindingInput(isOn: .constant(true))

                GenericContentInput(content: Text("content"))
                ViewBuilderClosureInput(content: { Text("content") })
                AnyViewInput(content: AnyView(Text("content")))

                EquatableViewWithClosure(count: 1, action: {})
                EquatableModifierWithClosure(count: 1, action: {}).equatable()
                EquatableViewCapturingClosure(count: 1, action: { print(flag) })
                EquatableModifierCapturingClosure(count: 1, action: { print(flag) }).equatable()

                Text("modified").modifier(ClosureModifier(action: {}))
                Text("modified").modifier(CapturingClosureModifier(action: { print(flag) }))
                Text("modified").modifier(ValueModifier(value: 1))
                Text("modified").modifier(ChangingModifier(value: tick))

                NoInputs()
                ChangingInput(value: tick)
            }
            .font(.caption2)
        }
        .task { await run() }
    }

    private func noop() {}

    private func run() async {
        for _ in 0..<Self.updates {
            try? await Task.sleep(for: .milliseconds(50))
            tick += 1
        }
        try? await Task.sleep(for: .milliseconds(500))
        Probe.report(parentUpdates: Self.updates)
    }
}
