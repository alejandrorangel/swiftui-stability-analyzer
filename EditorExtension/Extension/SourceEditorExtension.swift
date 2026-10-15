import Foundation
import XcodeKit

/// The commands are declared in Info.plist (XCSourceEditorCommandDefinitions), so Xcode can build the
/// Editor menu without launching the extension; `StabilityCommand.Kind` must use the same identifiers.
final class SourceEditorExtension: NSObject, XCSourceEditorExtension {}
