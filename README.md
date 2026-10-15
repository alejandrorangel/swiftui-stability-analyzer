# swiftui-stability-analyzer

Tells you which SwiftUI views can skip `body` when their parent re-renders, which inputs prevent it, and catches regressions in CI. It's the SwiftUI counterpart of [compose-stability-analyzer](https://github.com/skydoves/compose-stability-analyzer). See [PLAN.md](PLAN.md) for the model, its open questions and the roadmap (build tool plugin, Xcode Source Editor Extension, Instruments-based runtime checks).

Requires Xcode 16 or later (Swift 6); tested with Xcode 27 on macOS 27.

## Add it to your project

There are two ways to use the tool:
- **Xcode build tool plugin:** warnings show up in Xcode as you build. No install needed; Xcode fetches the package.
- **Command-line tool:** for terminal and AI agent use, and for a CI check against a committed baseline.

### 1. Xcode app project (build tool plugin)

1. In Xcode: **File → Add Package Dependencies…**, paste `https://github.com/alejandrorangel/swiftui-stability-analyzer`, choose **Up to Next Major Version** from `0.3.2`, and click **Add Package**.
2. In **Choose Package Products**, set **Add to Target** to **None** for `swiftui-stability` and `StabilityCore`. Nothing gets linked into your app. Set `SwiftUIStabilityPlugin` to your app target, or to **None** and add it in step 3.
3. Select your app target → **Build Phases** → **Run Build Tool Plug-ins** → **+** → `SwiftUIStabilityPlugin`. If you picked the target in step 2, it's already there. Repeat for each target (app, frameworks) that contains SwiftUI views.
4. Build (⌘B). Xcode asks you once to **Trust & Enable** the plugin. Warnings appear inline and in the Issue navigator, ending in `[stability]` or a rule name such as `[closure-property]`.

The first build compiles the analyzer and swift-syntax for your Mac: about 12 s for a Debug build and about 2 minutes for a Release build or Archive (measured on an Apple silicon Mac); later builds reuse it. After that the analyzer runs on every build: parsing only, nothing is compiled into your app. `xcodebuild` on CI needs `-skipPackagePluginValidation`, the command-line version of Trust & Enable.

To remove it, delete the plugin from **Run Build Tool Plug-ins** and the package from the project's **Package Dependencies**.

### 2. Swift package target

```swift
dependencies: [
    .package(url: "https://github.com/alejandrorangel/swiftui-stability-analyzer", from: "0.3.2"),
],
targets: [
    .target(
        name: "MyFeature",
        plugins: [.plugin(name: "SwiftUIStabilityPlugin", package: "swiftui-stability-analyzer")]
    ),
]
```

`swift build` or Xcode then report the warnings. [`Examples/PluginDemo`](Examples/PluginDemo) is a working example.

### 3. Command-line tool (and agent skill)

```sh
git clone https://github.com/alejandrorangel/swiftui-stability-analyzer
cd swiftui-stability-analyzer
scripts/install.sh --skill     # ~/.local/bin/swiftui-stability; --skill also installs the Claude Code skill
swiftui-stability --version
```

Re-run `git pull && scripts/install.sh --skill` to update. The skill (`~/.claude/skills/swiftui-stability`) tells AI agents when to run the analyzer, how to read its output, and how to fix each rule. Leave out `--skill` to install only the command.

## Use the command-line tool

```sh
swiftui-stability analyze MyApp/                  # report (pass a whole module so types resolve across files)
swiftui-stability analyze MyApp/ --unstable-only  # only what needs attention
swiftui-stability analyze MyApp/ --json           # for agents and scripts
swiftui-stability analyze MyApp/ --format xcode   # file:line: warning: … lines, as the plugin prints

swiftui-stability dump MyApp/                     # writes stability/baseline.stability — commit it
swiftui-stability check MyApp/                    # exit 1 on changes; --ignore-non-regressive to fail only on regressions
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

- **skippable:** `yes` means every compared input is stable. `depends` means a generic input, a type from another module, or a custom `==`. `no` means an input never compares equal.
- **Property levels:** `stable`, `runtime` (generic), `unknown` and `unstable` describe properties SwiftUI compares. `owned` is SwiftUI's own storage (`@State`, `@Environment`…): it isn't compared, but changes to it invalidate the view directly.

`check` after a model type changes in another file:

```
~ ProfileView.user: User stable → User unstable   ← regression
```

What's analyzed: structs conforming to `View`, `ViewModifier` (`body(content:)`), and `UIViewRepresentable` / `UIViewControllerRepresentable` / their AppKit equivalents (SwiftUI compares their stored properties before calling `update…`). All `#if` branches are read, since the analyzer doesn't know your build settings; two declarations with the same name in different branches are both reported (the second as `Name #2` in the baseline).

