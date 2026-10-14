import Darwin
import Foundation
import Testing
@testable import Tact

@MainActor
struct PlatformConnectionTests {
    @Test(arguments: ["unknown-op", "missing-catalog"])
    func oldEngineStopsBeforeReadingChats(kind: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let response: [String: Any] = kind == "unknown-op"
            ? ["ok": false, "error_code": "bad_request", "error": "未知操作 platforms"] : ["ok": true]
        let server = try PlatformProbeServer(responses: [response])
        let controller = fixture.controller(socket: server.path)
        let result = await controller.checkPlatformConnection(id: "company-chat")
        #expect(!result.ok && result.count == nil)
        #expect(result.message.contains(L10n.tr("引擎版本过旧", "The engine is too old")) && result.message.contains(L10n.tr("重启", "restart")))
        let requests = await server.finished.value
        #expect(requests.map(\.op) == ["platforms"])
    }

    @Test(arguments: [true, false])
    func newEngineCanTestAnExplicitEnabledOrDisabledPlatform(enabled: Bool) async throws {
        let fixture = try Fixture(enabled: enabled)
        defer { fixture.cleanup() }
        let count = enabled ? 3 : 0
        let server = try PlatformProbeServer(responses: [fixture.catalog,
            ["ok": true, "platform_id": "company-chat", "count": count]])
        let result = await fixture.controller(socket: server.path).checkPlatformConnection(id: "company-chat")
        #expect(result.ok && result.count == count)
        #expect(result.message.contains(L10n.tr("\(count) 个会话", "\(count) chats")))
        let requests = await server.finished.value
        #expect(requests.map(\.op) == ["platforms", "platform_test"])
        #expect(requests.last?.platformID == "company-chat")
    }

    @Test func responseFromAnotherPlatformIsNeverAccepted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let server = try PlatformProbeServer(responses: [fixture.catalog,
            ["ok": true, "platform_id": "different-platform", "count": 3]])
        let result = await fixture.controller(socket: server.path).checkPlatformConnection(id: "company-chat")
        #expect(!result.ok && result.count == nil)
        #expect(result.message.contains(L10n.tr("所选平台不一致", "does not match the selection")))
        #expect(await server.finished.value.map(\.op) == ["platforms", "platform_test"])
    }

    @Test(arguments: ["id", "plugin_id", "version", "capabilities", "command", "manifest", "duplicate"])
    func mismatchedDeclarationStopsBeforeRunningThePlugin(field: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var declaration = fixture.declaration
        switch field {
        case "capabilities": declaration[field] = ["conversations.list": true, "messages.read": false]
        case "command": declaration[field] = ["/wrong/adapter"]
        case "manifest": declaration[field] = "/wrong/plugin/manifest.json"
        case "duplicate": break
        default: declaration[field] = "different"
        }
        let entries = field == "duplicate" ? [declaration, declaration] : [declaration]
        let server = try PlatformProbeServer(responses: [["ok": true, "platforms": entries]])
        let result = await fixture.controller(socket: server.path).checkPlatformConnection(id: "company-chat")
        #expect(!result.ok && result.count == nil)
        #expect(result.message.contains(L10n.tr("配置尚未生效", "settings have not taken effect")))
        #expect(await server.finished.value.map(\.op) == ["platforms"])
    }

    @Test(arguments: ["-1", "true", "\"3\"", "3.5", "null"])
    func malformedCountNeverBecomesAConnectionSuccess(value: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let response = try #require(JSONSerialization.jsonObject(with: Data(
            "{\"ok\":true,\"platform_id\":\"company-chat\",\"count\":\(value)}".utf8)) as? [String: Any])
        let server = try PlatformProbeServer(responses: [fixture.catalog, response])
        let result = await fixture.controller(socket: server.path).checkPlatformConnection(id: "company-chat")
        #expect(!result.ok && result.count == nil)
        #expect(await server.finished.value.map(\.op) == ["platforms", "platform_test"])
    }

    private struct Fixture {
        let directory: URL
        let manifestPath: String
        let enabled: Bool
        let manifest: PlatformManifest

        init(enabled: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("platform-probe-\(UUID().uuidString)")
            manifestPath = directory.appendingPathComponent("manifest.json").path
            self.enabled = enabled
            var desktop = PlatformDesktop.defaultProfile
            desktop.bundleIDs = ["test.company.desktop"]
            manifest = PlatformManifest(protocolVersion: 1, id: "test.company", name: "Company Chat", version: "1.0.0",
                transport: "command-v1", entrypoint: ["/usr/bin/python3", "${plugin_dir}/adapter.py"],
                capabilities: ["conversations.list": true, "messages.read": true], desktop: desktop, limits: nil)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: URL(fileURLWithPath: manifestPath))
        }

        var declaration: [String: Any] {
            ["id": "company-chat", "plugin_id": manifest.id, "version": manifest.version,
             "enabled": enabled, "available": enabled, "state": enabled ? "ready" : "disabled",
             "manifest": manifestPath, "capabilities": manifest.capabilities,
             "command": ["/usr/bin/python3", directory.appendingPathComponent("adapter.py").path]]
        }
        var catalog: [String: Any] { ["ok": true, "platforms": [declaration]] }

        @MainActor func controller(socket: String) -> Controller {
            let file = ConfigFile(root: ["platforms": [["id": "company-chat", "manifest": manifestPath, "enabled": enabled]]])
            var config = AppConfig()
            config.socketPath = socket
            // The external fake server must never be replaced or terminated.
            config.engineCommand = ["/usr/bin/false"]
            config.platformRegistry = PlatformRegistry(file: file, configPath: directory.appendingPathComponent("config.json").path)
            return Controller(config: config)
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}

