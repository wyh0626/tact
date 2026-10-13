import Foundation

/// The engine's feedback summary as figures for the statistics pane.
struct StatsData: Equatable {
    let triggers: Int
    let generated: Int
    let empty: Int
    let errors: Int
    let shown: Int
    let accepted: Int
    let sent: Int
    let sentUnchanged: Int
    let medianLatencyMS: Int
    let p90LatencyMS: Int

    init(_ d: [String: Any]) {
        func int(_ key: String) -> Int { (d[key] as? NSNumber)?.intValue ?? 0 }
        triggers = int("triggers")
        generated = int("generated")
        empty = int("empty")
        errors = int("errors")
        shown = int("shown")
        accepted = int("accepted")
        sent = int("sent")
        sentUnchanged = int("sent_unchanged")
        medianLatencyMS = int("median_latency_ms")
        p90LatencyMS = int("p90_latency_ms")
    }

    /// Share of shown suggestions that were accepted, 0...1.
    var acceptRate: Double? { shown > 0 ? Double(accepted) / Double(shown) : nil }
    /// Share of sent suggestions that went out without edits, 0...1.
    var unchangedRate: Double? { sent > 0 ? Double(sentUnchanged) / Double(sent) : nil }
}
