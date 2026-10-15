---
name: swiftui-stability
description: Checks which SwiftUI views can skip `body` when their parent re-renders, and why not, with the `swiftui-stability` command — per-view skippability, per-property stability, finding rules (stored closures, @ObservedObject created inline, ForEach identity, AnyView…) and a committed baseline checked in CI. Use when writing or reviewing SwiftUI views, investigating extra body evaluations or SwiftUI performance, or when Xcode shows `[stability]` / `[closure-property]`-style warnings from the SwiftUIStabilityPlugin.
---
# SwiftUI stability analyzer

`swiftui-stability` statically analyzes SwiftUI views. Before re-running a child's `body`, SwiftUI compares the child's stored properties with their previous values. When every input compares equal, the body is skipped. This tool tells you, per view, whether that can happen and which inputs prevent it.

## Installation

If `swiftui-stability` isn't on the PATH, install it from https://github.com/alejandrorangel/swiftui-stability-analyzer: clone it and run `scripts/install.sh` (installs to `~/.local/bin/swiftui-stability`; `--skill` also installs this skill). Requires Xcode 16 or later (Swift 6).

In Xcode, the same analysis runs as the **SwiftUIStabilityPlugin** build tool plugin; its warnings end in `[stability]` or a rule name like `[closure-property]`. See the repository README to add it to a project.

## Workflow

1. **Analyze the whole module, not one file.** Property types are resolved across the files you pass; a type from a file you didn't pass is reported as `unknown`.
   `swiftui-stability analyze <AppSourcesDir> --unstable-only` — what needs attention.
   `swiftui-stability analyze <AppSourcesDir> --json` — everything, structured, when you'll parse it.
2. **Before editing a view, note its verdict; after editing, run it again** and make sure nothing got worse (`skippable: yes` → `no`, `stable` → `unstable`).
3. **If the project has a baseline** (`stability/baseline.stability`), run `swiftui-stability check <AppSourcesDir>`. Exit status 1 means something changed: fix regressions; if a change is intended, run `swiftui-stability dump <AppSourcesDir>` and commit the updated baseline with the code.

## Reading the output

```
ProfileView  skippable: no  Sources/ProfileView.swift:22
  stable   user: User  — Equatable
  unstable onTap: () -> Void  — closure: closures never compare equal
  owned    @State isExpanded: Bool  — owned by SwiftUI, not compared; writes re-run body
  warning [closure-property] line 25: …
```

- `skippable`: `yes` (all compared inputs are stable), `depends` (a generic, unknown type, or custom `==`), `no` (an input never compares equal).
- Property stability: `stable` compares reliably · `runtime` depends on a generic argument · `unknown` can't be decided from these sources · `unstable` compares as changed on every parent update · `owned` is storage SwiftUI owns (`@State`, `@Environment`…), not compared but it invalidates the view directly.
- The reason after `—` names the cause, including nested ones (`` `Row.onSelect`: closure ``).

## Fixing findings

| Rule | Fix |
|---|---|
| `closure-property` | Only if the view re-renders often or is expensive: make it `Equatable` comparing everything except the closure, and apply `.equatable()` where it's used. Or pass the action through the environment. Don't contort cheap views. |
| `stored-view-builder` | Store the built view: `let content: Content` with `init(@ViewBuilder content: () -> Content) { self.content = content() }`. |
| `observed-object-initialized` | `@ObservedObject var x = X()` → `@StateObject`, or `@State` with an `@Observable` class. This is a correctness bug: the object is recreated by the parent. |
| `state-plain-class` | Mark the class `@Observable`, or hold value state instead. |
| `foreach-inline-transform` | Compute the filtered/sorted collection once (in the model, or cached state), not in `body`. |
| `foreach-indices`, `foreach-id-self` | Iterate `Identifiable` elements or pass a stable `id:` key path. |
| `observable-object` (info) | Consider migrating the ObservableObject to `@Observable` for per-property invalidation. |
| `any-view` (info) | Use `@ViewBuilder`, `some View`, or a generic `Content: View`. |

Stability is a means, not a goal: prioritize views in lists, views under frequently changing state, and expensive bodies. Skippability is a static prediction; confirm suspected hot spots at runtime with `let _ = Self._logChanges()` in `body` (unified log, subsystem `com.apple.SwiftUI`) or the SwiftUI template in Instruments.

## Limits

- Types from other modules (SPM packages, frameworks) are `unknown` unless they're common SDK value types.
- SwiftUI's diffing is undocumented; the rules follow observed behavior (see the repository's PLAN.md).
