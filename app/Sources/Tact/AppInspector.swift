import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// `Tact --inspect-app <bundle id> <report.json>` describes what a chat app
/// shows Tact, for deciding how to connect it: its accessibility tree, as it
/// is in the background and again once the app is in front (WeChat builds its
/// views for accessibility only then), and what OCR reads in its main window.
/// The report holds shapes only (roles, identifiers, counts, lengths,
/// positions), never the text, so it is safe to share. Run it as the app
/// (`open -n -W -a Tact.app --args ...`) so its permissions apply.
enum AppInspector {
    struct Report: Encodable {
        var bundleID: String
        var version: String?
        var running = false
        var accessibilityTrusted = AXIsProcessTrusted()
        var screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        var accessibilityInBackground: Tree?
        var frontmost: Bool?
        var accessibility: Tree?
        /// What sits under points across the main window; a hit test reaches
        /// elements some interfaces leave out of their children.
        var hitTests: [Hit] = []
        var accessibilityAfterHitTests: Tree?
        /// With VoiceOver's switch on, which some interfaces wait for.
        var accessibilityEnhanced: Tree?
        var ocr: OCRShape?
        var wechat: WeChatShape?
        var layout: LayoutShape?
        var telegram: TelegramShape?
        var problems: [String] = []
    }

    /// Any chat window's layout as separators and text positions, in
    /// points, for working out how to read an app Tact has no rules for yet.
    struct LayoutShape: Encodable {
        var columnSeparators: [Int] = []
        /// The widest stretch between column separators: [left, width].
        var column: [Int] = []
        /// Rows where the colour changes across that column: [top, the
        /// brightness above, the brightness below].
        var rowSeparators: [[Int]] = []
        /// Per line of text in the column: top, height, left gap, right gap,
        /// brightness just left of it, just right of it.
        var lines: [[Int]] = []
    }

    /// How Tact reads Telegram's window (see TelegramScreen), in points.
    struct TelegramShape: Encodable {
        var found = false
        var headerHeight: Int?
        var composer: [Int]?
        var headerLines: [[Int]] = []
        var titleLength = 0
        /// Per line in the typing area: left gap, width, contrast with the
        /// panel (typed text stands out by more than TelegramScreen.typedContrast).
        var typingLines: [[Int]] = []
        var draftLength = 0
    }

    /// How Tact reads WeChat's window (see WeChatScreen), in points.
    struct WeChatShape: Encodable {
        var columnSeparators: [Int] = []
        var rowSeparators: [Int] = []
        var chat: [Int]?
        var headerHeight: Int?
        var messages: [Int]?
        var inputHeight: Int?
        var background: [Int]?
        var titleLength = 0
        var isGroup = false
        var draftLength = 0
        var rawTextBlocks = 0
        /// Per line: top, height, left gap, right gap, colour left of it, colour right of it.
        var lineSamples: [[Int]] = []
    }

    struct Tree: Encodable {
        var windows = 0
        var nodes = 0
        var deepest = 0
        var roles: [String: Int] = [:]
        var identifiers: [String: Int] = [:]
        /// Elements carrying text, by where they sit across the main window.
        var textElements = 0
        var textLeft = 0
        var textCenter = 0
        var textRight = 0
        var longestText = 0
        var focusedRole: String?
        var focusedIdentifier: String?
        var messages: Messages?
        var input: Input?
        /// Every element, for trees small enough to read whole.
        var outline: [Node]?
    }

    struct Node: Encodable {
        var depth: Int
        var role: String
        var subrole: String?
        var identifier: String?
        var children: Int
        var size: [Int]?
        var attributes: [String]
    }

    struct Hit: Encodable {
        /// Where across and down the main window, as fractions.
        var at: [Double]
        var role: String?
        var identifier: String?
        var ancestors = 0
        var children = 0
    }

    /// WeChat's message list (`chat_message_list`), and whether its bubbles
    /// show, by where their parts sit, who sent each one.
    struct Messages: Encodable {
        var rows = 0
        var bubbles = 0
        var withText = 0
        var averageLength = 0.0
        /// Bubbles drawn against the left edge (from others), the right edge
        /// (mine), or neither.
        var left = 0
        var right = 0
        var unclear = 0
    }

    /// WeChat's compose box (`chat_input_field`).
    struct Input: Encodable {
        var role: String?
        var valueLength: Int?
        var valueSettable = false
        var focused = false
    }

    struct OCRShape: Encodable {
        var windowSize: [Int]
        var lines = 0
        /// Lines whose centre sits in the left, middle or right third of the
        /// window: messages from others, timestamps, and my own messages in
        /// most chat apps.
        var left = 0
        var middle = 0
        var right = 0
        var averageLength = 0.0
        var samples: [[String: Double]] = []
    }