/// A bounded local socket fixture. No process, chat CLI or model is started.
private final class PlatformProbeServer: @unchecked Sendable {
    struct Request: Sendable { let op: String; let platformID: String? }
    let path = "/tmp/gr-probe-\(UUID().uuidString).sock"
    let finished: Task<[Request], Never>

    init(responses: [[String: Any]]) throws {
        let encoded = try responses.map { try JSONSerialization.data(withJSONObject: $0) + Data([0x0A]) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            unlink(path)
            throw POSIXError(.EIO)
        }
        let socketPath = path
        finished = Task.detached {
            await withCheckedContinuation { continuation in
                // Blocking socket I/O must not occupy Swift's cooperative thread pool:
                // the MainActor client needs that pool to resume between requests.
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(fd); unlink(socketPath) }
                    continuation.resume(returning: Self.reply(on: fd, responses: encoded))
                }
            }
        }
    }

    private static func reply(on fd: Int32, responses: [Data]) -> [Request] {
        var requests: [Request] = []
        for response in responses {
            // MainActor snapshot/Metal work may delay the next call after a response.
            // The dedicated GCD worker waits independently, with a bounded window.
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            guard wait(on: fd, events: Int16(POLLIN), until: deadline) else { return requests }
            var client: Int32
            repeat { client = accept(fd, nil, nil) } while client < 0 && errno == EINTR
            guard client >= 0 else { return requests }
            guard let request = exchange(on: client, response: response) else { return requests }
            requests.append(request)
        }
        return requests
    }

    private static func exchange(on fd: Int32, response: Data) -> Request? {
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var input = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !input.contains(0x0A) {
            guard input.count < 65_536, wait(on: fd, events: Int16(POLLIN), until: deadline) else { return nil }
            let count = read(fd, &buffer, min(buffer.count, 65_536 - input.count))
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return nil }
            input.append(contentsOf: buffer[..<count])
        }
        guard let newline = input.firstIndex(of: 0x0A),
              let raw = try? JSONSerialization.jsonObject(with: Data(input[..<newline])) as? [String: Any],
              let op = raw["op"] as? String else { return nil }
        var sent = 0
        while sent < response.count {
            guard wait(on: fd, events: Int16(POLLOUT), until: deadline) else { return nil }
            let count = response.withUnsafeBytes {
                write(fd, $0.baseAddress!.advanced(by: sent), $0.count - sent)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { return nil }
            sent += count
        }
        return Request(op: op, platformID: raw["platform_id"] as? String)
    }

    private static func wait(on fd: Int32, events: Int16, until deadline: TimeInterval) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var ready = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&ready, 1, Int32(min(100, ceil(remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            if result < 0 { return false }
            if result > 0 { return ready.revents & events != 0 }
        }
    }

    deinit { unlink(path) }
}
