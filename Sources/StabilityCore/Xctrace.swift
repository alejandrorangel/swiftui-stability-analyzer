import Foundation

/// Records and exports View Body data with `xcrun xctrace`.
public enum Xctrace {
    public enum Target {
        /// Launch this `.app` (on a simulator or device) for the recording.
        case launch(app: String)
        /// Attach to a running process by PID or name.
        case attach(String)
    }

    public static func record(_ target: Target, device: String?, timeLimit: String, output: String) throws {
        var arguments = ["xctrace", "record", "--instrument", BodyTrace.instrument, "--time-limit", timeLimit,
                         "--output", output, "--no-prompt"]
        if let device { arguments += ["--device", try resolveDevice(device)] }
        switch target {
        case .launch(let app): arguments += ["--launch", "--", app]
        case .attach(let process): arguments += ["--attach", process]
        }
        let result = try run(arguments)
        guard FileManager.default.fileExists(atPath: output) else {
            throw XctraceError.failed("xctrace record", result.output)
        }
    }

    /// A simulator name like "iPhone 17" usually exists for several runtimes, which xctrace rejects as ambiguous;
    /// prefer the booted one. UDIDs and device names pass through.
    static func resolveDevice(_ device: String) throws -> String {
        let list = try run(["simctl", "list", "devices", "booted", "--json"])
        guard list.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(list.output.utf8)) as? [String: Any],
              let runtimes = json["devices"] as? [String: [[String: Any]]] else { return device }
        let booted = runtimes.values.joined().filter { $0["state"] as? String == "Booted" }
        let matches = booted.filter { $0["name"] as? String == device }.compactMap { $0["udid"] as? String }
        return matches.count == 1 ? matches[0] : device
    }

    /// The View Body table and the recording's duration.
    public static func bodyTrace(from trace: String) throws -> BodyTrace {
        let toc = try run(["xctrace", "export", "--input", trace, "--toc"])
        guard toc.status == 0 else { throw XctraceError.failed("xctrace export", toc.output) }
        let duration = toc.output.range(of: #"<duration>([0-9.]+)</duration>"#, options: .regularExpression)
            .map { toc.output[$0].dropFirst("<duration>".count).dropLast("</duration>".count) }
            .flatMap { Double($0) }
        let xpath = #"/trace-toc/run[@number="1"]/data/table[@schema="\#(BodyTrace.schema)"]"#
        let export = try run(["xctrace", "export", "--input", trace, "--xpath", xpath])
        guard export.status == 0 else { throw XctraceError.failed("xctrace export", export.output) }
        return try BodyTrace(exportXML: Data(export.output.utf8), duration: duration)
    }

    private static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would block xctrace.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

public enum XctraceError: Error, CustomStringConvertible {
    case failed(String, String)

    public var description: String {
        switch self {
        case .failed(let command, let output):
            "\(command) failed:\n\(output.split(separator: "\n").suffix(8).joined(separator: "\n"))"
        }
    }
}
