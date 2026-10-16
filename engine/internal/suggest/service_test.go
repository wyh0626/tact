package suggest

import (
	"context"
	"github.com/wyh0626/tact/engine/internal/prompt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/wyh0626/tact/engine/internal/adapter"
	"github.com/wyh0626/tact/engine/internal/chatgpt"
	"github.com/wyh0626/tact/engine/internal/config"
	"github.com/wyh0626/tact/engine/internal/feedback"
	"github.com/wyh0626/tact/engine/internal/model"
	"github.com/wyh0626/tact/engine/internal/resolve"
)

type fakeAdapter struct {
	chats    []adapter.Chat
	history  map[string][]adapter.Message
	drafts   []adapter.Draft
	chatsHit int

	mu         sync.Mutex
	historyHit int
	// gate, when set, blocks History until it is closed.
	gate chan struct{}
}

func (f *fakeAdapter) historyCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.historyHit
}

func (f *fakeAdapter) Chats(context.Context) ([]adapter.Chat, error) {
	f.chatsHit++
	return f.chats, nil
}

func (f *fakeAdapter) History(_ context.Context, id string, limit int) ([]adapter.Message, error) {
	f.mu.Lock()
	f.historyHit++
	gate := f.gate
	f.mu.Unlock()
	if gate != nil {
		<-gate
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	msgs := f.history[id]
	if len(msgs) > limit {
		msgs = msgs[len(msgs)-limit:]
	}
	return msgs, nil
}

func (f *fakeAdapter) Drafts(context.Context) ([]adapter.Draft, error) {
	if f.drafts == nil {
		return nil, adapter.ErrUnsupported
	}
	return f.drafts, nil
}

type fakeModel struct {
	mu    sync.Mutex
	reply string
	last  []model.Message
}

func (f *fakeModel) Complete(_ context.Context, msgs []model.Message) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.last = msgs
	return f.reply, nil
}

func newTestService(t *testing.T, reply string) (*Service, *fakeAdapter, *fakeModel, string) {
	t.Helper()
	dir := t.TempDir()
	cfg := config.Default()
	cfg.Adapter.Command = []string{"unused"}
	cfg.Style.File = filepath.Join(dir, "style.md")
	cfg.Feedback.File = filepath.Join(dir, "feedback.jsonl")
	_ = os.WriteFile(cfg.Style.File, []byte("- 不用感叹号\n\n## 工作聊天\n- 简短直接\n\n## 朋友聊天\n- 口语化\n"), 0o600)
	cfg.Style.ChatSections = map[string]string{"李四 Li Si": "朋友聊天"}

	fa := &fakeAdapter{
		chats: []adapter.Chat{
			{ID: "1001", Title: "张三 Zhang San", Type: "private"},
			{ID: "1003", Title: "李四 Li Si", Type: "private"},
		},
		history: map[string][]adapter.Message{
			"1001": {
				{ID: "m1", Sender: "张三 Zhang San", Text: "支付回调那个改动明天能上线吗？"},
			},
			"1003": {
				{ID: "m9", Sender: "李四 Li Si", Text: "周末打球吗"},
			},
		},
	}
	fm := &fakeModel{reply: reply}
	return New(cfg, fa, fm, feedback.NewLogger(cfg.Feedback.File, false)), fa, fm, cfg.Feedback.File
}

func TestSuggestFromOCR(t *testing.T) {
	svc, _, fm, logPath := newTestService(t, `{"suggestion":"建议：还要跑完测试才能定，我确认后同步时间。","commits":false,"needs_check":false}`)
	resp := svc.Handle(context.Background(), Request{
		Op:        "suggest",
		RequestID: "r1",
		OCRLines:  []resolve.Line{{Text: "最近曾上线", Height: 12}, {Text: "张三 Zhang San", Height: 20}},
		Input:     "还要测试，别承诺",
	})
	if !resp.OK {
		t.Fatalf("suggest failed: %+v", resp)
	}
	if resp.Chat.ID != "1001" || resp.Mode != "rewrite" || resp.LastMessageID != "m1" {
		t.Fatalf("unexpected response: %+v", resp)
	}
	if resp.Suggestion == nil || *resp.Suggestion != "还要跑完测试才能定，我确认后同步时间。" {
		t.Fatalf("suggestion not cleaned: %v", resp.Suggestion)
	}
	user := fm.last[1].Content
	if !strings.Contains(user, "My intent: 还要测试，别承诺") || !strings.Contains(fm.last[0].Content, "简短直接") {
		t.Fatalf("prompt missing intent or work style:\n%s\n%s", fm.last[0].Content, user)
	}
	data, _ := os.ReadFile(logPath)
	if !strings.Contains(string(data), `"event":"generated"`) || strings.Contains(string(data), "别承诺") {
		t.Fatalf("feedback log must record the event without plaintext: %s", data)
	}
}

