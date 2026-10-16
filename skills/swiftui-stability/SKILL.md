---
name: swiftui-stability
description: Checks which SwiftUI views can skip `body` when their parent re-renders, and why not, with the `swiftui-stability` command — per-view skippability, per-property stability, finding rules (stored closures, @ObservedObject created inline, ForEach identity, AnyView…) and a committed baseline checked in CI. Use when writing or reviewing SwiftUI views, investigating extra body evaluations or SwiftUI performance, or when Xcode shows `[stability]` / `[closure-property]`-style warnings from the SwiftUIStabilityPlugin.
---
# SwiftUI stability analyzer

`swiftui-stability` statically analyzes SwiftUI views, view modifiers (`body(content:)`) and UIKit/AppKit representables. Before re-running a child's `body`, SwiftUI compares the child's stored properties with their previous values. When every input compares equal, the body is skipped. This tool tells you, per view, whether that can happen and which inputs prevent it.

## Installation

If `swiftui-stability` isn't on the PATH, install it from https://github.com/alejandrorangel/swiftui-stability-analyzer: clone it and run `scripts/install.sh` (installs to `~/.local/bin/swiftui-stability`; `--skill` also installs this skill). Requires Xcode 16 or later (Swift 6).

In Xcode, the same analysis runs as the **SwiftUIStabilityPlugin** build tool plugin; its warnings end in `[stability]` or a rule name like `[closure-property]`. See the repository README to add it to a project.

## Workflow

1. **Analyze the whole module, not one file.** Property types are resolved across the files you pass; a type from a file you didn't pass is reported as `unknown`.
   `swiftui-stability analyze <AppSourcesDir> --unstable-only` — what needs attention.
   `swiftui-stability analyze <AppSourcesDir> --json` — everything, structured, when you'll parse it.
2. **Before editing a view, note its verdict; after editing, run it again** and make sure nothing got worse (`skippable: yes` → `no`, `stable` → `unstable`).
3. **If the project has a baseline** (`stability/baseline.stability`), run `swiftui-stability check <AppSourcesDir>`. Exit status 1 means something changed: fix regressions; if a change is intended, run `swiftui-stability dump <AppSourcesDir>` and commit the updated baseline with the code.

## Measuring at runtime

To find which views actually re-run, and why, without editing the app:

`swiftui-stability trace --app <path.app> --device <sim or device> --sources <AppSourcesDir> --json`

(`ios describe --scheme S` gives the .app path; `--attach <AppName> --time-limit 30s` records a running app while you drive it, e.g. with `ios input`.) Each view gets its body run count and time, plus a verdict: `confirmed` (predicted and hot: fix it if it's expensive), `unexplained` (hot, no predicted cause: the `hint` lists its state, observed objects and inputs), `not-rerunning`, `quiet`. Prefer this over adding temporary counters.

## Reading the output

```
ProfileView  skippable: no  Sources/ProfileView.swift:22
  stable   user: User  — Equatable
  runtime  onTap: () -> Void  — closure: equal unless the caller's closure captures changing state (e.g. its `self`)
  owned    @State isExpanded: Bool  — owned by SwiftUI, not compared; writes re-run body
  info [closure-property] line 25: …

ProfileScreen  skippable: yes  Sources/ProfileScreen.swift:8
  warning [closure-captures-self] line 14: The closure passed to `ProfileView` as `onTap:` reads `taps`, so it captures `self` …
```

- `skippable`: `yes` (all compared inputs are stable, or the type is `Equatable`), `depends` (a generic, a closure, or an unknown type), `no` (an input never compares equal, e.g. `AnyView`).
- **Closures are decided at call sites.** SwiftUI compares a closure by what it captures (measured): capturing nothing, constants or a local copy is equal; reading the parent's state or calling its methods captures the parent's `self`, which changes on every parent update. `closure-captures-self` is reported on the parent's line.
- Property stability: `stable` compares reliably · `runtime` depends on a generic argument · `unknown` can't be decided from these sources · `unstable` compares as changed on every parent update · `owned` is storage SwiftUI owns (`@State`, `@Environment`…), not compared but it invalidates the view directly.
- The reason after `—` names the cause, including nested ones (`` `Row.onSelect`: closure ``).

## Fixing findings

| Rule | Fix |
|---|---|
| `closure-captures-self` | Capture only what the closure needs: `{ [model] in model.select(item) }` (a local copy or capture list compares equal), or pass a method of a model object (`model.select`) instead of the view's own method. Only worth it for expensive children or frequently updating parents. Alternatively make the child `Equatable` without the closure (SwiftUI uses `==` automatically; with main-actor default isolation write `nonisolated static func ==`). |
| `closure-property` (info) | Nothing to fix in the child by itself; see `closure-captures-self` at its call sites. |
| `stored-view-builder` | Store the built view: `let content: Content` with `init(@ViewBuilder content: () -> Content) { self.content = content() }`. |
| `observed-object-initialized` | `@ObservedObject var x = X()` → `@StateObject`, or `@State` with an `@Observable` class. This is a correctness bug: the object is recreated by the parent. |
| `state-plain-class` | `body` reads a plain class held in `@State`: make it `@Observable`, or keep the value in `@State` itself. Not reported when the class is only used in event handlers or passed on, a deliberate pattern (e.g. a scroll-offset box written on every scroll tick without re-rendering). |
| `state-observable-object` | `body` reads an ObservableObject held in `@State`, which doesn't subscribe: use `@StateObject` (created here, non-optional), or read it in a child with `@ObservedObject`. |
| `foreach-inline-transform` | Compute the filtered/sorted collection once (in the model, or cached state), not in `body`. |
| `foreach-indices`, `foreach-id-self` | Iterate `Identifiable` elements or pass a stable `id:` key path. |
| `frequent-updates` | The observed class has a display link, timer or sleep loop that writes observed state each tick, so `body` re-runs on every tick. Move the fast-changing value into a small child view that observes it (or an `@Observable` property read only there), so the rest of the body stays put. Confirm with `let _ = Self._printChanges()` in `body`. |
| `observable-object` (info) | Consider migrating the ObservableObject to `@Observable` for per-property invalidation. |
| `any-view` | A stored `AnyView` re-runs the view on every parent update (measured): use a generic `Content: View` or `@ViewBuilder`. |

**Intended findings:** add `// swiftui-stability:ignore <rule> — <why>` in the comment block directly above the flagged declaration (any line of the block; the reason may wrap) or at the end of its line, instead of contorting the code. No blank line between the comment and the code. `// swiftui-stability:ignore stability` on a type's declaration silences its "can't skip" warning. Don't suppress without a reason in the comment.

Stability is a means, not a goal: prioritize views in lists, views under frequently changing state, and expensive bodies. Skippability is a static prediction; confirm suspected hot spots at runtime with `let _ = Self._logChanges()` in `body` (unified log, subsystem `com.apple.SwiftUI`) or the SwiftUI template in Instruments.

## Limits

- Types from other modules (SPM packages, frameworks) are `unknown` unless they're common SDK value types.
- SwiftUI's diffing is undocumented; the rules are measured on iOS 27 (simulator) in the repository's Validation/RESULTS.md. Older iOS versions aren't measured yet.
- A local variable anywhere in the view's methods that shares a property's name hides that property from `closure-captures-self`.