In Xcode, only `warning` findings and views that can't skip are reported; `info` findings appear only in `analyze` output. Each plugin run also writes the full JSON report (`<Target>.stability.json`) to the plugin's output directory in DerivedData (`…/BuildToolPluginIntermediates/…/SwiftUIStabilityPlugin/`).

## Rules

| Rule | Severity | What |
|---|---|---|
| `closure-property` | warning | A stored closure keeps the view from skipping |
| `stored-view-builder` | warning | `let content: () -> Content`; store `Content` instead |
| `observed-object-initialized` | warning | `@ObservedObject var x = X()` is recreated by the parent |
| `state-plain-class` | warning | `@State` holding a non-`@Observable` class |
| `frequent-updates` | warning / info | An observed object whose class has a display link, timer or sleep loop that writes observed state on each tick (directly or through its own methods; one-shot writes followed by `break`/`return` don't count). Each tick re-runs `body`. Warning for an ObservableObject (whole body), info for `@Observable` |
| `foreach-inline-transform` | warning | `ForEach(items.filter …)` recomputed every body |
| `foreach-indices` | warning | `ForEach(items.indices)` ties identity to position |
| `foreach-id-self` | info | `id: \.self` identifies rows by value |
| `observable-object` | info | ObservableObject invalidates on any `@Published` change |
| `any-view` | info | `AnyView` erases structural identity |

### Suppressing a finding

When a finding is intended, say so next to the code with `// swiftui-stability:ignore <rule> — reason`:

```swift
// swiftui-stability:ignore state-plain-class — holds a weak scroll view and the last handled row;
// its changes must not re-render.
@State private var tracker = ScrollTracker()

let onTap: () -> Void  // swiftui-stability:ignore closure-property
```

- **In a comment above the code**, it can be on any line of the comment block (so the reason can wrap) and applies to the first code line after the block, including attribute lines such as `@MainActor`. A blank line between the comment and the code detaches it.
- **At the end of a line**, it applies to that line.

List several rules separated by commas, or leave out the rule to silence every finding on that line. `// swiftui-stability:ignore stability` on a type's declaration silences its "can't skip" warning in Xcode. The baseline still records the type, so `check` still catches it getting worse. Suppressed findings are listed in `analyze` output and in `--json` (`suppressed`).

## CI (GitHub Actions)

Commit a baseline (`swiftui-stability dump MyApp/` → `stability/baseline.stability`), then fail pull requests that make views less stable:

```yaml
- name: SwiftUI stability
  run: |
    git clone --depth 1 --branch 0.3.2 https://github.com/alejandrorangel/swiftui-stability-analyzer /tmp/ssa
    swift build -c release --package-path /tmp/ssa --product swiftui-stability
    /tmp/ssa/.build/release/swiftui-stability check MyApp/ --ignore-non-regressive
```

To accept an intended change, run `dump` again and commit the updated baseline together with the code.

## Develop

```sh
swift build
swift test
```

## Inspiration

This project is inspired by [compose-stability-analyzer](https://github.com/skydoves/compose-stability-analyzer) by [Jaewoong Eum (skydoves)](https://github.com/skydoves), which does this for Jetpack Compose. It borrows that project's ideas and vocabulary: the four stability levels (stable, runtime, unknown, unstable), a committed baseline checked in CI (`dump` / `check`, with `~ + -` change notation), inline IDE feedback, and runtime tracing as the next step. The implementation is separate, and this project isn't affiliated with it.

SwiftUI's diffing rules are undocumented. The model here follows public write-ups, chiefly [Airbnb's Understanding and Improving SwiftUI Performance](https://airbnb.tech/web/understanding-and-improving-swiftui-performance/) and [Chris Eidhof's notes on SwiftUI view equality](https://chris.eidhof.nl/note/swiftui-view-equality); see [PLAN.md](PLAN.md) for what still needs verifying.
