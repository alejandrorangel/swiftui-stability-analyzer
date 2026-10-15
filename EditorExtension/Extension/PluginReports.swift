import Foundation
import StabilityCore

/// The build plugin's latest reports (`<Target>.stability.json` in DerivedData), analyzed with the whole module,
/// so annotations can use cross-file verdicts. The extension only gets the current file from Xcode.
enum PluginReports {
    static func latest() -> [ViewReport] {
        // Inside the sandbox, the home directory is the container's; DerivedData is read through a read-only
        // temporary exception for ~/Library/Developer/Xcode/DerivedData.
        guard let home = getpwuid(getuid())?.pointee.pw_dir.map({ String(cString: $0) }) else { return [] }
        let derivedData = URL(fileURLWithPath: home).appending(path: "Library/Developer/Xcode/DerivedData")
        let manager = FileManager.default
        var newest: [String: (date: Date, url: URL)] = [:]
        for project in (try? manager.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? [] {
            let plugins = project.appending(path: "Build/Intermediates.noindex/BuildToolPluginIntermediates")
            guard let files = manager.enumerator(at: plugins, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in files where url.lastPathComponent.hasSuffix(".stability.json") {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                // One report per target name: the most recently built one.
                if date > newest[url.lastPathComponent]?.date ?? .distantPast {
                    newest[url.lastPathComponent] = (date, url)
                }
            }
        }
        return newest.values.flatMap { entry -> [ViewReport] in
            guard let data = try? Data(contentsOf: entry.url) else { return [] }
            return (try? JSONDecoder().decode([ViewReport].self, from: data)) ?? []
        }
    }
}
