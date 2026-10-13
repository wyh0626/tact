import Darwin
import Foundation

/// Local-only engine double: the UI must get a chance to release its reply.
final class WaitingPingServer: @unchecked Sendable {
    let path = "/tmp/gr-ping-\(UUID().uuidString).sock"
    let finished: Task<Bool, Never>
    private let listener: Int32
    private let gate = DispatchSemaphore(value: 0)

    init() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            Darwin.close(fd)
            unlink(path)
            throw POSIXError(.EIO)
        }
        listener = fd
        let gate = self.gate
        finished = Task.detached { Self.reply(on: fd, after: gate) }
    }

    private static func reply(on fd: Int32, after gate: DispatchSemaphore) -> Bool {
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 3000) > 0 else { return false }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return false }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 1024)
        guard read(client, &buffer, buffer.count) > 0,
              gate.wait(timeout: .now() + 3) == .success else { return false }
        let response = Array("{\"ok\":true}\n".utf8)
        return response.withUnsafeBytes { write(client, $0.baseAddress, $0.count) == $0.count }
    }

    func releaseResponse() { gate.signal() }

    deinit {
        gate.signal()
        Darwin.close(listener)
        unlink(path)
    }
}
