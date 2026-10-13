// Package resolve maps the text OCR read from a chat's header bar to one chat
// in the adapter's chat list. It refuses to guess: when more than one chat
// matches equally well, the caller gets an AmbiguousError.
package resolve

import (
	"errors"
	"fmt"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/wyh0626/tact/engine/internal/adapter"
)

// Line is one line of OCR output. Height is the line's height in pixels and
// is used to try the most prominent line (the chat name) first.
type Line struct {
	Text   string  `json:"text"`
	Height float64 `json:"height"`
}

type Result struct {
	Chat   adapter.Chat
	Line   string
	Method string
	Score  float64
}

var ErrNotFound = errors.New("顶部栏文字没有匹配到任何会话")

type AmbiguousError struct {
	Line   string
	Titles []string
}

func (e *AmbiguousError) Error() string {
	return fmt.Sprintf("「%s」同时匹配到 %d 个会话：%s", e.Line, len(e.Titles), strings.Join(e.Titles, " / "))
}

// statusHints mark the secondary header line ("最近曾上线", "12 位成员", ...).
// Only lines after the first are skipped for containing them, because a chat
// title itself may contain such a word.
var statusHints = []string{
	"最近曾上线", "最近上线", "在线", "上线", "正在输入", "正在", "位成员", "成员", "订阅",
	"last seen", "online", "typing", "members", "subscribers", "recently",
}

func isStatusLine(s string) bool {
	l := strings.ToLower(s)
	for _, h := range statusHints {
		if strings.Contains(l, h) {
			return true
		}
	}
	return false
}

const maxLines = 4

// Resolve picks the chat whose title best matches one of the header lines.
func Resolve(lines []Line, chats []adapter.Chat) (Result, error) {
	sorted := append([]Line(nil), lines...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Height > sorted[j].Height })
	if len(sorted) > maxLines {
		sorted = sorted[:maxLines]
	}
	chats = dedupe(chats)

	var (
		bestScore  float64
		bestLine   string
		bestMethod string
		bestChats  []adapter.Chat
	)
	for i, l := range sorted {
		text := strings.TrimSpace(l.Text)
		if text == "" || (i > 0 && isStatusLine(text)) {
			continue
		}
		var top float64
		var method string
		var matches []adapter.Chat
		for _, c := range chats {
			s, m := Score(text, c.Title)
			switch {
			case s == 0:
			case s > top:
				top, method, matches = s, m, []adapter.Chat{c}
			case s == top:
				matches = append(matches, c)
			}
		}
		if top > bestScore {
			bestScore, bestLine, bestMethod, bestChats = top, text, method, matches
		}
	}
	if bestScore == 0 {
		return Result{}, ErrNotFound
	}
	if len(bestChats) > 1 {
		titles := make([]string, 0, len(bestChats))
		for _, c := range bestChats {
			titles = append(titles, c.Title)
		}
		return Result{}, &AmbiguousError{Line: bestLine, Titles: titles}
	}
	return Result{Chat: bestChats[0], Line: bestLine, Method: bestMethod, Score: bestScore}, nil
}

// Headline returns the line most likely to be the chat title, for error
// messages: the tallest one that is not an icon read as a letter (such as a
// search glyph read as "Q") or a status line. It falls back to the tallest.
func Headline(lines []Line) string {
	sorted := append([]Line(nil), lines...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Height > sorted[j].Height })
	for _, l := range sorted {
		text := strings.TrimSpace(l.Text)
		if utf8.RuneCountInString(Normalize(text)) >= 2 && !isStatusLine(text) {
			return text
		}
	}
	if len(sorted) > 0 {
		return strings.TrimSpace(sorted[0].Text)
	}
	return ""
}

// Score rates how well an OCR line matches a chat title, 0 meaning no match.
func Score(line, title string) (float64, string) {
	line, title = strings.TrimSpace(line), strings.TrimSpace(title)
	if line == "" || title == "" {
		return 0, ""
	}
	if line == title {
		return 100, "exact"
	}
	nl, nt := Normalize(line), Normalize(title)
	if nl == "" || nt == "" {
		return 0, ""
	}
	if nl == nt {
		return 95, "normalized"
	}
	truncated := strings.HasSuffix(line, "…") || strings.HasSuffix(line, "...")
	if truncated && utf8.RuneCountInString(nl) >= 2 && strings.HasPrefix(nt, nl) {
		return 85, "truncated"
	}
	short, long := nl, nt
	if utf8.RuneCountInString(short) > utf8.RuneCountInString(long) {
		short, long = long, short
	}
	if utf8.RuneCountInString(short) >= 2 && strings.Contains(long, short) {
		ratio := float64(utf8.RuneCountInString(short)) / float64(utf8.RuneCountInString(long))
		if ratio >= 0.5 {
			return 70 + 10*ratio, "contains"
		}
	}
	if sim := Similarity(nl, nt); sim >= 0.75 {
		return 40 + 30*sim, "fuzzy"
	}
	return 0, ""
}

// Normalize lowercases, folds full-width ASCII, and drops whitespace,
// punctuation, symbols and emoji so that OCR noise around a title does not
// matter.
func Normalize(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		switch {
		case r == 0x3000:
			continue // ideographic space
		case r >= 0xFF01 && r <= 0xFF5E:
			r -= 0xFEE0 // full-width ASCII → ASCII
		}
		if unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r) ||
			unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) || unicode.Is(unicode.Cf, r) ||
			unicode.Is(unicode.Co, r) || unicode.Is(unicode.Cs, r) || unicode.IsControl(r) {
			continue
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return b.String()
}

// Similarity is 1 - (edit distance / longer length), computed on runes.
func Similarity(a, b string) float64 {
	ra, rb := []rune(a), []rune(b)
	if len(ra) == 0 && len(rb) == 0 {
		return 1
	}
	maxLen := len(ra)
	if len(rb) > maxLen {
		maxLen = len(rb)
	}
	return 1 - float64(Levenshtein(ra, rb))/float64(maxLen)
}

func Levenshtein(a, b []rune) int {
	if len(a) == 0 {
		return len(b)
	}
	if len(b) == 0 {
		return len(a)
	}
	prev := make([]int, len(b)+1)
	cur := make([]int, len(b)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(a); i++ {
		cur[0] = i
		for j := 1; j <= len(b); j++ {
			cost := 1
			if a[i-1] == b[j-1] {
				cost = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+cost)
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

func dedupe(chats []adapter.Chat) []adapter.Chat {
	seen := make(map[adapter.ID]bool, len(chats))
	out := make([]adapter.Chat, 0, len(chats))
	for _, c := range chats {
		if seen[c.ID] {
			continue
		}
		seen[c.ID] = true
		out = append(out, c)
	}
	return out
}
