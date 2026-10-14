import Darwin
import Foundation

enum EngineError: LocalizedError {
    case pathTooLong
    case socket(Int32)
    case connect(Int32)
    case io(Int32)
    case timeout
    case cancelled
    case badResponse

    var errorDescription: String? {
        switch self {
        case .pathTooLong: return L10n.tr("引擎 socket 路径太长", "The engine socket path is too long")
        case .socket(let e), .io(let e): return L10n.tr("和引擎通信出错：\(String(cString: strerror(e)))", "Engine communication failed: \(String(cString: strerror(e)))")
        case .connect: return L10n.tr("连不上引擎，先运行 tactd serve，或在配置里填 app.engine_command", "Cannot connect to the engine. Run tactd serve or set app.engine_command in the configuration")
        case .timeout: return L10n.tr("引擎响应超时", "The engine timed out")
        case .cancelled: return L10n.tr("已取消", "Cancelled")
        case .badResponse: return L10n.tr("引擎返回了无法解析的内容", "The engine returned an unreadable response")
        }
    }
}

/// Lets the caller abort a request that is blocked in read(): shutting the
/// socket down makes the engine see the hang-up and cancel its work too.
/// @unchecked: all mutable state is guarded by `lock`, which the compiler cannot verify.
final class EngineCall: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    fileprivate func attach(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.fd = fd
        return true
    }

    fileprivate func detach() {
        lock.lock()
        fd = -1
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }
}

/// One JSON line out, one JSON line back, over the engine's Unix socket.
final class EngineClient: Sendable {
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func call(_ payload: [String: Any], timeout: TimeInterval, token: EngineCall? = nil) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.callSync(payload, timeout: timeout, token: token))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func callSync(_ payload: [String: Any], timeout: TimeInterval, token: EngineCall? = nil) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.socket(errno) }
        defer {
            token?.detach()
            close(fd)
        }
        if let token = token, !token.attach(fd) { throw EngineError.cancelled }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw EngineError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (i, byte) in pathBytes.enumerated() { buffer[i] = byte }
            buffer[pathBytes.count] = 0
        }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw EngineError.connect(errno) }

        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw EngineError.io(errno) }
                offset += n
            }
        }

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 {
                if token?.isCancelled == true { throw EngineError.cancelled }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw EngineError.timeout }
                throw EngineError.io(errno)
            }
            if n == 0 { break }
            received.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break }
        }
        if token?.isCancelled == true { throw EngineError.cancelled }
        guard !received.isEmpty else { throw EngineError.badResponse }
        let end = received.firstIndex(of: 0x0A) ?? received.endIndex
        let line = received.subdata(in: received.startIndex..<end)
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw EngineError.badResponse
        }
        return object
    }
}

/// Typed view of an engine response.
struct EngineResponse {
    let ok: Bool
    let error: String?
    let errorCode: String?
    let chatID: String?
    let chatTitle: String?
    let method: String?
    let matchedLine: String?
    let suggestion: String?
    let mode: String
    let lastMessageID: String?
    let notes: [String]
    /// The same warnings in a few characters each, for the ghost text.
    let shortNotes: [String]
    let timing: String
    /// The engine reused prefetched messages instead of fetching them now.
    let historyCached: Bool
    let candidates: [String]

    init(_ d: [String: Any]) {
        ok = (d["ok"] as? Bool) ?? false
        error = d["error"] as? String
        errorCode = d["error_code"] as? String
        let chat = d["chat"] as? [String: Any]
        chatID = chat?["id"] as? String
        chatTitle = chat?["title"] as? String
        method = d["method"] as? String
        matchedLine = d["matched_line"] as? String
        suggestion = d["suggestion"] as? String
        mode = (d["mode"] as? String) ?? "complete"
        lastMessageID = d["last_message_id"] as? String
        var n: [String] = []
        var short: [String] = []
        if (d["commits"] as? Bool) == true { n.append(L10n.tr("含承诺，发出前确认", "Contains a commitment; review before sending")); short.append(L10n.tr("含承诺", "Commitment")) }
        if (d["sensitive"] as? Bool) == true { n.append(L10n.tr("含链接、邮箱或长数字", "Contains a link, email address, or long number")); short.append(L10n.tr("含链接/号码", "Link/number")) }
        notes = n
        shortNotes = short
        let t = d["timing_ms"] as? [String: Any] ?? [:]
        historyCached = (t["history_cached"] as? NSNumber)?.intValue == 1
        timing = t.keys.filter { $0 != "history_cached" }.sorted().map { "\($0) \(t[$0] ?? "")ms" }
            .joined(separator: " · ") + (historyCached ? L10n.tr("（消息来自预取）", " (prefetched messages)") : "")
        candidates = (d["candidates"] as? [String]) ?? []
    }

    /// What to show the user when ok is false.
    var friendlyError: String {
        switch errorCode {
        case "not_resolved":
            return L10n.tr("没认出当前会话（识别到「\(matchedLine ?? "")」）", "Could not identify the current chat (recognized “\(matchedLine ?? "")”)")
        case "ambiguous":
            return L10n.tr("有多个同名会话，这次不建议：\(candidates.joined(separator: " / "))", "Skipped suggestion because multiple chats have the same name: \(candidates.joined(separator: " / "))")
        case "draft_conflict":
            return L10n.tr("输入框内容和另一个会话的草稿一样，会话可能认错了", "The input matches a draft in another chat. The current chat may have been identified incorrectly")
        case "adapter_error":
            return L10n.tr("读取消息失败：\(error ?? "")", "Could not read messages: \(error ?? "")")
        case "model_error", "model_bad_output":
            return L10n.tr("模型出错：\(error ?? "")", "Model error: \(error ?? "")")
        default:
            return error ?? L10n.tr("引擎出错", "Engine error")
        }
    }
}
