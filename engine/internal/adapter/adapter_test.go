package adapter

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// exampleScript is an adapter answering every operation from fixed JSON,
// with history out of order and longer than asked for.
func exampleScript(t *testing.T) *Script {
	t.Helper()
	script := filepath.Join(t.TempDir(), "example.sh")
	body := `#!/bin/sh
case "$1" in
chats) echo '{"chats":[{"id":"1","title":"张三"},{"id":2,"title":"项目群","type":"group"},{"id":"3","title":"李四"}]}';;
history) echo '{"messages":[
  {"id":"m3","sender":"张三","from_me":false,"text":"几点？","time":"2026-10-12T10:03:00+08:00"},
  {"id":"m1","sender":"张三","from_me":false,"text":"下午评审","time":"2026-10-12T10:01:00+08:00"},
  {"id":"m2","sender":"我","from_me":true,"text":"可以","time":"2026-10-12T10:02:00+08:00"}]}';;
drafts) echo '{"drafts":[{"chat_id":"1","text":"还要测试"}]}';;
esac
`
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	// The first run of a freshly written executable includes macOS's check
	// of new executables, which takes seconds when the machine is busy.
	return &Script{Command: []string{script}, Timeout: 10 * time.Second}
}

func TestScriptAdapter(t *testing.T) {
	s := exampleScript(t)
	ctx := context.Background()
	chats, err := s.Chats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(chats) != 3 || chats[0].Title != "张三" || chats[1].ID != "2" || chats[1].Type != "group" {
		t.Fatalf("unexpected chats: %+v", chats)
	}
	msgs, err := s.History(ctx, string(chats[0].ID), 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 || msgs[0].ID != "m2" || msgs[1].ID != "m3" || !msgs[0].Time.Before(msgs[1].Time.Time) {
		t.Fatalf("want the 2 newest messages oldest first, got %+v", msgs)
	}
	drafts, err := s.Drafts(ctx)
	if err != nil || len(drafts) != 1 || drafts[0].ChatID != "1" {
		t.Fatalf("drafts = %+v, %v", drafts, err)
	}
}

func TestUnsupportedAndFailure(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "a.sh")
	body := "#!/bin/sh\ncase \"$1\" in drafts) exit 3;; chats) echo boom >&2; exit 1;; esac\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	// The first run of a freshly written executable includes macOS's check
	// of new executables, which takes seconds when the machine is busy. This
	// test is about exit codes, not timing, so it leaves room for that.
	s := &Script{Command: []string{script}, Timeout: 10 * time.Second}
	if _, err := s.Drafts(context.Background()); !errors.Is(err, ErrUnsupported) {
		t.Fatalf("exit 3 must map to ErrUnsupported, got %v", err)
	}
	_, err := s.Chats(context.Background())
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("stderr must surface in the error, got %v", err)
	}
}

func TestTimeout(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "slow.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nsleep 5\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	s := &Script{Command: []string{script}, Timeout: 200 * time.Millisecond}
	start := time.Now()
	_, err := s.Chats(context.Background())
	if err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("want a quick timeout error, got %v after %s", err, time.Since(start))
	}
}

func TestFlexibleJSON(t *testing.T) {
	var c Chat
	if err := json.Unmarshal([]byte(`{"id": 12345678901, "title": "x", "last_message_at": 1760234742}`), &c); err != nil {
		t.Fatal(err)
	}
	if c.ID != "12345678901" || c.LastMessageAt.Unix() != 1760234742 {
		t.Fatalf("numeric id/time not accepted: %+v", c)
	}
	var m Message
	if err := json.Unmarshal([]byte(`{"id": "a", "time": 1760234742000, "reply_to": null}`), &m); err != nil {
		t.Fatal(err)
	}
	if m.Time.Unix() != 1760234742 {
		t.Fatalf("millisecond time not accepted: %v", m.Time)
	}
	var list []Chat
	if err := decodeList([]byte(`[{"id":"1","title":"a"}]`), "chats", &list); err != nil || len(list) != 1 {
		t.Fatalf("bare array not accepted: %v %v", list, err)
	}
}
