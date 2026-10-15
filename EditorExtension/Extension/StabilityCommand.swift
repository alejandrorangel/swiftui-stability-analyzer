import Foundation
import StabilityCore
import XcodeKit

/// Runs one of `Fixes` on the current file and replaces the buffer with the result. Failures (nothing safe to
/// do) are shown by Xcode as an alert with the message.
final class StabilityCommand: NSObject, XCSourceEditorCommand {
    enum Kind: String, CaseIterable {
        case capture = "dev.stability.capture-closure-dependencies"
        case equatable = "dev.stability.make-equatable"
        case printChanges = "dev.stability.toggle-print-changes"
        case ignore = "dev.stability.ignore-finding"
        case annotate = "dev.stability.toggle-annotations"

        var title: String {
            switch self {
            case .capture: "Capture What the Closure Needs"
            case .equatable: "Make Equatable Without Closures"
            case .printChanges: "Toggle Self._printChanges()"
            case .ignore: "Ignore Finding on This Line"
            case .annotate: "Toggle Stability Annotations"
            }
        }

        func apply(to source: String, line: Int) throws -> String {
            switch self {
            case .capture: try Fixes.captureClosureDependencies(in: source, line: line)
            case .equatable: try Fixes.makeEquatable(in: source, line: line)
            case .printChanges: try Fixes.togglePrintChanges(in: source, line: line)
            case .ignore: try Fixes.ignoreFinding(in: source, line: line)
            case .annotate: try Fixes.toggleStabilityAnnotations(in: source, moduleReports: PluginReports.latest())
            }
        }
    }

    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        guard let kind = Kind(rawValue: invocation.commandIdentifier) else {
            completionHandler(nil)
            return
        }
        let buffer = invocation.buffer
        let selection = buffer.selections.firstObject as? XCSourceTextRange
        // XcodeKit lines are 0-based; Fixes uses 1-based lines like the analyzer.
        let line = (selection?.start.line ?? 0) + 1
        do {
            let updated = try kind.apply(to: buffer.completeBuffer, line: line)
            guard updated != buffer.completeBuffer else {
                completionHandler(nil)
                return
            }
            buffer.completeBuffer = updated
            // Keep the cursor on its code; "ignore" inserted a line above it.
            if let selection {
                let line = min(selection.start.line + (kind == .ignore ? 1 : 0), buffer.lines.count - 1)
                let position = XCSourceTextPosition(line: line, column: selection.start.column)
                buffer.selections.setArray([XCSourceTextRange(start: position, end: position)])
            }
            completionHandler(nil)
        } catch {
            completionHandler(NSError(domain: "SwiftUIStability", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: (error as? FixError)?.description ?? "\(error)"]))
        }
    }
}
