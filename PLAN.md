# SwiftUI Stability Analyzer — plan

_Started 2026-10-15 · Swift 6.4, swift-syntax 604, Xcode 27_

The SwiftUI counterpart of [compose-stability-analyzer](https://github.com/skydoves/compose-stability-analyzer): tell people and agents which views can skip `body` when their parent re-renders, why not, and catch regressions in CI. Sibling project of [ios-cli](https://github.com/alejandrorangel/ios-cli), built in the same agent-first way: every command has `--json` output, and an agent skill will ship with it.

## The core difference from Compose

Compose has a formal model. The compiler infers stability, writes `$stable` fields and marks composables skippable, so the Compose tool reads facts from the compiler. **SwiftUI's diffing is undocumented.** What's commonly observed ([Airbnb](https://airbnb.tech/web/understanding-and-improving-swiftui-performance/), [Chris Eidhof](https://chris.eidhof.nl/note/swiftui-view-equality)):

- Before re-running a child's `body`, SwiftUI compares the child's stored properties with their previous values.
- Equatable types are compared with `==`, other value types field by field, and classes by identity.
- Closures practically never compare equal, so one closure property makes the view re-run with its parent.
- Property wrappers SwiftUI owns (`@State`, `@Environment`…) aren't compared. They invalidate the view directly: an ObservableObject on any `@Published` change, an `@Observable` class only for the properties `body` read.
- A view that conforms to `Equatable` and is wrapped in `.equatable()` uses its own `==`.

So the static analysis is a **model of SwiftUI's behavior**, and Phase 0 has to verify that model at runtime.

## Compose → SwiftUI mapping

| Compose analyzer | Here | Status |
|---|---|---|
| Compiler plugin (stability inference) | `StabilityCore`: swift-syntax, cross-file type index, classifier | ✅ v0.1 |
| `STABLE / RUNTIME / UNKNOWN / UNSTABLE` | Same four levels (`runtime` = generic parameter) | ✅ |
| Skippable / restartable | `skippable: yes / depends / no` (no restartable concept in SwiftUI) | ✅ |
| `stabilityDump` / `stabilityCheck` | `swiftui-stability dump` / `check` (`--ignore-non-regressive`, `--allow-missing-baseline`) | ✅ |
| IDE gutter icons and inspections | Build tool plugin: inline warnings in Xcode (SwiftPM targets and Xcode app targets) | ✅ v0.2 |
| Stability Doctor one-click fixes | Source Editor Extension commands | 🔜 Phase 2 |
| `@TraceRecomposition` | Insert/remove `let _ = Self._logChanges()` (extension command), read via unified log | 🔜 Phase 3 |
| Live heatmap / Reality Check | `xctrace record --template SwiftUI` → body-update counts per view, joined with static verdicts | 🔜 Phase 3 |
| — | Agent skill + `--json` everywhere | 🔜 Phase 4 |

Why not a macro for tracing? Body macros (SE-0415) [can't attach to a property's getter](https://forums.swift.org/t/body-macros-on-properties/85357) such as `var body`, and they still need an experimental flag. Inserting the source line is simpler, and it works in every Xcode.

## Delivery surfaces

All of them share `StabilityCore`, so there's one implementation of the rules.

1. **CLI** (`swiftui-stability`): analyze, dump, check. Used by CI, by agents, and by the other two surfaces.
2. **Build tool plugin** (SwiftPM `BuildToolPlugin` + `XcodeBuildToolPlugin`): runs the analyzer on the target's sources each build and prints `--format xcode` lines. Xcode shows them as inline warnings in the editor and the Issue navigator. **This is the closest to Compose's IDE annotations**, and it sees the whole target, so cross-file types resolve.
3. **Xcode Source Editor Extension** ([XcodeKit](https://developer.apple.com/documentation/xcodekit/creating-a-source-editor-extension)): menu commands that edit the current file. Constraints: it's sandboxed, it only receives the open buffer's text (`XCSourceTextBuffer`, no other files, so types from other files show as `unknown`), it runs only when you pick its command, and it can't draw gutter icons or panels; its UI is the text edit or an error message. That makes it a fit for **fixes**, not for reporting:
   - *Add Equatable conformance excluding closures* + remind to apply `.equatable()`
   - *Store built content instead of a `@ViewBuilder` closure*
   - *Toggle body tracing* (`let _ = Self._logChanges()` in the selected view's body)
   - *Annotate view* (inserts a `// stability: …` comment above the view)
   The extension must ship inside a macOS host app, signed, and enabled in System Settings → Login Items & Extensions → Xcode Source Editor.

## Phases

0. **Validate the model** (next). Build a fixture app with one view per property kind: Int, Equatable struct, non-Equatable struct of values, struct holding a closure, closure, class, Binding, generic content, AnyView, `@ViewBuilder` closure vs stored content. Re-render the parent N times and count each child's body runs with `_logChanges()`, run it through ios-cli (`ios run`, `ios logs`). Lock the results into the rules and into tests. Open questions: Binding comparison, non-capturing closures, POD memcmp vs field-wise, AnyView, whether Equatable views use `==` without `.equatable()`.
1. **Static analyzer** ✅ v0.1: classifier, findings, dump/check, xcode format, 19 tests.
   - Next: `.stability-config` for types from other modules (`Foundation.Measurement=stable`, `MyKit.*=stable`, as in Compose's stability configuration file); per-line suppression (`// stability:ignore closure-property`); module-qualified names in the baseline when two modules declare the same view name.
2. **Xcode integration**
   - ✅ **Build tool plugin** (v0.2). Verified with `swift build` on `Examples/PluginDemo`, with `xcodebuild` on the package for the iOS Simulator, and in an Xcode app project (synchronized folders, plugin added as a target dependency). The warnings show up in the `.xcresult` as structured issues with file and line, which is what drives the editor annotations and the Issue navigator. Findings from the build:
     - SwiftPM only allows prebuild commands to run prebuilt binaries, so the source-built tool runs as a **build command**.
     - Build commands run only when inputs change, and Xcode doesn't replay a skipped command's warnings: on a no-op build they disappeared (0 in the `.xcresult`). The tool now touches a trigger file that's one of its own inputs, so it runs every build. A no-op build in Xcode has 0 compile tasks and still shows the warnings.
     - Any declared output that isn't source becomes a resource: a `.json` output was copied into a `PluginDemo_DemoViews.bundle`. The declared output is a comment-only Swift file (rewritten only when it changes); the JSON report is a side file.
     - Next: a prebuilt `artifactbundle` + `binaryTarget` release (as SwiftLint does) so adopters don't compile swift-syntax; a config file to pick rules and severities, and to turn regressions against the baseline into errors.
   - Source Editor Extension with the commands above.
3. **Runtime**: `swiftui-stability trace` driving `xctrace record --template SwiftUI --launch` (or attach), `xctrace export` → per-view body counts (heatmap) → reality check: *Confirmed* (predicted unstable, re-runs often), *False alarm* (predicted unstable, rarely re-runs), *Silent waste* (predicted stable, re-runs often). The SwiftUI template exists in this Xcode (`xctrace list templates`); its export schema still needs a spike.
4. **Agents**: ✅ skill (`skills/swiftui-stability/SKILL.md`, installed by `scripts/install.sh --skill`): when to run, before/after workflow, reading the output, a fix per rule. Next: a prebuilt release binary with a one-line installer (as ios-cli's `get.sh`); optionally an `ios stability` passthrough in ios-cli.

## Known limits of v0.1

- Purely syntactic: types from other modules are `unknown` (Phase 1 config fixes the common ones). Protocol existentials are `unknown`.
- Name resolution is by scope then simple name; two types with the same name in different modules can be confused.
- Finding rules are heuristics over the syntax tree (e.g. `.filter` anywhere in a `ForEach` data argument).
