import Foundation
import XcodeKit

final class SourceEditorExtension: NSObject, XCSourceEditorExtension {
    var commandDefinitions: [[XCSourceEditorCommandDefinitionKey: Any]] {
        StabilityCommand.Kind.allCases.map { kind in
            [
                .identifierKey: kind.rawValue,
                .classNameKey: NSStringFromClass(StabilityCommand.self),
                .nameKey: kind.title,
            ]
        }
    }
}
