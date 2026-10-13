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

    /// Whether the header OCR still shows the chat the suggestion was made for.
    static func headerMatches(lines: [OCRLine], title: String) -> Bool {
        let t = normalize(title)
        guard !t.isEmpty else { return false }
        for line in lines.prefix(4) {
            let cleaned = line.text.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            let l = normalize(cleaned)
            guard l.count >= 2 else { continue }
            if l == t || t.contains(l) || l.contains(t) { return true }
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
