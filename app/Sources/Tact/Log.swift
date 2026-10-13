import Foundation

/// `info` goes to stdout and ~/.tact/app.log. `console` goes to stdout
/// only and is used for anything that may contain chat names or text.
enum Log {
    private static let queue = DispatchQueue(label: "tact.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        print(line)
        fflush(stdout)
        queue.async {
            let path = (AppConfig.directory as NSString).appendingPathComponent("app.log")
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(atPath: AppConfig.directory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
            }
        }
    }

    static func console(_ message: String) {
        print("\(formatter.string(from: Date())) \(message)")
        fflush(stdout)
    }
}
