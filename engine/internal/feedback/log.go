// Package feedback appends one JSON line per event to a local log and
// summarizes it. By default no message or suggestion text is stored.
package feedback

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Events written by the engine: generated, empty, error.
// Events written by the app: shown, accepted, dismissed, voided, sent.
type Event struct {
	Time          time.Time `json:"time"`
	RequestID     string    `json:"request_id,omitempty"`
	PlatformID    string    `json:"platform_id,omitempty"`
	Event         string    `json:"event"`
	Chat          string    `json:"chat,omitempty"`
	Mode          string    `json:"mode,omitempty"`
	SuggestionLen int       `json:"suggestion_len,omitempty"`
	InputLen      int       `json:"input_len,omitempty"`
	LatencyMS     int64     `json:"latency_ms,omitempty"`
	EditDistance  *int      `json:"edit_distance,omitempty"`
	Commits       bool      `json:"commits,omitempty"`
	NeedsCheck    bool      `json:"needs_check,omitempty"`
	Sensitive     bool      `json:"sensitive,omitempty"`
	ErrorCode     string    `json:"error_code,omitempty"`
	Detail        string    `json:"detail,omitempty"`
	Suggestion    string    `json:"suggestion,omitempty"`
	Input         string    `json:"input,omitempty"`
}

type Logger struct {
	path      string
	plaintext bool
	mu        sync.Mutex
}

func NewLogger(path string, plaintext bool) *Logger {
	return &Logger{path: path, plaintext: plaintext}
}

func (l *Logger) Append(e Event) error {
	if l == nil || l.path == "" {
		return nil
	}
	if e.Time.IsZero() {
		e.Time = time.Now()
	}
	if !l.plaintext {
		e.Suggestion, e.Input = "", ""
	}
	line, err := json.Marshal(e)
	if err != nil {
		return err
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if err := os.MkdirAll(filepath.Dir(l.path), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(l.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(line, '\n'))
	return err
}

// HashChat keeps logs useful for grouping without storing chat IDs.
func HashChat(id string) string {
	if id == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:5])
}

type Summary struct {
	Since, Until      time.Time
	Generated, Empty  int
	Errors            int
	Shown, Accepted   int
	Dismissed, Voided int
	Sent              int
	ErrorCodes        map[string]int
	VoidReasons       map[string]int
	ModelLatenciesMS  []int64
	EditDistances     []int
	SuggestionLengths []int
}

func Stats(path string) (Summary, error) {
	s := Summary{ErrorCodes: map[string]int{}, VoidReasons: map[string]int{}}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return s, nil
		}
		return s, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		var e Event
		if json.Unmarshal(sc.Bytes(), &e) != nil {
			continue
		}
		if s.Since.IsZero() || e.Time.Before(s.Since) {
			s.Since = e.Time
		}
		if e.Time.After(s.Until) {
			s.Until = e.Time
		}
		switch e.Event {
		case "generated":
			s.Generated++
			if e.LatencyMS > 0 {
				s.ModelLatenciesMS = append(s.ModelLatenciesMS, e.LatencyMS)
			}
			if e.SuggestionLen > 0 {
				s.SuggestionLengths = append(s.SuggestionLengths, e.SuggestionLen)
			}
		case "empty":
			s.Empty++
		case "error":
			s.Errors++
			s.ErrorCodes[e.ErrorCode]++
		case "shown":
			s.Shown++
		case "accepted":
			s.Accepted++
		case "dismissed":
			s.Dismissed++
		case "voided":
			s.Voided++
			s.VoidReasons[e.Detail]++
		case "sent":
			s.Sent++
			if e.EditDistance != nil {
				s.EditDistances = append(s.EditDistances, *e.EditDistance)
			}
		}
	}
	return s, sc.Err()
}

