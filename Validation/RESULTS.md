# Validation results

How SwiftUI actually decides whether to re-run a child's `body`, measured with [StabilityLab](StabilityLab), and how the analyzer's predictions compare. Re-run with `Validation/run.sh` (needs [ios-cli](https://github.com/alejandrorangel/ios-cli)); it exits 1 when a prediction disagrees.

**Method.** A parent view re-renders 20 times (it reads a `@State` counter), rebuilding each child with an *equal* input every time. Each child counts its own `body` runs. About 1 run means SwiftUI compared the inputs and skipped; about 21 means it re-ran on every parent update. Three controls receive a changing input and must reach 21.

**Environment.** iPhone 17 simulator, iOS 27.0 (24A434), Xcode 27.0, Debug build, 2026-10-15. Six runs gave the same verdicts; one launch added a few unrelated runs (up to 8) to some views, which is why only "once per parent update" counts as re-running. The table below is from iOS 27.0.

| Environment | Agree |
|---|---|
| iPhone 17 simulator, iOS 27.0 (24A434), Debug | 40/40 (6 runs) |
| iPhone 17 simulator, iOS 26.5 (23F77), Debug | 40/40 |
| Physical device | not yet measured |
| Release build | not yet measured |
| iOS 17 / 18 | not yet measured (no runtime installed) |

## What SwiftUI does

- **Closures are compared by what they capture**, not treated as always different. A closure that captures nothing, constants, runtime values that are equal (`Int`, a heap-allocated `String`), or a local copy of the same object compares equal and the child skips. So do method references on a class instance (`model.ping`) and `nil`.
- **A closure that captures the parent view's `self` re-runs the child on every parent update**: reading the parent's state or properties inside it (`{ flag.toggle() }`, `{ model.ping() }` where `model` is the parent's property) or passing one of the parent's methods (`action: open`). The captured `self` includes the parent's changed state. Fix: capture only what's needed (`{ [model] in model.ping() }`).
- **`AnyView` never compares equal**, even wrapping the same `Text`: the child re-runs every time.
- **An `Equatable` view's `==` is used even without `.equatable()`** (iOS 27): views whose `==` ignores a changing closure skipped.
- Value types compare by value whether or not they're `Equatable` or POD (heap strings, arrays, non-Equatable structs with `String` fields, enums with payloads, an `any` existential holding a struct). `Binding`s to unchanged state, `.constant(_)`, the same object instance, `@ObservedObject`, and generic `Content` all skip.
- A `ViewModifier` behaves like a view. (One whose `body(content:)` returns `content` unchanged was never evaluated at all.)

## Predictions vs measurements

Predicted re-run: the child's verdict is `skippable: no`, or a call site passes it a closure that captures `self` (`closure-captures-self`). Everything else is predicted to skip.

Version 27.0 (Build 24A434), 20 parent updates

| Case | Body runs | Measured | Predicted | Basis | |
|---|---|---|---|---|---|
| `AnyViewInput` | 21 | re-runs | re-runs | skippable: no (content) | ✅ |
| `ArrayInput` | 2 | skips | skips | skippable: yes | ✅ |
| `BindingInput` | 1 | skips | skips | skippable: yes | ✅ |
| `CapturingClosureModifier` | 21 | re-runs | re-runs | closure-captures-self at the call site | ✅ |
| `ChangingInput` | 21 | re-runs | re-runs | control: input changes | ✅ |
| `ChangingModifier` | 21 | re-runs | re-runs | control: input changes | ✅ |
| `ClosureCapturingHeapStringInput` | 3 | skips | skips | skippable: depends | ✅ |
| `ClosureCapturingIntInput` | 2 | skips | skips | skippable: depends | ✅ |
| `ClosureCapturingObjectInput` | 21 | re-runs | re-runs | closure-captures-self at the call site | ✅ |
| `ClosureCapturingParentInput` | 21 | re-runs | re-runs | closure-captures-self at the call site | ✅ |
| `ClosureCapturingSameObjectInput` | 1 | skips | skips | skippable: depends | ✅ |
| `ClosureCapturingValueInput` | 2 | skips | skips | skippable: depends | ✅ |
| `ClosureModifier` | 1 | skips | skips | skippable: depends | ✅ |
| `ClosureNoCaptureInput` | 1 | skips | skips | skippable: depends | ✅ |
| `ConstantBindingInput` | 2 | skips | skips | skippable: yes | ✅ |
| `DateInput` | 1 | skips | skips | skippable: yes | ✅ |
| `EnumPayloadInput` | 2 | skips | skips | skippable: yes | ✅ |
| `EquatableModifierCapturingClosure` | 2 | skips | skips | skippable: yes | ✅ |
| `EquatableModifierWithClosure` | 1 | skips | skips | skippable: yes | ✅ |
| `EquatableStructInput` | 1 | skips | skips | skippable: yes | ✅ |
| `EquatableViewCapturingClosure` | 2 | skips | skips | skippable: yes | ✅ |
| `EquatableViewWithClosure` | 1 | skips | skips | skippable: yes | ✅ |
| `ExistentialInput` | 2 | skips | skips | skippable: depends | ✅ |
| `GenericContentInput` | 2 | skips | skips | skippable: depends | ✅ |
| `HeapStringInput` | 2 | skips | skips | skippable: yes | ✅ |
| `IntInput` | 1 | skips | skips | skippable: yes | ✅ |
| `MethodReferenceInput` | 1 | skips | skips | skippable: depends | ✅ |
| `NewObjectInput` | 21 | re-runs | re-runs | control: input changes | ✅ |
| `ObservableModelInput` | 1 | skips | skips | skippable: yes | ✅ |
| `ObservedObjectInput` | 1 | skips | skips | skippable: yes | ✅ |
| `OptionalClosureNilInput` | 1 | skips | skips | skippable: depends | ✅ |
| `ParentMethodReferenceInput` | 21 | re-runs | re-runs | closure-captures-self at the call site | ✅ |
| `PlainPODStructInput` | 1 | skips | skips | skippable: yes | ✅ |
| `PlainStringStructInput` | 2 | skips | skips | skippable: yes | ✅ |
| `SameObjectInput` | 1 | skips | skips | skippable: yes | ✅ |
| `ShortStringInput` | 1 | skips | skips | skippable: yes | ✅ |
| `StructWithClosureInput` | 1 | skips | skips | skippable: depends | ✅ |
| `ValueModifier` | 1 | skips | skips | skippable: yes | ✅ |
| `ViewBuilderClosureCapturingInput` | 3 | skips | skips | skippable: depends | ✅ |
| `ViewBuilderClosureInput` | 1 | skips | skips | skippable: depends | ✅ |

40/40 agree

The analyzer's model before these measurements (0.3.2: "closures never compare equal", `AnyView` unknown, `Equatable` views needing `.equatable()`) agreed on 28 of 40.
