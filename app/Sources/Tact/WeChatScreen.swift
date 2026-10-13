import CoreGraphics
import Foundation
import Vision

/// A window capture's pixels, top row first, for finding a layout in it.
struct Pixels {
    struct Color: Equatable, Hashable {
        var r: Int
        var g: Int
        var b: Int

        func distance(to other: Color) -> Int {
            max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
        }

        /// How far from grey: text and backgrounds are near 0.
        var chroma: Int { max(r, g, b) - min(r, g, b) }
    }

    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        bytes = buffer
    }

    func color(_ x: Int, _ y: Int) -> Color {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return Color(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    /// The most common colour of a few points stacked around (x, y), so a
    /// stray glyph pixel does not decide it.
    func steadyColor(_ x: Int, _ y: Int) -> Color {
        let samples = (-2...2).map { color(x, y + $0 * 2) }
        return Dictionary(grouping: samples, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? color(x, y)
    }
}

/// Locates the chat and input in a WeChat window capture. The live assistant
/// sends positioned OCR text to the model, without parsing message bubbles.
/// The colour-based reader below is only used by the local inspector to
/// diagnose older layouts; its guesses are never sent by the live assistant.
enum WeChatScreen {
    static let bundleID = "com.tencent.xinWeChat"

    /// Rectangles are in pixels of the capture, top-left origin.
    struct Layout: Equatable {
        var chat: CGRect
        var header: CGRect
        var messages: CGRect
        var input: CGRect
        /// The input box above its controls: where typing shows.
        var typing: CGRect
        var background: Pixels.Color
    }

    /// Text found by OCR, in pixels of the capture.
    struct Line: Equatable {
        var text: String
        var box: CGRect
    }

    /// The chat as read: its title, the draft, and the message list's text
    /// with positions, for the model to tell senders and messages apart.
    struct Reading: Equatable {
        var title: String
        var isGroup: Bool
        var draft: String
        var rawLines: [TextBlock]
    }

    struct TextBlock: Equatable {
        var text: String
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var payload: [String: Any] {
            ["text": text, "x": x, "y": y, "width": width, "height": height]
        }
    }

    /// Two pixels this far apart in any channel are on different surfaces.
    static let edgeThreshold = 8
    /// The header holds the chat's name, from 21 to 38 points down.
    static let headerHeight: CGFloat = 50
    /// The input box's controls (emoji, files, voice, send) take its bottom
    /// row. OCR reads some of those icons as characters, so it never looks
    /// there for typing.
    static let controlsHeight: CGFloat = 56

    /// A run of neighbouring columns or rows that all qualified. A column
    /// qualifies when it differs from the one before it, so the region past
    /// a separator starts at `last`, and the one before it ends at `first`.
    struct Run: Equatable {
        var first: Int
        var last: Int
    }

    static func runs(_ positions: [Int]) -> [Run] {
        var result: [Run] = []
        for position in positions {
            if let last = result.last, position - last.last <= 3 {
                result[result.count - 1].last = position
            } else {
                result.append(Run(first: position, last: position))
            }
        }
        return result
    }

    /// Columns where the colour changes on almost every row: the borders
    /// between WeChat's sidebar, chat list, chat and info panel.
    static func columnSeparators(_ pixels: Pixels) -> [Run] {
        let rows = Array(stride(from: pixels.height * 15 / 100, to: pixels.height * 92 / 100, by: 2))
        guard !rows.isEmpty else { return [] }
        let needed = rows.count * 85 / 100
        let columns = (1..<pixels.width).filter { x in
            var count = 0
            for y in rows where pixels.color(x, y).distance(to: pixels.color(x - 1, y)) > edgeThreshold {
                count += 1
            }
            return count >= needed
        }
        return runs(columns)
    }

    /// Rows where the colour changes across almost all of the chat column:
    /// the lines under the header and above the input box.
    static func rowSeparators(_ pixels: Pixels, from minX: Int, to maxX: Int) -> [Run] {
        let columns = Array(stride(from: minX, to: maxX, by: 2))
        guard !columns.isEmpty else { return [] }
        let needed = columns.count * 90 / 100
        let rows = (1..<pixels.height).filter { y in
            var count = 0
            for x in columns where pixels.color(x, y).distance(to: pixels.color(x, y - 1)) > edgeThreshold {
                count += 1
            }
            return count >= needed
        }
        return runs(rows)
    }

    /// The chat column is the widest stretch between column separators.
    static func chatColumn(width: Int, separators: [Run]) -> (minX: Int, maxX: Int) {
        var bounds = [Run(first: 0, last: 0)] + separators + [Run(first: width, last: width)]
        bounds.sort { $0.first < $1.first }
        var best = (minX: 0, maxX: width)
        var widest = -1
        for (left, right) in zip(bounds, bounds.dropFirst()) where right.first - left.last > widest {
            widest = right.first - left.last
            best = (left.last, right.first)
        }
        return best
    }

    static func layout(_ pixels: Pixels, scale: CGFloat) -> Layout? {
        let pt = { (points: CGFloat) in Int(points * scale) }
        let header = pt(headerHeight)
        let boundaries = [Run(first: 0, last: 0)] + columnSeparators(pixels)
            + [Run(first: pixels.width, last: pixels.width)]
        // A narrow chat can be smaller than the conversation list. Require
        // an input divider in the candidate column, rather than taking the
        // widest column. Info panels tend to have extra section dividers.
        var candidates: [(minX: Int, maxX: Int, input: Run, sections: Int)] = []
        for (left, right) in zip(boundaries, boundaries.dropFirst()) {
            guard right.first - left.last > pt(160) else { continue }
            // Leave out the scroll bar, which is drawn only some of the time.
            let rows = rowSeparators(pixels, from: left.last + pt(4), to: right.first - pt(24))
            guard let input = rows.last(where: { $0.first >= pixels.height * 35 / 100 && $0.first <= pixels.height - pt(50) }),
                  input.first > header + pt(40) else { continue }
            let sections = rows.filter { $0.first > header + pt(40) && $0.first < input.first }.count
            candidates.append((left.last, right.first, input, sections))
        }
        guard let fewestSections = candidates.map(\.sections).min() else { return nil }
        let plausible = candidates.filter { $0.sections == fewestSections }
        // Do not send another column's conversation previews on a guess.
        guard plausible.count == 1, let column = plausible.first else { return nil }
        let input = column.input
        let width = CGFloat(column.maxX - column.minX)
        let messages = CGRect(x: CGFloat(column.minX), y: CGFloat(header),
                              width: width, height: CGFloat(input.first - header))
        return Layout(
            chat: CGRect(x: CGFloat(column.minX), y: 0, width: width, height: CGFloat(pixels.height)),
            header: CGRect(x: CGFloat(column.minX), y: 0, width: width, height: CGFloat(header)),
            messages: messages,
            input: CGRect(x: CGFloat(column.minX), y: CGFloat(input.last),
                          width: width, height: CGFloat(pixels.height - input.last)),
            typing: CGRect(x: CGFloat(column.minX), y: CGFloat(input.last),
                           width: width, height: CGFloat(max(pt(20), pixels.height - input.last - pt(controlsHeight)))),
            background: background(pixels, in: messages))
    }

    /// The list's own colour: the most common one on a grid over it.
    static func background(_ pixels: Pixels, in rect: CGRect) -> Pixels.Color {
        var counts: [Pixels.Color: Int] = [:]
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: 7) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: 7) {
                counts[pixels.color(x, y), default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key ?? pixels.color(Int(rect.midX), Int(rect.midY))
    }

    /// WeChat's caret: an upright bar of solid green, 2 pt wide and taller
    /// than the 14 pt text it follows. Typed text is grey, no stroke of it
    /// is that tall, and emoji are wider or not one colour. Nil while the
    /// caret blinks off.
    static func caret(_ pixels: Pixels, in typing: CGRect, scale: CGFloat) -> CGRect? {
        let tall = Int(15 * scale), thin = 3 * scale
        var bars: [CGRect] = []
        var bar: CGRect?
        for x in Int(typing.minX)..<Int(typing.maxX) {
            if let run = solidRun(pixels, x: x, from: Int(typing.minY), to: Int(typing.maxY)), run.count >= tall {
                let column = CGRect(x: CGFloat(x), y: CGFloat(run.lowerBound), width: 1, height: CGFloat(run.count))
                bar = bar.map { $0.union(column) } ?? column
            } else if let finished = bar {
                bars.append(finished)
                bar = nil
            }
        }
        if let finished = bar { bars.append(finished) }
        return bars.first { $0.width <= thin }
    }

    /// The longest stretch of column `x` in one strong colour.
    private static func solidRun(_ pixels: Pixels, x: Int, from top: Int, to bottom: Int) -> Range<Int>? {
        var longest: Range<Int>?
        var run: (start: Int, color: Pixels.Color)?
        for y in top...bottom {
            let color = y < bottom ? pixels.color(x, y) : nil
            if let current = run, let color, color.chroma >= 40, color.distance(to: current.color) <= 32 { continue }
            if let current = run, y - current.start > longest?.count ?? 0 { longest = current.start..<y }
            run = color.flatMap { $0.chroma >= 40 ? (y, $0) : nil }
        }
        return longest
    }

    // MARK: - Reading

    /// Only crop and locate text. Do not infer bubbles, colours or senders.
    /// Relative coordinates let a text model interpret the same layout at
    /// different window sizes and pixel scales.
    static func readForModel(_ lines: [Line], layout: Layout) -> Reading {
        let header = lines.filter { layout.header.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
        let (title, group) = title(from: header, in: layout.header)
        let area = layout.messages
        let blocks = lines.compactMap { line -> TextBlock? in
            guard area.contains(CGPoint(x: line.box.midX, y: line.box.midY)) else { return nil }
            let box = line.box.intersection(area)
            guard !box.isEmpty, box.width > 0, box.height > 0 else { return nil }
            return TextBlock(text: line.text, x: Double((box.minX - area.minX) / area.width),
                             y: Double((box.minY - area.minY) / area.height),
                             width: Double(box.width / area.width), height: Double(box.height / area.height))
        }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        return Reading(title: title, isGroup: group, draft: draft(from: lines, in: layout.typing), rawLines: blocks)
    }

    /// Pieces of one line of text that OCR returned separately (around an
    /// emoji, say), joined back.
    static func joinFragments(_ lines: [Line]) -> [Line] {
        var result: [Line] = []
        for line in lines.sorted(by: { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }) {
            if let index = result.indices.last(where: { sameRow(result[$0].box, line.box) }),
               line.box.minX - result[index].box.maxX < line.box.height * 1.5,
               line.box.minX >= result[index].box.minX {
                result[index] = Line(text: joined(result[index].text, line.text), box: result[index].box.union(line.box))
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > min(a.height, b.height) * 0.5
    }

    /// Lines of one message, joined: no space between Chinese characters,
    /// one between words.
    static func joined(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        let word = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber) }
        return word(last) && word(first) ? a + " " + b : a + b
    }

    /// The chat's name: the largest text in the header's left half (buttons
    /// sit on the right), with a group's member count, "(23)", taken off.
    static func title(from lines: [Line], in header: CGRect) -> (String, Bool) {
        let left = lines.filter { $0.box.minX < header.midX }
        guard let line = (left.isEmpty ? lines : left).max(by: { $0.box.height < $1.box.height }) else { return ("", false) }
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard let range = text.range(of: #"\s*[(（]\d+[)）]$"#, options: .regularExpression) else { return (text, false) }
        return (String(text[..<range.lowerBound]), true)
    }

    /// The text in `rect` of a capture, positioned in the capture's pixels.
    static func recognize(_ image: CGImage, in rect: CGRect) throws -> [Line] {
        let crop = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isEmpty, let part = image.cropping(to: crop) else { return [] }
        return try recognize(part, at: crop.origin)
    }

    /// The typing area's text, read with the caret painted out in the box's
    /// own colour, and where the caret was. A lit caret reads as a "|"
    /// after the draft, so two captures of the same draft would differ
    /// whenever it blinks; every read goes through the same redraw so lit
    /// and unlit captures give OCR the same pixels.
    static func recognizeTyping(_ image: CGImage, pixels: Pixels, layout: Layout,
                                scale: CGFloat) throws -> (lines: [Line], caret: CGRect?) {
        let crop = layout.typing.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !crop.isEmpty, let part = image.cropping(to: crop),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: part.width, height: part.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return ([], nil) }
        context.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        let found = caret(pixels, in: crop, scale: scale)
        if let found {
            let color = background(pixels, in: crop)
            context.setFillColor(CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                         blue: CGFloat(color.b) / 255, alpha: 1))
            // The bar's ends are blended into the box and fall outside its
            // solid run; above and below it there is only the box.
            let cover = found.insetBy(dx: 0, dy: -1)
            context.fill(CGRect(x: cover.minX - crop.minX, y: crop.maxY - cover.maxY, width: cover.width, height: cover.height))
        }
        guard let redrawn = context.makeImage() else { return ([], found) }
        return (try recognize(redrawn, at: crop.origin), found)
    }

    /// The text in `part`, a piece cut from a capture at `origin`.
    private static func recognize(_ part: CGImage, at origin: CGPoint) throws -> [Line] {
        let width = CGFloat(part.width), height = CGFloat(part.height)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: part, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return Line(text: text, box: CGRect(x: origin.x + box.minX * width, y: origin.y + (1 - box.maxY) * height,
                                                width: box.width * width, height: box.height * height))
        }
    }

    private static func isInputPlaceholder(_ text: String) -> Bool {
        // Vision can merge the caret, voice-input hint and send control into
        // one observation. Match the entire UI hint, never words inside a draft.
        let compact = String(text.filter { !$0.isWhitespace })
        return compact.range(of: #"^[|｜丨]?(输入消息[.。…⋯]*|按住鼠标(语音输入文字|语音输入|说话))[①②③④⑤⑥⑦⑧⑨⑩○◯◎|｜丨]*(发送|Send)?([(（][sS][)）])?$"#,
                             options: .regularExpression) != nil
    }

    private static func isCaret(_ line: Line) -> Bool {
        ["|", "｜", "丨"].contains(line.text.trimmingCharacters(in: .whitespacesAndNewlines))
            && line.box.height > line.box.width * 3
    }

    private static func inputTextLines(_ lines: [Line], in input: CGRect) -> [Line] {
        let text = lines.filter { line in
            guard input.contains(CGPoint(x: line.box.midX, y: line.box.midY)) else { return false }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || isCaret(line) { return false }
            // Only known controls at the lower right are excluded. A long
            // draft may continue through the right half of the input box.
            let lowerRight = line.box.minX > input.minX + input.width * 0.6 && line.box.midY > input.midY
            return !(lowerRight && text.range(of: #"^[①②③④⑤⑥⑦⑧⑨⑩○◯◎\s]*(发送|Send)(\s*[(（].*[)）])?$"#,
                                              options: .regularExpression) != nil)
        }
        return joinFragments(text)
    }

    /// Typed text only; an empty composer remains empty when its caret or
    /// placeholder appears and disappears as focus changes.
    /// The lines of typed text, without the hint.
    static func draftLines(from lines: [Line], in input: CGRect) -> [Line] {
        inputTextLines(lines, in: input).filter { !isInputPlaceholder($0.text) }
    }

    /// Whether the draft may run past the box: its first line sits at the
    /// very top (scrolled), or its last line reaches the bottom of the
    /// typing area, where a further line would be cut off.
    static func draftMayBeClipped(_ lines: [Line], in typing: CGRect) -> Bool {
        guard let first = lines.min(by: { $0.box.minY < $1.box.minY }),
              let last = lines.max(by: { $0.box.maxY < $1.box.maxY }) else { return false }
        let height = lines.map(\.box.height).max() ?? 0
        return first.box.minY - typing.minY < height * 0.5 || typing.maxY - last.box.maxY < height * 1.2
    }

    static func draft(from lines: [Line], in input: CGRect) -> String {
        inputTextLines(lines, in: input).filter { !isInputPlaceholder($0.text) }
            .map(\.text).reduce("") { joined($0, $1) }
    }

    /// Where the empty input box shows its hint ("按住鼠标 语音输入文字"), for
    /// ghost text to cover; nil once something is typed.
    static func placeholder(from lines: [Line], in input: CGRect) -> CGRect? {
        let text = inputTextLines(lines, in: input)
        guard !text.contains(where: { !isInputPlaceholder($0.text) }) else { return nil }
        return text.first { isInputPlaceholder($0.text) }?.box
    }

    /// The typing row, rather than the centre of the whole composer (which
    /// includes the toolbar). All geometry stays in capture pixels.
    static func inputAnchor(from lines: [Line], in input: CGRect, scale: CGFloat) -> CGRect {
        if let caret = lines.first(where: {
            input.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) && isCaret($0)
        }) { return caret.box }
        let text = inputTextLines(lines, in: input)
        if let last = text.last(where: { !isInputPlaceholder($0.text) }) {
            return CGRect(x: last.box.maxX, y: last.box.minY, width: scale, height: last.box.height)
        }
        if let hint = text.first(where: { isInputPlaceholder($0.text) }) {
            return CGRect(x: hint.box.minX, y: hint.box.minY, width: scale, height: hint.box.height)
        }
        let height = min(18 * scale, input.height)
        return CGRect(x: min(input.minX + 16 * scale, input.maxX - scale),
                      y: min(input.minY + 14 * scale, input.maxY - height), width: scale, height: height)
    }
}