    static func run(bundleID: String, output: String) -> Bool {
        // Screen capture needs the process's window server connection, which
        // the application object sets up; the app proper has one already.
        _ = NSApplication.shared
        var report = Report(bundleID: bundleID)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            report = await inspect(report)
            semaphore.signal()
        }
        semaphore.wait()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: output))
            return true
        } catch {
            FileHandle.standardError.write(Data("写不了报告：\(error.localizedDescription)\n".utf8))
            return false
        }
    }

    private static func inspect(_ start: Report) async -> Report {
        var report = start
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: report.bundleID).first else {
            report.problems.append("应用没有在运行")
            return report
        }
        report.running = true
        report.version = app.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if report.accessibilityTrusted {
            report.accessibilityInBackground = tree(of: root)
            if attribute(root, kAXFrontmostAttribute) as? Bool != true {
                AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                app.activate(options: [])
                // Coming to the front, WeChat rebuilds its views; read too
                // early and rows are missing.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            report.frontmost = attribute(root, kAXFrontmostAttribute) as? Bool
            report.accessibility = tree(of: root)
            report.hitTests = hitTests(in: root)
            report.accessibilityAfterHitTests = tree(of: root)
            let enhanced = "AXEnhancedUserInterface" as CFString
            let before = attribute(root, enhanced as String) as? Bool ?? false
            AXUIElementSetAttributeValue(root, enhanced, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            report.accessibilityEnhanced = tree(of: root)
            AXUIElementSetAttributeValue(root, enhanced, before ? kCFBooleanTrue : kCFBooleanFalse)
        } else {
            report.problems.append("没有辅助功能权限")
        }
        if report.screenRecordingAllowed {
            do {
                let (image, size) = try await capture(pid: app.processIdentifier)
                report.ocr = try ocrShape(image, windowSize: size)
                report.layout = try layoutShape(image, scale: CGFloat(image.width) / max(1, size.width))
                if report.bundleID == TelegramScreen.bundleID {
                    report.telegram = try telegramShape(image, scale: CGFloat(image.width) / max(1, size.width))
                }
                if report.bundleID == WeChatScreen.bundleID {
                    report.wechat = try weChatShape(image, scale: CGFloat(image.width) / max(1, size.width))
                }
            } catch {
                report.problems.append("截图识别失败：\(error.localizedDescription)")
            }
        } else {
            report.problems.append("没有屏幕录制权限")
        }
        return report
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// An identifier as the report may show it: a chat's own name is cut
    /// from `session_item_<name>`, and anything else that is not a plain
    /// lowercase name (account ids, names) is left out.
    static func identifierShape(_ identifier: String) -> String {
        if identifier.hasPrefix("session_item_") { return "session_item_*" }
        let plain = identifier.count <= 48 && identifier.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
        return plain ? identifier : "(other)"
    }

    /// Which edge a bubble's drawn parts sit against, from the gaps they
    /// leave to the list's edges.
    enum Side: Equatable { case left, right, unclear }

    static func side(of parts: [CGRect], in list: CGRect) -> Side {
        let drawn = parts.filter { $0.width > 0 && $0.width < list.width * 0.8 }
        guard let first = drawn.first else { return .unclear }
        let union = drawn.dropFirst().reduce(first) { $0.union($1) }
        let leftGap = union.minX - list.minX
        let rightGap = list.maxX - union.maxX
        guard abs(leftGap - rightGap) >= 10 else { return .unclear }
        return leftGap < rightGap ? .left : .right
    }

    private static func longestText(of element: AXUIElement) -> String {
        [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { attribute(element, $0) as? String }.max { $0.count < $1.count } ?? ""
    }

    private static func node(_ element: AXUIElement, depth: Int) -> Node {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        return Node(depth: depth,
                    role: attribute(element, kAXRoleAttribute) as? String ?? "?",
                    subrole: attribute(element, kAXSubroleAttribute) as? String,
                    identifier: (attribute(element, kAXIdentifierAttribute) as? String).map(identifierShape),
                    children: ((attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).count,
                    size: frame(of: element).map { [Int($0.width), Int($0.height)] },
                    attributes: ((names as? [String]) ?? []).sorted())
    }

    private static func hitTests(in root: AXUIElement) -> [Hit] {
        let windows = (attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        guard let main = windows.compactMap({ frame(of: $0) }).max(by: { $0.width * $0.height < $1.width * $1.height }) else { return [] }
        var hits: [Hit] = []
        for down in [0.3, 0.6, 0.9] {
            for across in [0.2, 0.45, 0.75] {
                var hit = Hit(at: [across, down])
                var found: AXUIElement?
                let point = CGPoint(x: main.minX + main.width * across, y: main.minY + main.height * down)
                if AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &found) == .success, let found {
                    hit.role = attribute(found, kAXRoleAttribute) as? String
                    hit.identifier = (attribute(found, kAXIdentifierAttribute) as? String).map(identifierShape)
                    hit.children = ((attribute(found, kAXChildrenAttribute) as? [AXUIElement]) ?? []).count
                    var parent = attribute(found, kAXParentAttribute)
                    while let element = parent, hit.ancestors < 60 {
                        hit.ancestors += 1
                        parent = attribute(element as! AXUIElement, kAXParentAttribute)
                    }
                }
                hits.append(hit)
            }
        }
        return hits
    }

    private static func tree(of root: AXUIElement) -> Tree {
        var tree = Tree()
        let windows = (attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        tree.windows = windows.count
        let main = windows.compactMap { frame(of: $0) }.max { $0.width * $0.height < $1.width * $1.height }
        let focused = attribute(root, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        if let focused {
            tree.focusedRole = attribute(focused, kAXRoleAttribute) as? String
            tree.focusedIdentifier = (attribute(focused, kAXIdentifierAttribute) as? String).map(identifierShape)
        }
        var messageText = 0
        var nodes: [Node] = []
        func walk(_ element: AXUIElement, depth: Int, list: CGRect?) {
            guard tree.nodes < 20_000, depth < 60 else { return }
            tree.nodes += 1
            nodes.append(node(element, depth: depth))
            tree.deepest = max(tree.deepest, depth)
            let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
            tree.roles[role, default: 0] += 1
            let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? ""
            if !identifier.isEmpty { tree.identifiers[identifierShape(identifier), default: 0] += 1 }
            let text = longestText(of: element)
            if !text.isEmpty {
                tree.textElements += 1
                tree.longestText = max(tree.longestText, text.count)
                if let main, let box = frame(of: element) {
                    switch (box.midX - main.minX) / max(1, main.width) {
                    case ..<0.4: tree.textLeft += 1
                    case 0.6...: tree.textRight += 1
                    default: tree.textCenter += 1
                    }
                }
            }
            let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            var list = list
            switch identifier {
            case "chat_message_list":
                list = frame(of: element)
                tree.messages = tree.messages ?? Messages()
                tree.messages?.rows += children.count
            case "chat_bubble_item_view":
                var parts: [CGRect] = []
                var longest = 0
                func collect(_ part: AXUIElement, depth: Int) {
                    guard depth < 12 else { return }
                    if depth > 0, let box = frame(of: part) { parts.append(box) }
                    longest = max(longest, longestText(of: part).count)
                    for child in (attribute(part, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { collect(child, depth: depth + 1) }
                }
                collect(element, depth: 0)
                tree.messages = tree.messages ?? Messages()
                tree.messages?.bubbles += 1
                if longest > 0 {
                    tree.messages?.withText += 1
                    messageText += longest
                }
                switch list.map({ side(of: parts, in: $0) }) ?? .unclear {
                case .left: tree.messages?.left += 1
                case .right: tree.messages?.right += 1
                case .unclear: tree.messages?.unclear += 1
                }
            case "chat_input_field":
                var input = Input(role: role)
                input.valueLength = (attribute(element, kAXValueAttribute) as? String)?.count
                var settable = DarwinBoolean(false)
                input.valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                    && settable.boolValue
                input.focused = focused.map { CFEqual($0, element) } ?? false
                tree.input = input
            default:
                break
            }
            for child in children {
                walk(child, depth: depth + 1, list: list)
            }
        }
        windows.forEach { walk($0, depth: 0, list: nil) }
        if nodes.count <= 40 { tree.outline = nodes }
        if let withText = tree.messages?.withText, withText > 0 {
            tree.messages?.averageLength = Double(messageText) / Double(withText)
        }
        return tree
    }

    private static func capture(pid: pid_t) async throws -> (CGImage, CGSize) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.isOnScreen })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw HeaderError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration), window.frame.size)
    }

    private static func ocrShape(_ image: CGImage, windowSize: CGSize) throws -> OCRShape {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        var shape = OCRShape(windowSize: [Int(windowSize.width), Int(windowSize.height)])
        var total = 0
        for observation in request.results ?? [] {
            guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let box = observation.boundingBox
            shape.lines += 1
            total += text.count
            switch box.midX {
            case ..<0.4: shape.left += 1
            case 0.6...: shape.right += 1
            default: shape.middle += 1
            }
            if shape.samples.count < 40 {
                shape.samples.append(["x": box.minX, "y": 1 - box.maxY, "width": box.width,
                                      "height": box.height, "length": Double(text.count)])
            }
        }
        shape.averageLength = shape.lines > 0 ? Double(total) / Double(shape.lines) : 0
        return shape
    }

    private static func layoutShape(_ image: CGImage, scale: CGFloat) throws -> LayoutShape {
        var shape = LayoutShape()
        guard let pixels = Pixels(image) else { return shape }
        let points = { (pixels: CGFloat) in Int((pixels / scale).rounded()) }
        let luma = { (c: Pixels.Color) in (c.r + c.g + c.b) / 3 }
        let columns = WeChatScreen.columnSeparators(pixels)
        shape.columnSeparators = columns.map { points(CGFloat($0.first)) }
        let column = WeChatScreen.chatColumn(width: pixels.width, separators: columns)
        shape.column = [points(CGFloat(column.minX)), points(CGFloat(column.maxX - column.minX))]
        let midX = (column.minX + column.maxX) / 2
        shape.rowSeparators = WeChatScreen.rowSeparators(pixels, from: column.minX + Int(4 * scale), to: column.maxX - Int(24 * scale))
            .map { [points(CGFloat($0.first)), luma(pixels.color(midX, $0.first - 2)), luma(pixels.color(midX, $0.last + 1))] }
        let area = CGRect(x: column.minX, y: 0, width: column.maxX - column.minX, height: pixels.height)
        for line in try WeChatScreen.recognize(image, in: area).sorted(by: { $0.box.minY < $1.box.minY }).prefix(80) {
            let y = Int(line.box.midY)
            shape.lines.append([points(line.box.minY), points(line.box.height),
                                points(line.box.minX - area.minX), points(area.maxX - line.box.maxX),
                                luma(pixels.steadyColor(Int(line.box.minX - 3 * scale), y)),
                                luma(pixels.steadyColor(Int(line.box.maxX + 3 * scale), y))])
        }
        return shape
    }

    private static func telegramShape(_ image: CGImage, scale: CGFloat) throws -> TelegramShape {
        var shape = TelegramShape()
        let points = { (pixels: CGFloat) in Int((pixels / scale).rounded()) }
        guard let pixels = Pixels(image), let layout = TelegramScreen.layout(pixels, scale: scale) else { return shape }
        shape.found = true
        shape.headerHeight = points(layout.header.height)
        shape.composer = [points(layout.composer.minY), points(layout.composer.height)]
        let header = try WeChatScreen.recognize(image, in: layout.header)
        shape.headerLines = header.map { [points($0.box.minY), points($0.box.height), points($0.box.minX - layout.chat.minX)] }
        shape.titleLength = TelegramScreen.title(header).count
        let typing = try WeChatScreen.recognize(image, in: layout.typing)
        shape.typingLines = typing.map {
            [points($0.box.minX - layout.typing.minX), points($0.box.width),
             TelegramScreen.contrast(of: $0, on: layout.background, in: pixels)]
        }
        shape.draftLength = TelegramScreen.draft(TelegramScreen.split(typing, in: layout, pixels: pixels).typed).count
        return shape
    }

    private static func weChatShape(_ image: CGImage, scale: CGFloat) throws -> WeChatShape {
        var shape = WeChatShape()
        guard let pixels = Pixels(image) else { return shape }
        let points = { (pixels: CGFloat) in Int((pixels / scale).rounded()) }
        let columns = WeChatScreen.columnSeparators(pixels)
        shape.columnSeparators = columns.map { points(CGFloat($0.first)) }
        let column = WeChatScreen.chatColumn(width: pixels.width, separators: columns)
        shape.chat = [points(CGFloat(column.minX)), points(CGFloat(column.maxX - column.minX))]
        shape.rowSeparators = WeChatScreen.rowSeparators(pixels, from: column.minX + Int(4 * scale), to: column.maxX - Int(24 * scale))
            .map { points(CGFloat($0.first)) }
        guard let layout = WeChatScreen.layout(pixels, scale: scale) else { return shape }
        shape.chat = [points(layout.chat.minX), points(layout.chat.width)]
        shape.headerHeight = points(layout.header.height)
        shape.messages = [points(layout.messages.minY), points(layout.messages.height)]
        shape.inputHeight = points(layout.input.height)
        shape.background = [layout.background.r, layout.background.g, layout.background.b]
        let lines = try WeChatScreen.recognize(image, in: layout.chat)
        let inside = { (rect: CGRect) in lines.filter { rect.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) } }
        for line in WeChatScreen.joinFragments(inside(layout.messages)) {
            let y = Int(line.box.midY)
            let left = pixels.steadyColor(Int(line.box.minX - 3 * scale), y)
            let right = pixels.steadyColor(Int(line.box.maxX + 3 * scale), y)
            shape.lineSamples.append([points(line.box.minY), points(line.box.height),
                                      points(line.box.minX - layout.messages.minX), points(layout.messages.maxX - line.box.maxX),
                                      left.r, left.g, left.b, right.r, right.g, right.b])
        }
        let reading = WeChatScreen.readForModel(lines, layout: layout)
        shape.rawTextBlocks = reading.rawLines.count
        shape.titleLength = reading.title.count
        shape.isGroup = reading.isGroup
        shape.draftLength = reading.draft.count
        return shape
    }
}
