import SwiftUI

/// The host app only exists to carry the Xcode Source Editor Extension; this window explains how to turn it on.
@main
struct SwiftUIStabilityApp: App {
    var body: some Scene {
        WindowGroup("SwiftUI Stability") {
            VStack(alignment: .leading, spacing: 12) {
                Text("SwiftUI Stability for Xcode").font(.title2.bold())
                Text("1. Open System Settings → General → Login Items & Extensions → Xcode Source Editor, and turn on SwiftUI Stability.")
                Text("2. Restart Xcode.")
                Text("3. In a Swift file: Editor → SwiftUI Stability → a command. Assign shortcuts in Xcode → Settings → Key Bindings.")
                Text("The commands: capture what a closure needs, make a view Equatable without its closures, toggle Self._printChanges(), and ignore the finding on the current line.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 520)
        }
        .windowResizability(.contentSize)
    }
}