func (s Summary) String() string {
	var b strings.Builder
	if s.Generated+s.Empty+s.Errors == 0 {
		return "还没有记录。用快捷键触发几次之后再来看。"
	}
	fmt.Fprintf(&b, "统计区间：%s ～ %s\n", s.Since.Local().Format("01-02 15:04"), s.Until.Local().Format("01-02 15:04"))
	triggers := s.Generated + s.Empty + s.Errors
	fmt.Fprintf(&b, "触发 %d 次：出建议 %d，不建议 %d，出错 %d\n", triggers, s.Generated, s.Empty, s.Errors)
	if s.Shown > 0 {
		fmt.Fprintf(&b, "显示 %d 次：接受 %d（%.0f%%），取消 %d，作废 %d\n",
			s.Shown, s.Accepted, 100*float64(s.Accepted)/float64(s.Shown), s.Dismissed, s.Voided)
	}
	if len(s.EditDistances) > 0 {
		zero := 0
		for _, d := range s.EditDistances {
			if d == 0 {
				zero++
			}
		}
		fmt.Fprintf(&b, "接受后发出 %d 条：原样发出 %.0f%%，改动字数中位数 %d\n",
			len(s.EditDistances), 100*float64(zero)/float64(len(s.EditDistances)), medianInt(s.EditDistances))
	}
	if len(s.ModelLatenciesMS) > 0 {
		fmt.Fprintf(&b, "引擎耗时中位数 %d ms（P90 %d ms）\n", median64(s.ModelLatenciesMS), percentile64(s.ModelLatenciesMS, 0.9))
	}
	if len(s.ErrorCodes) > 0 {
		fmt.Fprintf(&b, "出错原因：%s\n", formatCounts(s.ErrorCodes))
	}
	if len(s.VoidReasons) > 0 {
		fmt.Fprintf(&b, "作废原因：%s\n", formatCounts(s.VoidReasons))
	}
	return strings.TrimSpace(b.String())
}

func formatCounts(m map[string]int) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return m[keys[i]] > m[keys[j]] })
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		name := k
		if name == "" {
			name = "未知"
		}
		parts = append(parts, fmt.Sprintf("%s ×%d", name, m[k]))
	}
	return strings.Join(parts, "，")
}

// Numbers is the summary as plain figures, for the settings window.
type Numbers struct {
	Since           time.Time `json:"since"`
	Until           time.Time `json:"until"`
	Triggers        int       `json:"triggers"`
	Generated       int       `json:"generated"`
	Empty           int       `json:"empty"`
	Errors          int       `json:"errors"`
	Shown           int       `json:"shown"`
	Accepted        int       `json:"accepted"`
	Dismissed       int       `json:"dismissed"`
	Voided          int       `json:"voided"`
	Sent            int       `json:"sent"`
	SentUnchanged   int       `json:"sent_unchanged"`
	MedianLatencyMS int64     `json:"median_latency_ms"`
	P90LatencyMS    int64     `json:"p90_latency_ms"`
}

func (s Summary) Numbers() Numbers {
	n := Numbers{
		Since: s.Since, Until: s.Until,
		Triggers:  s.Generated + s.Empty + s.Errors,
		Generated: s.Generated, Empty: s.Empty, Errors: s.Errors,
		Shown: s.Shown, Accepted: s.Accepted, Dismissed: s.Dismissed, Voided: s.Voided,
		Sent: len(s.EditDistances),
	}
	for _, d := range s.EditDistances {
		if d == 0 {
			n.SentUnchanged++
		}
	}
	if len(s.ModelLatenciesMS) > 0 {
		n.MedianLatencyMS = median64(s.ModelLatenciesMS)
		n.P90LatencyMS = percentile64(s.ModelLatenciesMS, 0.9)
	}
	return n
}

func medianInt(xs []int) int {
	c := append([]int(nil), xs...)
	sort.Ints(c)
	return c[len(c)/2]
}

func median64(xs []int64) int64 { return percentile64(xs, 0.5) }

func percentile64(xs []int64, p float64) int64 {
	c := append([]int64(nil), xs...)
	sort.Slice(c, func(i, j int) bool { return c[i] < c[j] })
	i := int(p * float64(len(c)-1))
	return c[i]
}
