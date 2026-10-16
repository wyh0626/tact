package suggest

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/wyh0626/tact/engine/internal/adapter"
	"github.com/wyh0626/tact/engine/internal/config"
)

func TestScreenSuggestUsesTheMessagesItCarries(t *testing.T) {
	t.Parallel()
	svc, fa, fm, logPath := newTestService(t, `{"suggestion":"好，周六上午见"}`)
	resp := svc.Handle(context.Background(), Request{
		Op: "suggest", RequestID: "w1", PlatformID: "wechat", Input: "可以",
		Screen: &ScreenChat{Title: "周末球局", Type: "group", Messages: []adapter.Message{
			{Sender: "王五", Text: "周六上午打球吗？"},
			{Sender: "", Text: "   "},
			{FromMe: true, Text: "几点"},
			{Sender: "王五", Text: " 九点，老地方 "},
		}},
	})
	if !resp.OK || resp.PlatformID != "wechat" || resp.Suggestion == nil || *resp.Suggestion != "好，周六上午见" {
		t.Fatalf("screen suggest = %+v", resp)
	}
	if resp.Chat == nil || resp.Chat.Title != "周末球局" || resp.Method != "screen" || resp.Mode != "rewrite" || resp.LastMessageID != "" {
		t.Fatalf("screen chat = %+v", resp)
	}
	if fa.chatsHit != 0 || fa.historyCalls() != 0 {
		t.Fatalf("a screen request must not touch the plugin: chats %d, history %d", fa.chatsHit, fa.historyCalls())
	}
	prompt := fm.last[1].Content
	for _, want := range []string{"Chat: 周末球局 (group chat)", "王五: 周六上午打球吗？", "Me: 几点", "王五: 九点，老地方", "My intent: 可以"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("prompt missing %q:\n%s", want, prompt)
		}
	}
	if strings.Count(prompt, "\nThem") != 0 {
		t.Fatalf("a message without text must be dropped:\n%s", prompt)
	}

	fb := svc.Handle(context.Background(), Request{Op: "feedback", PlatformID: "wechat", ChatID: "周末球局", Event: "accepted"})
	if !fb.OK || fb.PlatformID != "wechat" {
		t.Fatalf("screen feedback = %+v", fb)
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatal(err)
		}
		if event["platform_id"] != "wechat" {
			t.Fatalf("screen event not bound to its platform: %s", line)
		}
	}
	if strings.Contains(string(data), "周末球局") {
		t.Fatalf("the chat title must be hashed in the log: %s", data)
	}
}

func TestScreenRequestsAreChecked(t *testing.T) {
	t.Parallel()
	svc, _, _, _ := newTestService(t, `{"suggestion":"好"}`)
	ctx := context.Background()
	cases := map[string]Request{
		"no chat":      {Op: "suggest", PlatformID: "wechat"},
		"other op":     {Op: "history", PlatformID: "wechat", Screen: &ScreenChat{Title: "a"}},
		"long title":   {Op: "suggest", PlatformID: "wechat", Screen: &ScreenChat{Title: strings.Repeat("长", maxScreenTitleRunes+1)}},
		"unknown type": {Op: "suggest", PlatformID: "wechat", Screen: &ScreenChat{Title: "a", Type: "channel"}},
		"too many":     {Op: "suggest", PlatformID: "wechat", Screen: &ScreenChat{Title: "a", Messages: make([]adapter.Message, maxScreenMessages+1)}},
		"plugin":       {Op: "suggest", Screen: &ScreenChat{Title: "a"}},
	}
	for name, req := range cases {
		if resp := svc.Handle(ctx, req); resp.OK || resp.ErrorCode != CodeBadRequest {
			t.Errorf("%s: %+v", name, resp)
		}
	}
}

func TestScreenPlatformWorksAlongsidePlugins(t *testing.T) {
	t.Parallel()
	svc, _, _, _ := newTestService(t, `{"suggestion":"收到"}`)
	manifest := writeTestManifest(t, testPluginManifest)
	svc.configurePlatforms([]config.PlatformConfig{
		{ID: "work", Manifest: manifest, Enabled: true},
		{ID: "personal", Manifest: manifest, Enabled: true},
	})
	resp := svc.Handle(context.Background(), Request{Op: "suggest", PlatformID: "wechat",
		Screen: &ScreenChat{Title: "张三", Type: "private", Messages: []adapter.Message{{Sender: "张三", Text: "到了吗"}}}})
	if !resp.OK || resp.PlatformID != "wechat" || resp.Suggestion == nil {
		t.Fatalf("screen suggest beside plugins = %+v", resp)
	}
}

func TestPracticeSuggestionsAreRealButNotCounted(t *testing.T) {
	t.Parallel()
	svc, _, fm, logPath := newTestService(t, `{"suggestion":"好啊，六点半没问题"}`)
	resp := svc.Handle(context.Background(), Request{
		Op: "suggest", RequestID: "p1", PlatformID: PracticePlatformID,
		Screen: &ScreenChat{Title: "小林", Type: "private", Messages: []adapter.Message{
			{Sender: "小林", Text: "周六晚上六点半，我叫上阿杰一起？"},
		}},
	})
	if !resp.OK || resp.PlatformID != PracticePlatformID || resp.Suggestion == nil {
		t.Fatalf("practice suggest = %+v", resp)
	}
	if !strings.Contains(fm.last[1].Content, "小林: 周六晚上六点半") {
		t.Fatalf("practice prompt = %s", fm.last[1].Content)
	}
	for _, event := range []string{"shown", "accepted"} {
		if fb := svc.Handle(context.Background(), Request{Op: "feedback", PlatformID: PracticePlatformID, Event: event}); !fb.OK {
			t.Fatalf("practice feedback = %+v", fb)
		}
	}
	if data, err := os.ReadFile(logPath); err == nil && len(data) > 0 {
		t.Fatalf("practice must not reach the stats: %s", data)
	}
}
