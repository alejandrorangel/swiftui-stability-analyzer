# swiftui-stability-analyzer

Tells you which SwiftUI views can skip `body` when their parent re-renders, which inputs prevent it, and catches regressions in CI. It's the SwiftUI counterpart of [compose-stability-analyzer](https://github.com/skydoves/compose-stability-analyzer). See [PLAN.md](PLAN.md) for the model, its open questions and the roadmap (build tool plugin, Xcode Source Editor Extension, Instruments-based runtime checks).

## Build

```sh
swift build -c release   # .build/release/swiftui-stability
swift test
```

## Use

```sh
swiftui-stability analyze Sources/MyApp                 # report (pass a whole module so types resolve across files)
swiftui-stability analyze Sources/MyApp --unstable-only  # only what needs attention
swiftui-stability analyze Sources/MyApp --json           # for agents and scripts
swiftui-stability analyze Sources/MyApp --format xcode   # file:line: warning: … for Xcode build phases

swiftui-stability dump Sources/MyApp                    # writes stability/baseline.stability — commit it
swiftui-stability check Sources/MyApp                   # exit 1 on changes; --ignore-non-regressive to fail only on regressions
```

Example (`Examples/Sample`):

```
ProfileView  skippable: no  Examples/Sample/Views.swift:22
  stable   user: User  — Equatable
  stable   theme: Theme  — all stored properties are stable
  unstable onTap: () -> Void  — closure: closures never compare equal
  owned    @State isExpanded: Bool  — owned by SwiftUI, not compared; writes re-run body
  owned    @Environment model: ProfileModel  — not compared; re-runs body only when properties it reads change
  warning [closure-property] line 25: `onTap` is a closure, which never compares equal, …
```

`check` after a model type changes in another file:

```
~ ProfileView.user: User stable → User unstable   ← regression
```

## In Xcode: build tool plugin

The `SwiftUIStabilityPlugin` runs the analyzer on a target's Swift files during every build. Its results appear as warnings inline in the editor and in the Issue navigator, and they stay there across rebuilds.

**Xcode app project:** File → Add Package Dependencies… → Add Local… (or the repository URL), add the package without linking any library to your app, then in the app target: Build Phases → Run Build Tool Plug-ins → **+** → `SwiftUIStabilityPlugin`. The first build asks you to **Trust & Enable** the plugin.

**Swift package target:**

```swift
dependencies: [.package(url: "https://github.com/alejandrorangel/swiftui-stability-analyzer", branch: "main")],
targets: [
    .target(name: "MyFeature", plugins: [.plugin(name: "SwiftUIStabilityPlugin", package: "swiftui-stability-analyzer")]),
]
```

`Examples/PluginDemo` is a working setup (`swift build` there shows the warnings). On CI, pass `-skipPackagePluginValidation` to `xcodebuild`. Each build also writes the full JSON report (`<Target>.stability.json`) to the plugin's output directory, e.g. `DerivedData/…/BuildToolPluginIntermediates/…/SwiftUIStabilityPlugin/`.

Only `warning` findings and views that can't skip are reported in Xcode; `info` findings are left to `analyze`. The plugin builds the analyzer and swift-syntax from source on the first build (about 12 s for the demo package on an Apple silicon Mac).

## Rules

| Rule | Severity | What |
|---|---|---|
| `closure-property` | warning | A stored closure keeps the view from skipping |
| `stored-view-builder` | warning | `let content: () -> Content`; store `Content` instead |
| `observed-object-initialized` | warning | `@ObservedObject var x = X()` is recreated by the parent |
| `state-plain-class` | warning | `@State` holding a non-`@Observable` class |
| `foreach-inline-transform` | warning | `ForEach(items.filter …)` recomputed every body |
| `foreach-indices` | warning | `ForEach(items.indices)` ties identity to position |
| `foreach-id-self` | info | `id: \.self` identifies rows by value |
| `observable-object` | info | ObservableObject invalidates on any `@Published` change |
| `any-view` | info | `AnyView` erases structural identity |

## CI (GitHub Actions)

```yaml
- run: swift build -c release --package-path tools/swiftui-stability-analyzer
- run: tools/swiftui-stability-analyzer/.build/release/swiftui-stability check Sources/MyApp
```
