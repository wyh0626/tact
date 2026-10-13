package resolve

import (
	"errors"
	"testing"
	"time"

	"github.com/wyh0626/tact/engine/internal/adapter"
)

func chats() []adapter.Chat {
	return []adapter.Chat{
		{ID: "1", Title: "张三 Zhang San 🎃", Type: "private"},
		{ID: "2", Title: "【研发】支付项目组", Type: "group"},
		{ID: "3", Title: "李四 Li Si", Type: "private"},
		{ID: "4", Title: "在线客服群", Type: "group"},
		{ID: "5", Title: "张三", Type: "private"},
		{ID: "6", Title: "张三", Type: "private"},
		{ID: "7", Title: "海外贷后问题处理群（新）", Type: "group"},
	}
}

func TestResolve(t *testing.T) {
	cases := []struct {
		name   string
		lines  []Line
		wantID string
		method string
	}{
		{"emoji stripped", []Line{{"张三 Zhang San", 30}, {"最近曾上线", 18}}, "1", "normalized"},
		{"status line is ignored", []Line{{"最近曾上线", 30}, {"李四 Li Si", 28}}, "3", "exact"},
		{"OCR noise on emoji", []Line{{"张三 Zhang San 自", 30}}, "1", "contains"},
		{"full-width brackets and spaces", []Line{{"[研发] 支付项目组", 30}}, "2", "normalized"},
		{"truncated title", []Line{{"海外贷后问题处理…", 30}}, "7", "truncated"},
		{"title containing a status word", []Line{{"在线客服群", 30}}, "4", "exact"},
		{"one character misread", []Line{{"李西 Li Si", 30}}, "3", "fuzzy"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, err := Resolve(tc.lines, chats())
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if string(r.Chat.ID) != tc.wantID || r.Method != tc.method {
				t.Fatalf("got chat %s via %s, want %s via %s", r.Chat.ID, r.Method, tc.wantID, tc.method)
			}
		})
	}
}

func TestResolveAmbiguousSameName(t *testing.T) {
	cs := chats()
	cs[4].LastMessageAt = adapter.Time{Time: time.Now()}
	_, err := Resolve([]Line{{"张三", 30}}, cs)
	var amb *AmbiguousError
	if !errors.As(err, &amb) {
		t.Fatalf("want AmbiguousError even when one is more recent, got %v", err)
	}
	if len(amb.Titles) != 2 {
		t.Fatalf("want 2 candidates, got %v", amb.Titles)
	}
}

func TestResolveNotFound(t *testing.T) {
	_, err := Resolve([]Line{{"完全不相干的群", 30}}, chats())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
	_, err = Resolve([]Line{{"张", 30}}, chats())
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("a single character must not match anything, got %v", err)
	}
}

func TestNormalize(t *testing.T) {
	if got := Normalize("ＡＢＣ　张三‍👍！"); got != "abc张三" {
		t.Fatalf("Normalize = %q", got)
	}
}

func TestHeadlineSkipsIconsAndStatus(t *testing.T) {
	lines := []Line{
		{Text: "Q", Height: 40},
		{Text: "张扬乐 Erik Zhang", Height: 30},
		{Text: "最近曾上线", Height: 20},
	}
	if got := Headline(lines); got != "张扬乐 Erik Zhang" {
		t.Fatalf("got %q", got)
	}
	if got := Headline([]Line{{Text: "Q", Height: 40}}); got != "Q" {
		t.Fatalf("fallback: got %q", got)
	}
	if got := Headline(nil); got != "" {
		t.Fatalf("empty: got %q", got)
	}
}

// OCR reads an emoji after a name as a stray character ("🦊" → "的"). The
// emoji may be a status (absent from the CLI title) or part of the name
// (present in the title, possibly mid-name); all must resolve to the person.
func TestResolveEmojiReadAsCharacter(t *testing.T) {
	cases := []struct {
		name   string
		line   string
		chats  []adapter.Chat
		wantID string
	}{
		{"status emoji, title without it", "张扬乐 Erik Zhang的",
			[]adapter.Chat{{ID: "a", Title: "张扬乐 Erik Zhang"}, {ID: "b", Title: "叶方舟 Frank Ye"}}, "a"},
		{"emoji in the title", "张扬乐 Erik Zhang的",
			[]adapter.Chat{{ID: "a", Title: "张扬乐 Erik Zhang 🦊"}, {ID: "b", Title: "叶方舟 Frank Ye"}}, "a"},
		{"emoji mid-name", "小王的Wang",
			[]adapter.Chat{{ID: "a", Title: "小王🐱Wang"}, {ID: "b", Title: "小李 Li"}}, "a"},
		{"short name next to a longer one", "张三的",
			[]adapter.Chat{{ID: "a", Title: "张三"}, {ID: "b", Title: "张三丰"}}, "a"},
		{"longer name next to a short one", "张三丰的",
			[]adapter.Chat{{ID: "a", Title: "张三"}, {ID: "b", Title: "张三丰"}}, "b"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, err := Resolve([]Line{{tc.line, 30}, {"最近曾上线", 18}}, tc.chats)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if string(r.Chat.ID) != tc.wantID {
				t.Fatalf("got %q (%s), want chat %s", r.Chat.Title, r.Method, tc.wantID)
			}
		})
	}
}