func TestStyleSectionPerChat(t *testing.T) {
	svc, _, fm, _ := newTestService(t, `{"suggestion":"行啊"}`)
	resp := svc.Handle(context.Background(), Request{Op: "suggest", ChatID: "1003"})
	if !resp.OK || resp.Mode != "complete" {
		t.Fatalf("unexpected: %+v", resp)
	}
	if !strings.Contains(fm.last[0].Content, "口语化") || strings.Contains(fm.last[0].Content, "简短直接") {
		t.Fatalf("chat 1003 should get the friends section:\n%s", fm.last[0].Content)
	}
}

func TestModelDeclines(t *testing.T) {
	svc, _, _, _ := newTestService(t, `{"suggestion": null}`)
	resp := svc.Handle(context.Background(), Request{Op: "suggest", Title: "张三 Zhang San"})
	if !resp.OK || resp.Suggestion != nil {
		t.Fatalf("want ok with no suggestion, got %+v", resp)
	}
}

func TestNotResolvedAndBadOutput(t *testing.T) {
	svc, fa, _, _ := newTestService(t, "我觉得可以")
	resp := svc.Handle(context.Background(), Request{Op: "suggest", Title: "不存在的群"})
	if resp.OK || resp.ErrorCode != CodeNotResolved {
		t.Fatalf("want not_resolved, got %+v", resp)
	}
	if fa.chatsHit < 2 {
		t.Fatalf("an unknown title should refresh the chat list once, hits=%d", fa.chatsHit)
	}
	resp = svc.Handle(context.Background(), Request{Op: "suggest", Title: "张三 Zhang San"})
	if resp.OK || resp.ErrorCode != CodeModelOutput {
		t.Fatalf("want model_bad_output, got %+v", resp)
	}
}

func TestDraftConflict(t *testing.T) {
	svc, fa, _, _ := newTestService(t, `{"suggestion":"好"}`)
	fa.drafts = []adapter.Draft{{ChatID: "1003", Text: "周六可以"}}
	resp := svc.Handle(context.Background(), Request{Op: "suggest", Title: "张三 Zhang San", Input: "周六可以"})
	if resp.OK || resp.ErrorCode != CodeDraftConflict {
		t.Fatalf("want draft_conflict, got %+v", resp)
	}
	fa.drafts = []adapter.Draft{{ChatID: "1001", Text: "周六可以"}}
	resp = svc.Handle(context.Background(), Request{Op: "suggest", Title: "张三 Zhang San", Input: "周六可以"})
	if !resp.OK {
		t.Fatalf("a draft in the same chat is fine, got %+v", resp)
	}
}

func TestCheck(t *testing.T) {
	svc, fa, _, _ := newTestService(t, "")
	resp := svc.Handle(context.Background(), Request{Op: "check", ChatID: "1001", LastMessageID: "m1"})
	if !resp.OK || resp.Valid == nil || !*resp.Valid {
		t.Fatalf("want valid, got %+v", resp)
	}
	fa.history["1001"] = append(fa.history["1001"], adapter.Message{ID: "m2", Text: "？"})
	resp = svc.Handle(context.Background(), Request{Op: "check", ChatID: "1001", LastMessageID: "m1"})
	if !resp.OK || resp.Valid == nil || *resp.Valid {
		t.Fatalf("a newer message must invalidate, got %+v", resp)
	}
}

