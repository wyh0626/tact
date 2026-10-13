import Foundation
@testable import Tact

/// A complete plugin package, as a chat tool's provider would ship it,
/// written to a temporary folder once per test run.
enum ExamplePlugin {
    static let id = "example.chat"
    static let name = "Example Chat"
    static let version = "1.0.0"
    static let bundleID = "com.example.chat"

    /// The package's manifest; its folder holds the adapter too.
    static let manifest: String = {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tact-example-plugin-\(UUID().uuidString)/example-chat", isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "protocol_version": 1, "id": id, "name": name, "version": version, "transport": "command-v1",
            "setup": [
                "summary": "Example Chat 通过它的命令行工具读取会话。",
                "requirements": ["已安装并登录 Example Chat"],
                "commands": [
                    ["title": "登录账号", "command": "examplechat login ${input}",
                     "detail": "终端里会提示输入验证码。", "input_placeholder": "账号邮箱"],
                ],
                "help_url": "https://example.com/help",
            ] as [String: Any],
            "entrypoint": ["/usr/bin/python3", "${plugin_dir}/adapter.py"],
            "capabilities": ["conversations.list": true, "messages.read": true, "composer.read": true,
                             "composer.apply": true, "overlay.inline": true, "events.subscribe": false],
            "desktop": ["strategy": "ax-ocr-v1", "bundle_ids": [bundleID],
                        "header": ["top_offset": 28, "height": 64, "left_padding": 0],
                        "overlay": ["font_size": 13, "offset_x": 0, "offset_y": 0],
                        "send_shortcut": "return"] as [String: Any],
            "limits": ["timeout_ms": 15000, "chats_cache_seconds": 300],
        ]
        try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let adapter = """
        import json, sys
        if sys.argv[1:2] == ["chats"]:
            print(json.dumps({"chats": [{"id": "1", "title": "张三"}]}))
        elif sys.argv[1:2] == ["history"]:
            print(json.dumps({"messages": [{"id": "m1", "from_me": False, "text": "到了吗"}]}))
        else:
            sys.exit(3)
        """
        try! adapter.write(to: folder.appendingPathComponent("adapter.py"), atomically: true, encoding: .utf8)
        return folder.appendingPathComponent("manifest.json").path
    }()

    static var folder: URL { URL(fileURLWithPath: manifest).deletingLastPathComponent() }
}
