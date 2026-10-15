import Darwin
import Foundation
import Testing
@testable import Tact

@MainActor
struct ModelConnectionTimeoutTests {
    @Test(arguments: [0, 20000, 60000, 120000, 1_800_000])
    func cloudTestWaitsForModelDeadlineAndItsErrorResponse(timeoutMS: Int) {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "deepseek", "base_url": ModelProvider.deepseek.baseURL,
                                                                     "model": "deepseek-flash", "timeout_ms": timeoutMS]]))
        let effectiveSeconds = TimeInterval(timeoutMS > 0 ? timeoutMS : 20000) / 1000
        #expect(settings.connectionTestTimeout == effectiveSeconds + 5)
        #expect(settings.connectionTestTimeout > effectiveSeconds)
    }

    @Test func localTestKeepsItsLongStartupWindow() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "local", "timeout_ms": 60000]]))
        #expect(settings.connectionTestTimeout == 180)
    }

    @Test func testModelAcceptsDelayedReplyWithinItsWaitBudget() async throws {
        let server = try DelayedModelTestServer(response: ["ok": true, "note": "OK", "timing_ms": ["model": 20]], delayMicroseconds: 20_000)
        let result = await controller(socket: server.path).testModel(timeout: 1)
        #expect(result.ok && result.message.contains("OK"))
        #expect(await server.finished.value == "model_test")
    }

    @Test func IPCReadTimeoutIsReportedAsTimeoutInsteadOfMissingEngine() async throws {
        let server = try DelayedModelTestServer(response: ["ok": true, "note": "OK"], delayMicroseconds: 300_000)
        let result = await controller(socket: server.path).testModel(timeout: 0.05)
        #expect(!result.ok)
        #expect(result.message == EngineError.timeout.localizedDescription)
        #expect(result.message != EngineError.connect(ECONNREFUSED).localizedDescription)
        #expect(await server.finished.value == "model_test")
    }

    @Test func modelDeadlineErrorFromEngineIsPreserved() async throws {
        let server = try DelayedModelTestServer(response: ["ok": false, "error_code": "model_error", "error": "context deadline exceeded"],
                                                delayMicroseconds: 20_000)
        let result = await controller(socket: server.path).testModel(timeout: 1)
        #expect(!result.ok && result.message == "context deadline exceeded")
        #expect(await server.finished.value == "model_test")
    }

    @Test func unavailableEngineRetainsConnectionFailure() async {
        let result = await controller(socket: "/tmp/tact-missing-\(UUID().uuidString).sock").testModel(timeout: 0.05)
        #expect(!result.ok && result.message == EngineError.connect(ENOENT).localizedDescription)
    }

    private func controller(socket: String) -> Controller {
        var config = AppConfig()
        config.socketPath = socket
        config.engineCommand = ["/usr/bin/false"]
        return Controller(config: config)
    }
}

/// One bounded socket exchange, with its delay on a dedicated GCD worker.
/// Never calls a model API or starts an engine process.
private final class DelayedModelTestServer: @unchecked Sendable {
    let path = "/tmp/tact-model-\(UUID().uuidString).sock"
    let finished: Task<String?, Never>

    init(response: [String: Any], delayMicroseconds: useconds_t) throws {
        let encoded = try JSONSerialization.data(withJSONObject: response) + Data([0x0A])
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            Darwin.close(listener)
            unlink(path)
            throw POSIXError(.EIO)
        }
        let socketPath = path
        finished = Task.detached {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { Darwin.close(listener); unlink(socketPath) }
                    var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                    guard poll(&ready, 1, 2000) > 0 else { continuation.resume(returning: nil); return }
                    let client = accept(listener, nil, nil)
                    guard client >= 0 else { continuation.resume(returning: nil); return }
                    defer { Darwin.close(client) }
                    var noSignal: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                    var timeout = timeval(tv_sec: 1, tv_usec: 0)
                    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    var input = Data()
                    while !input.contains(0x0A) && input.count < 4096 {
                        let count = read(client, &buffer, buffer.count)
                        guard count > 0 else { continuation.resume(returning: nil); return }
                        input.append(contentsOf: buffer[..<count])
                    }
                    let request = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
                    usleep(delayMicroseconds)
                    _ = encoded.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                    continuation.resume(returning: request?["op"] as? String)
                }
            }
        }
    }

    deinit { unlink(path) }
}
