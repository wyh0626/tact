import AppKit
import ScreenCaptureKit
import Vision

struct OCRLine {
    let text: String
    let height: Double
}

enum HeaderError: LocalizedError {
    case windowNotFound
    case cropFailed
    /// macOS also stops honouring the grant for a running Tact whose app
    /// was replaced on disk, by an update say, until it is opened again.
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .windowNotFound: return "屏幕录制里找不到当前聊天窗口"
        case .cropFailed: return "顶部栏区域超出了窗口范围"
        case .screenRecordingDenied:
            return "没有屏幕录制权限：到「系统设置 → 隐私与安全性 → 屏幕录制」打开 Tact。刚更新过 Tact 的话，退出后重新打开"
        }
    }
}

/// Captures the chat's header bar (where the client shows the chat name) and
/// reads it with on-device OCR. Images stay in memory unless debug saving
/// is turned on.
@MainActor
final class HeaderReader {
    var config: AppConfig
    private var cachedWindow: SCWindow?

    init(config: AppConfig) {
        self.config = config
    }

    /// The header strip above the message list, derived from the input box
    /// (left edge of the chat area) and the window (top edge).
    func headerRect(input: CGRect, window: CGRect) -> CGRect {
        let left = max(window.minX, input.minX - config.headerLeftPadding)
        let right = window.maxX - 8
        let y0 = window.minY + config.headerTopOffset
        return CGRect(x: left, y: y0, width: max(20, right - left), height: config.headerHeight)
    }

    /// The whole chat window, so one capture serves both the header crop
    /// and the input background sample.
    func captureWindow(pid: pid_t, windowFrame: CGRect) async throws -> CGImage {
        do {
            let window = try await findWindow(pid: pid, frame: windowFrame)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = max(1, Int(windowFrame.width * scale))
            configuration.height = max(1, Int(windowFrame.height * scale))
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw Self.explained(error)
        }
    }

    /// ScreenCaptureKit's refusal, in words a user can act on.
    nonisolated static func explained(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.Code.userDeclined.rawValue else { return error }
        return HeaderError.screenRecordingDenied
    }

    func capture(pid: pid_t, windowFrame: CGRect, rect: CGRect) async throws -> CGImage {
        let image = try await captureWindow(pid: pid, windowFrame: windowFrame)
        guard let cropped = Self.crop(image, windowFrame: windowFrame, to: rect) else { throw HeaderError.cropFailed }
        return cropped
    }

    /// Cuts `rect` (accessibility coordinates) out of a window capture.
    nonisolated static func crop(_ image: CGImage, windowFrame: CGRect, to rect: CGRect) -> CGImage? {
        let sx = CGFloat(image.width) / windowFrame.width
        let sy = CGFloat(image.height) / windowFrame.height
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let crop = CGRect(
            x: (rect.minX - windowFrame.minX) * sx,
            y: (rect.minY - windowFrame.minY) * sy,
            width: rect.width * sx,
            height: rect.height * sy
        ).integral.intersection(bounds)
        guard !crop.isEmpty else { return nil }
        return image.cropping(to: crop)
    }

    /// The colour of one point (accessibility coordinates) of a window capture.
    nonisolated static func color(in image: CGImage, windowFrame: CGRect, at point: CGPoint) -> NSColor? {
        let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
        guard let pixel = crop(image, windowFrame: windowFrame, to: rect),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return NSColor(srgbRed: CGFloat(rgba[0]) / 255, green: CGFloat(rgba[1]) / 255,
                       blue: CGFloat(rgba[2]) / 255, alpha: 1)
    }

    private func findWindow(pid: pid_t, frame: CGRect) async throws -> SCWindow {
        if let w = cachedWindow, w.owningApplication?.processID == pid, Self.distance(w.frame, frame) < 4 {
            return w
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let best = candidates.min(by: { Self.distance($0.frame, frame) < Self.distance($1.frame, frame) }) else {
            throw HeaderError.windowNotFound
        }
        cachedWindow = best
        return best
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// A cheap fingerprint of the header: downscaled to 64×16 grey and
    /// quantized, so it changes when the chat changes but not on every
    /// anti-aliasing difference.
    nonisolated static func fingerprint(_ image: CGImage) -> UInt64 {
        let w = 64, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for p in pixels {
            hash ^= UInt64(p >> 4)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The first recognition loads Vision's model and takes seconds; doing it
    /// once at launch keeps that off the first trigger.
    nonisolated static func warmUp() {
        let width = 240, height = 48
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "预热 Warm up", attributes: [.font: NSFont.systemFont(ofSize: 22)])
            .draw(at: NSPoint(x: 8, y: 10))
        NSGraphicsContext.current = previous
        if let image = ctx.makeImage() { _ = try? recognize(image) }
    }

    /// Recognized lines, tallest (most prominent) first.
    nonisolated static func recognize(_ image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        let lines: [OCRLine] = observations.compactMap { obs in
            guard let text = obs.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return OCRLine(text: text, height: Double(obs.boundingBox.height) * Double(image.height))
        }
        return lines.sorted { $0.height > $1.height }
    }

    nonisolated static func savePNG(_ image: CGImage, to path: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
