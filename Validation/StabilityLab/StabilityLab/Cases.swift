import Combine
import SwiftUI

// One child view per kind of stored property. The parent re-renders N times and passes each child an *equal*
// input every time; a child whose body count stays at 1 was skipped, one that reaches ~N+1 re-ran.
// Names are the case IDs: Validation/compare.py joins them with `swiftui-stability analyze --json`.

// MARK: - Supporting types

struct Point: Equatable {
    var x: Int
    var y: Int
}

/// Not Equatable; only trivially copyable fields (POD).
struct PlainSize {
    var width: Double
    var height: Double
}

/// Not Equatable; a String field makes it non-POD.
struct PlainLabel {
    var text: String
}

struct PlainRow {
    var title: String
    var onTap: () -> Void
}

enum LoadState {
    case idle
    case loaded(PlainLabel)
}

protocol Badge {
    var count: Int { get }
}

struct NumberBadge: Badge {
    var count: Int
}

final class Model {
    func ping() {}
}

final class Store: ObservableObject {
    @Published var value = 0
}

@Observable final class ObservableModel {
    var value = 0
}

/// Long enough to be heap-allocated: equal strings built separately don't share storage.
func longString(_ n: Int) -> String { "a string long enough to be stored on the heap #\(n)" }

// MARK: - Values

struct IntInput: View {
    let value: Int
    var body: some View { let _ = Probe.hit(Self.self); Text("\(value)") }
}

struct ShortStringInput: View {
    let value: String
    var body: some View { let _ = Probe.hit(Self.self); Text(value) }
}

struct HeapStringInput: View {
    let value: String
    var body: some View { let _ = Probe.hit(Self.self); Text(value) }
}

struct DateInput: View {
    let value: Date
    var body: some View { let _ = Probe.hit(Self.self); Text(value, style: .date) }
}

struct ArrayInput: View {
    let values: [Int]
    var body: some View { let _ = Probe.hit(Self.self); Text("\(values.count)") }
}

struct EquatableStructInput: View {
    let value: Point
    var body: some View { let _ = Probe.hit(Self.self); Text("\(value.x)") }
}

struct PlainPODStructInput: View {
    let value: PlainSize
    var body: some View { let _ = Probe.hit(Self.self); Text("\(value.width)") }
}

struct PlainStringStructInput: View {
    let value: PlainLabel
    var body: some View { let _ = Probe.hit(Self.self); Text(value.text) }
}

struct EnumPayloadInput: View {
    let value: LoadState
    var body: some View { let _ = Probe.hit(Self.self); Text("state") }
}

struct ExistentialInput: View {
    let value: any Badge
    var body: some View { let _ = Probe.hit(Self.self); Text("\(value.count)") }
}

// MARK: - Closures

struct ClosureNoCaptureInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

struct ClosureCapturingValueInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

struct ClosureCapturingObjectInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

struct MethodReferenceInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

/// A method of the parent view passed as a function: partial application captures the parent's `self`.
struct ParentMethodReferenceInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

struct OptionalClosureNilInput: View {
    let action: (() -> Void)?
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

struct StructWithClosureInput: View {
    let row: PlainRow
    var body: some View { let _ = Probe.hit(Self.self); Text(row.title) }
}

struct ClosureCapturingIntInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

struct ClosureCapturingHeapStringInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

/// Captures a local copy of an object reference (the same instance every time), not `self`.
struct ClosureCapturingSameObjectInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

/// Captures the parent view (`self`), the most common shape for actions written in a parent's body.
struct ClosureCapturingParentInput: View {
    let action: () -> Void
    var body: some View { let _ = Probe.hit(Self.self); Text("closure") }
}

struct ViewBuilderClosureCapturingInput<Content: View>: View {
    let content: () -> Content
    var body: some View { let _ = Probe.hit(ViewBuilderClosureCapturingInput<Text>.self); content() }
}

// MARK: - References

struct SameObjectInput: View {
    let model: Model
    var body: some View { let _ = Probe.hit(Self.self); Text("object") }
}

/// Control: a new instance every time is a changed input.
struct NewObjectInput: View {
    let model: Model
    var body: some View { let _ = Probe.hit(Self.self); Text("object") }
}

struct ObservedObjectInput: View {
    @ObservedObject var store: Store
    var body: some View { let _ = Probe.hit(Self.self); Text("\(store.value)") }
}

struct ObservableModelInput: View {
    let model: ObservableModel
    var body: some View { let _ = Probe.hit(Self.self); Text("\(model.value)") }
}

// MARK: - Bindings

struct BindingInput: View {
    @Binding var isOn: Bool
    var body: some View { let _ = Probe.hit(Self.self); Text(isOn ? "on" : "off") }
}

struct ConstantBindingInput: View {
    @Binding var isOn: Bool
    var body: some View { let _ = Probe.hit(Self.self); Text(isOn ? "on" : "off") }
}

// MARK: - View content

struct GenericContentInput<Content: View>: View {
    let content: Content
    var body: some View { let _ = Probe.hit(GenericContentInput<Text>.self); content }
}

struct ViewBuilderClosureInput<Content: View>: View {
    let content: () -> Content
    var body: some View { let _ = Probe.hit(ViewBuilderClosureInput<Text>.self); content() }
}

struct AnyViewInput: View {
    let content: AnyView
    var body: some View { let _ = Probe.hit(Self.self); content }
}

// MARK: - Custom equality

/// Equatable, comparing only `count`; used without `.equatable()`.
struct EquatableViewWithClosure: View, Equatable {
    let count: Int
    let action: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.count == rhs.count }
    var body: some View { let _ = Probe.hit(Self.self); Text("\(count)") }
}

/// The same, used with `.equatable()`.
struct EquatableModifierWithClosure: View, Equatable {
    let count: Int
    let action: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.count == rhs.count }
    var body: some View { let _ = Probe.hit(Self.self); Text("\(count)") }
}

/// Equatable ignoring a closure that captures the parent (so the closure differs every time); no `.equatable()`.
struct EquatableViewCapturingClosure: View, Equatable {
    let count: Int
    let action: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.count == rhs.count }
    var body: some View { let _ = Probe.hit(Self.self); Text("\(count)") }
}

/// The same, with `.equatable()`.
struct EquatableModifierCapturingClosure: View, Equatable {
    let count: Int
    let action: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.count == rhs.count }
    var body: some View { let _ = Probe.hit(Self.self); Text("\(count)") }
}

// MARK: - Modifiers

struct ClosureModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View { let _ = Probe.hit(Self.self); content.padding(1) }
}

struct CapturingClosureModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View { let _ = Probe.hit(Self.self); content.padding(1) }
}

struct ValueModifier: ViewModifier {
    let value: Int
    func body(content: Content) -> some View { let _ = Probe.hit(Self.self); content.padding(1) }
}

/// Control: receives the changing tick.
struct ChangingModifier: ViewModifier {
    let value: Int
    func body(content: Content) -> some View { let _ = Probe.hit(Self.self); content.padding(1) }
}

// MARK: - Controls

struct NoInputs: View {
    @State private var local = 0
    var body: some View { let _ = Probe.hit(Self.self); Text("\(local)") }
}

/// Control: receives the parent's changing tick, so it must re-run every time.
struct ChangingInput: View {
    let value: Int
    var body: some View { let _ = Probe.hit(Self.self); Text("\(value)") }
}
