import Foundation
import SwiftUI
@testable import Tact

/// Writes screens to PNG files for review, in $TACT_SNAPSHOT_DIR or a
/// folder in the temporary directory.
@MainActor
enum Snapshot {
    static let directory: URL = {
        let env = ProcessInfo.processInfo.environment["TACT_SNAPSHOT_DIR"]
        let url = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tact-snapshots")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @discardableResult
    static func render<V: View>(_ view: V, name: String, size: CGSize, dark: Bool = false) -> URL? {
        guard let data = ViewRenderer.png(view, size: size, dark: dark) else { return nil }
        let url = directory.appendingPathComponent("\(name).png")
        return (try? data.write(to: url)) == nil ? nil : url
    }
}