func TestFeedbackAndStats(t *testing.T) {
	svc, _, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	ctx := context.Background()
	svc.Handle(ctx, Request{Op: "suggest", RequestID: "a", Title: "张三 Zhang San"})
	zero := 0
	for _, ev := range []Request{
		{Op: "feedback", RequestID: "a", Event: "shown", ChatID: "1001"},
		{Op: "feedback", RequestID: "a", Event: "accepted", ChatID: "1001"},
		{Op: "feedback", RequestID: "a", Event: "sent", ChatID: "1001", EditDistance: &zero},
	} {
		if r := svc.Handle(ctx, ev); !r.OK {
			t.Fatalf("feedback failed: %+v", r)
		}
	}
	if r := svc.Handle(ctx, Request{Op: "feedback", Event: "bogus"}); r.OK {
		t.Fatal("unknown events must be rejected")
	}
	stats := svc.Handle(ctx, Request{Op: "stats"})
	if !stats.OK || !strings.Contains(stats.Stats, "接受 1（100%）") || !strings.Contains(stats.Stats, "原样发出 100%") {
		t.Fatalf("unexpected stats:\n%s", stats.Stats)
	}
}

func TestPrepareThenSuggestUsesPrefetchedHistory(t *testing.T) {
	svc, fa, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	ctx := context.Background()
	prep := svc.Handle(ctx, Request{Op: "prepare", OCRLines: []resolve.Line{{Text: "张三 Zhang San", Height: 30}}})
	if !prep.OK || prep.Chat == nil || prep.Chat.ID != "1001" || prep.LastMessageID != "m1" {
		t.Fatalf("prepare: %+v", prep)
	}
	resp := svc.Handle(ctx, Request{Op: "suggest", ChatID: "1001"})
	if !resp.OK || resp.Suggestion == nil {
		t.Fatalf("suggest: %+v", resp)
	}
	if fa.historyCalls() != 1 || resp.TimingMS["history_cached"] != 1 {
		t.Fatalf("want the prefetched history reused, got %d fetches, timing %v", fa.historyCalls(), resp.TimingMS)
	}
}

func TestSuggestRefetchesStaleHistory(t *testing.T) {
	svc, fa, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	ctx := context.Background()
	now := time.Now()
	svc.now = func() time.Time { return now }
	svc.Handle(ctx, Request{Op: "prepare", ChatID: "1001"})

	fa.mu.Lock()
	fa.history["1001"] = append(fa.history["1001"], adapter.Message{ID: "m2", Text: "在吗"})
	fa.mu.Unlock()
	now = now.Add(time.Duration(svc.cfg.Context.HistoryCacheSeconds+1) * time.Second)

	resp := svc.Handle(ctx, Request{Op: "suggest", ChatID: "1001"})
	if resp.LastMessageID != "m2" || fa.historyCalls() != 2 {
		t.Fatalf("want a fresh fetch after the cache expired, got last %q after %d fetches", resp.LastMessageID, fa.historyCalls())
	}
}

func TestPrepareAlwaysRefreshes(t *testing.T) {
	svc, fa, _, _ := newTestService(t, "")
	ctx := context.Background()
	svc.Handle(ctx, Request{Op: "prepare", ChatID: "1001"})
	svc.Handle(ctx, Request{Op: "prepare", ChatID: "1001"})
	if fa.historyCalls() != 2 {
		t.Fatalf("prepare must not serve from cache, got %d fetches", fa.historyCalls())
	}
}

func TestZeroCacheSecondsAlwaysFetches(t *testing.T) {
	svc, fa, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	svc.cfg.Context.HistoryCacheSeconds = 0
	ctx := context.Background()
	svc.Handle(ctx, Request{Op: "prepare", ChatID: "1001"})
	svc.Handle(ctx, Request{Op: "suggest", ChatID: "1001"})
	if fa.historyCalls() != 2 {
		t.Fatalf("want no cache reuse, got %d fetches", fa.historyCalls())
	}
}

