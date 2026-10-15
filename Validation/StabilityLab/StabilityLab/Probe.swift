import Foundation

/// Counts `body` evaluations per view type and prints them as one JSON line when the run ends.
enum Probe {
    private static var counts: [String: Int] = [:]

    static func hit<T>(_ type: T.Type) {
        counts[String(describing: type), default: 0] += 1
    }

    static func report(parentUpdates: Int) {
        let payload: [String: Any] = [
            "parentUpdates": parentUpdates,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "counts": counts,
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print("STABILITY_LAB_RESULT " + String(decoding: data, as: UTF8.self))
    }
}
