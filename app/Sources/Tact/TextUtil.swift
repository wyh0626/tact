import Foundation

enum TextUtil {
    /// Same idea as the engine's resolve.Normalize: case-, width-, space-,
    /// punctuation- and emoji-insensitive.
    static func normalize(_ s: String) -> String {
        let folded = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        var out = String.UnicodeScalarView()
        for scalar in folded.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }
            switch scalar.properties.generalCategory {
            case .format, .nonspacingMark, .enclosingMark, .control, .privateUse, .surrogate:
                continue
            default:
                break
            }
            if scalar.properties.isEmojiPresentation { continue }
            out.append(scalar)
        }
        return String(out)
    }

    /// What differs between two reads of the same chat, or nil when they
    /// agree. OCR can read unchanged punctuation, width or case differently
    /// ("，" then ","), so only characters, letters and digits count. The
    /// answer names kinds of characters, never the text, for the log.
    static func change(from old: (title: String, draft: String), to new: (title: String, draft: String)) -> String? {
        if let title = difference(old.title, new.title) { return "会话名和刚才读到的不同（\(title)）" }
        if let draft = difference(old.draft, new.draft) { return "草稿和刚才读到的不同（\(draft)）" }
        return nil
    }

    private static func difference(_ a: String, _ b: String) -> String? {
        let before = Array(normalize(a)), after = Array(normalize(b))
        guard before != after else { return nil }
        let at = zip(before, after).prefix { $0 == $1 }.count
        let kind = { (text: [Character]) -> String in
            guard at < text.count else { return "无" }
            let c = text[at]
            if c.unicodeScalars.contains(where: \.properties.isIdeographic) { return "汉字" }
            return c.isLetter ? "字母" : c.isNumber ? "数字" : "其他"
        }
        return "\(before.count) → \(after.count) 字，第 \(at + 1) 个字起：\(kind(before)) → \(kind(after))"
    }

    /// Whether the header OCR still shows the chat the suggestion was made for.
    static func headerMatches(lines: [OCRLine], title: String) -> Bool {
        let t = normalize(title)
        guard !t.isEmpty else { return false }
        for line in lines.prefix(4) {
            let cleaned = line.text.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            let l = normalize(cleaned)
            guard l.count >= 2 else { continue }
            if l == t || t.contains(l) || l.contains(t) { return true }
            // The engine found the chat by this header at a similarity of
            // 0.75 or more (resolve.Score), OCR misreads included; reading
            // it again must not hold it to a stricter standard.
            if Double(editDistance(l, t)) <= Double(max(l.count, t.count)) * 0.25 { return true }
        }
        return false
    }

    /// Character-level Levenshtein distance.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