func TestSuggestJoinsPrefetchInFlight(t *testing.T) {
	svc, fa, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	fa.gate = make(chan struct{})
	ctx := context.Background()

	prepDone := make(chan Response, 1)
	go func() { prepDone <- svc.Handle(ctx, Request{Op: "prepare", ChatID: "1001"}) }()
	for fa.historyCalls() == 0 {
		time.Sleep(time.Millisecond)
	}
	suggestDone := make(chan Response, 1)
	go func() { suggestDone <- svc.Handle(ctx, Request{Op: "suggest", ChatID: "1001"}) }()
	time.Sleep(20 * time.Millisecond)
	close(fa.gate)

	if r := <-prepDone; !r.OK {
		t.Fatalf("prepare: %+v", r)
	}
	if r := <-suggestDone; !r.OK || r.Suggestion == nil {
		t.Fatalf("suggest: %+v", r)
	}
	if fa.historyCalls() != 1 {
		t.Fatalf("want one shared fetch, got %d", fa.historyCalls())
	}
}

func TestCancelledSuggestDoesNotWasteFetch(t *testing.T) {
	svc, fa, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	fa.gate = make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan Response, 1)
	go func() { done <- svc.Handle(ctx, Request{Op: "suggest", ChatID: "1001"}) }()
	for fa.historyCalls() == 0 {
		time.Sleep(time.Millisecond)
	}
	cancel()
	if r := <-done; r.ErrorCode != CodeCancelled {
		t.Fatalf("want cancelled, got %+v", r)
	}
	close(fa.gate)
	resp := svc.Handle(context.Background(), Request{Op: "suggest", ChatID: "1001"})
	if !resp.OK || fa.historyCalls() != 1 {
		t.Fatalf("want the finished fetch reused, got %+v after %d fetches", resp, fa.historyCalls())
	}
}

func TestModelTest(t *testing.T) {
	svc, _, _, _ := newTestService(t, "OK")
	resp := svc.Handle(context.Background(), Request{Op: "model_test"})
	if !resp.OK || resp.Note != "OK" {
		t.Fatalf("model_test: %+v", resp)
	}
	if _, ok := resp.TimingMS["model"]; !ok {
		t.Fatalf("want model timing, got %v", resp.TimingMS)
	}
}

func TestModelTestEmptyReply(t *testing.T) {
	svc, _, _, _ := newTestService(t, "  ")
	resp := svc.Handle(context.Background(), Request{Op: "model_test"})
	if resp.OK || resp.ErrorCode != CodeModelOutput {
		t.Fatalf("want model_bad_output, got %+v", resp)
	}
}

func TestWarmLoadsChats(t *testing.T) {
	svc, fa, _, _ := newTestService(t, "")
	svc.Warm(context.Background())
	svc.Handle(context.Background(), Request{Op: "resolve", Title: "张三 Zhang San"})
	if fa.chatsHit != 1 {
		t.Fatalf("want the warmed chat list reused, got %d fetches", fa.chatsHit)
	}
}

func TestStatsData(t *testing.T) {
	svc, _, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	ctx := context.Background()
	svc.Handle(ctx, Request{Op: "suggest", RequestID: "a", Title: "张三 Zhang San"})
	svc.Handle(ctx, Request{Op: "feedback", RequestID: "a", Event: "shown", ChatID: "1001"})
	svc.Handle(ctx, Request{Op: "feedback", RequestID: "a", Event: "accepted", ChatID: "1001"})
	resp := svc.Handle(ctx, Request{Op: "stats"})
	if resp.StatsData == nil || resp.StatsData.Triggers != 1 || resp.StatsData.Shown != 1 || resp.StatsData.Accepted != 1 {
		t.Fatalf("stats_data: %+v", resp.StatsData)
	}
}

func TestChatGPTOps(t *testing.T) {
	svc, _, _, _ := newTestService(t, "")
	if resp := svc.Handle(context.Background(), Request{Op: "chatgpt_status"}); resp.OK {
		t.Fatalf("without a sign-in manager the op must fail, got %+v", resp)
	}
	svc.chatgpt = chatgpt.NewManager(filepath.Join(t.TempDir(), "chatgpt.json"))
	resp := svc.Handle(context.Background(), Request{Op: "chatgpt_status"})
	if !resp.OK || resp.ChatGPT == nil || resp.ChatGPT.SignedIn {
		t.Fatalf("status = %+v", resp)
	}
	if resp := svc.Handle(context.Background(), Request{Op: "chatgpt_models"}); resp.OK || !strings.Contains(resp.Error, "登录") {
		t.Fatalf("models before sign-in = %+v", resp)
	}
	if resp := svc.Handle(context.Background(), Request{Op: "chatgpt_logout"}); !resp.OK {
		t.Fatalf("logout when signed out = %+v", resp)
	}
}

// warmingModel is a model that can read a prompt ahead, like the local one.
type warmingModel struct {
	fakeModel
	warmed chan []model.Message
}

func (w *warmingModel) Prewarm(_ context.Context, msgs []model.Message) { w.warmed <- msgs }

// A prefetch has a model that can read ahead read the very prompt the
// hotkey will send, so its reading can be reused.
func TestPrepareWarmsAModelThatReadsAhead(t *testing.T) {
	svc, _, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	wm := &warmingModel{fakeModel: fakeModel{reply: `{"suggestion":"好的"}`}, warmed: make(chan []model.Message, 1)}
	svc.model = wm
	now := time.Now()
	svc.now = func() time.Time { return now }
	ctx := context.Background()
	if prep := svc.Handle(ctx, Request{Op: "prepare", ChatID: "1001"}); !prep.OK {
		t.Fatalf("prepare: %+v", prep)
	}
	var warmed []model.Message
	select {
	case warmed = <-wm.warmed:
	case <-time.After(2 * time.Second):
		t.Fatal("prepare did not warm the model")
	}
	if resp := svc.Handle(ctx, Request{Op: "suggest", ChatID: "1001"}); !resp.OK {
		t.Fatalf("suggest: %+v", resp)
	}
	wm.mu.Lock()
	sent := wm.last
	wm.mu.Unlock()
	if len(sent) != len(warmed) {
		t.Fatalf("warmed %d messages, sent %d", len(warmed), len(sent))
	}
	for i := range sent {
		if sent[i] != warmed[i] {
			t.Fatalf("message %d differs between the warm-up and the request:\n%q\n%q", i, warmed[i].Content, sent[i].Content)
		}
	}
}

// limitModel replies with a fixed text and keeps the output limit its
// request was made with.
type limitModel struct {
	reply string
	limit int
}

func (m *limitModel) Complete(ctx context.Context, _ []model.Message) (string, error) {
	m.limit = model.MaxTokensFor(ctx, 300)
	return m.reply, nil
}

func TestALongDraftIsRewrittenAtItsOwnLength(t *testing.T) {
	svc, _, _, _ := newTestService(t, "")
	draft := strings.Repeat("这个方案我看过了，整体没问题，但排期需要再确认。", 12)
	rewrite := strings.Repeat("这个方案我看过，整体没有问题，不过排期还要再确认。", 12)
	m := &limitModel{reply: `{"suggestion":"` + rewrite + `"}`}
	svc.model = m
	resp := svc.Handle(context.Background(), Request{Op: "suggest", ChatID: "1001", Input: draft})
	if !resp.OK || resp.Mode != "rewrite" || resp.Suggestion == nil || *resp.Suggestion != rewrite {
		t.Fatalf("a rewrite longer than max_suggestion_chars is kept: %+v", resp)
	}
	if n := utf8.RuneCountInString(draft); m.limit != 3*n+300 {
		t.Fatalf("output limit = %d for a %d-character draft", m.limit, n)
	}

	m.limit = 0
	if resp := svc.Handle(context.Background(), Request{Op: "suggest", ChatID: "1001", Input: "婉拒"}); !resp.OK || m.limit != 300 {
		t.Fatalf("a few words keep the configured limits: %+v, limit %d", resp, m.limit)
	}
}

func TestADraftTooLongToRewriteWholeIsRefused(t *testing.T) {
	svc, fa, fm, _ := newTestService(t, `{"suggestion":"好"}`)
	resp := svc.Handle(context.Background(), Request{Op: "suggest", ChatID: "1001",
		Input: strings.Repeat("字", prompt.MaxDraftRunes+1)})
	if resp.OK || resp.ErrorCode != CodeDraftTooLong || !strings.Contains(resp.Error, "分成几条") {
		t.Fatalf("resp = %+v", resp)
	}
	if fa.historyCalls() != 0 || fm.last != nil {
		t.Fatal("a refused draft reads nothing and asks no model")
	}
}
