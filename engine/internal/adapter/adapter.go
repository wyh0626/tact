// Package adapter talks to a chat platform through an external script that
// follows the contract in docs/ADAPTER.md. The script owns everything
// platform-specific; the engine only sees the normalized JSON below.
package adapter

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ErrUnsupported is returned when the script exits with status 3, meaning it
// does not implement the requested operation (for example "drafts").
var ErrUnsupported = errors.New("adapter does not support this operation")

// ID accepts both JSON strings and numbers, since platforms disagree.
type ID string

func (id *ID) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "null" {
		*id = ""
		return nil
	}
	if strings.HasPrefix(s, `"`) {
		var str string
		if err := json.Unmarshal(b, &str); err != nil {
			return err
		}
		*id = ID(str)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(b, &n); err != nil {
		return fmt.Errorf("id must be a string or number, got %s", s)
	}
	*id = ID(n.String())
	return nil
}

// Time accepts RFC 3339 strings, "2006-01-02 15:04:05" local strings, unix
// seconds or unix milliseconds. Empty or null means unknown.
type Time struct{ time.Time }

func (t *Time) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "null" || s == `""` {
		return nil
	}
	if strings.HasPrefix(s, `"`) {
		var str string
		if err := json.Unmarshal(b, &str); err != nil {
			return err
		}
		for _, layout := range []string{time.RFC3339Nano, "2006-01-02 15:04:05", "2006-01-02T15:04:05"} {
			if parsed, err := time.ParseInLocation(layout, str, time.Local); err == nil {
				t.Time = parsed
				return nil
			}
		}
		return fmt.Errorf("unrecognized time %q", str)
	}
	n, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return fmt.Errorf("unrecognized time %s", s)
	}
	if n > 1e12 { // milliseconds
		n /= 1000
	}
	sec := int64(n)
	t.Time = time.Unix(sec, int64((n-float64(sec))*1e9))
	return nil
}

func (t Time) MarshalJSON() ([]byte, error) {
	if t.IsZero() {
		return []byte(`""`), nil
	}
	return json.Marshal(t.Time.Format(time.RFC3339))
}

type Chat struct {
	ID            ID     `json:"id"`
	Title         string `json:"title"`
	Type          string `json:"type"` // private | group | channel
	LastMessageAt Time   `json:"last_message_at"`
	Unread        int    `json:"unread"`
}

type Message struct {
	ID         ID     `json:"id"`
	Sender     string `json:"sender"`
	FromMe     bool   `json:"from_me"`
	Text       string `json:"text"`
	Time       Time   `json:"time"`
	ReplyTo    ID     `json:"reply_to"`
	MentionsMe bool   `json:"mentions_me"`
}

type Draft struct {
	ChatID ID     `json:"chat_id"`
	Text   string `json:"text"`
}

// Adapter is what the engine needs from a chat platform.
type Adapter interface {
	Chats(ctx context.Context) ([]Chat, error)
	// History returns the most recent `limit` messages, oldest first.
	History(ctx context.Context, chatID string, limit int) ([]Message, error)
	Drafts(ctx context.Context) ([]Draft, error)
}

// Script runs an external adapter executable.
type Script struct {
	Command []string
	Timeout time.Duration
}

func (s *Script) run(ctx context.Context, args ...string) ([]byte, error) {
	if len(s.Command) == 0 {
		return nil, errors.New("adapter command is empty")
	}
	timeout := s.Timeout
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	argv := append(append([]string{}, s.Command[1:]...), args...)
	cmd := exec.CommandContext(ctx, s.Command[0], argv...)
	// Run the script in its own process group and kill the whole group on
	// timeout; otherwise a CLI it spawned keeps stdout open and Run blocks.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 500 * time.Millisecond
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return nil, fmt.Errorf("适配脚本 %s 超时（%s）", args[0], timeout)
	case errors.Is(ctx.Err(), context.Canceled):
		return nil, ctx.Err()
	case err != nil:
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 3 {
			return nil, ErrUnsupported
		}
		return nil, fmt.Errorf("适配脚本 %s 失败：%v：%s", args[0], err, truncate(strings.TrimSpace(stderr.String()), 400))
	}
	return stdout.Bytes(), nil
}

func (s *Script) Chats(ctx context.Context) ([]Chat, error) {
	out, err := s.run(ctx, "chats")
	if err != nil {
		return nil, err
	}
	var chats []Chat
	if err := decodeList(out, "chats", &chats); err != nil {
		return nil, err
	}
	return chats, nil
}

func (s *Script) History(ctx context.Context, chatID string, limit int) ([]Message, error) {
	out, err := s.run(ctx, "history", chatID, strconv.Itoa(limit))
	if err != nil {
		return nil, err
	}
	var msgs []Message
	if err := decodeList(out, "messages", &msgs); err != nil {
		return nil, err
	}
	return normalizeHistory(msgs, limit), nil
}

func (s *Script) Drafts(ctx context.Context) ([]Draft, error) {
	out, err := s.run(ctx, "drafts")
	if err != nil {
		return nil, err
	}
	var drafts []Draft
	if err := decodeList(out, "drafts", &drafts); err != nil {
		return nil, err
	}
	return drafts, nil
}

// normalizeHistory orders messages oldest first when timestamps are present
// and keeps the last `limit` of them.
func normalizeHistory(msgs []Message, limit int) []Message {
	allTimed := len(msgs) > 0
	for _, m := range msgs {
		if m.Time.IsZero() {
			allTimed = false
			break
		}
	}
	if allTimed {
		sort.SliceStable(msgs, func(i, j int) bool { return msgs[i].Time.Before(msgs[j].Time.Time) })
	}
	if limit > 0 && len(msgs) > limit {
		msgs = msgs[len(msgs)-limit:]
	}
	return msgs
}

// decodeList accepts either {"<key>": [...]} or a bare JSON array.
func decodeList(data []byte, key string, out any) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 {
		return fmt.Errorf("适配脚本没有输出（期望 {\"%s\": [...]}）", key)
	}
	if data[0] == '[' {
		if err := json.Unmarshal(data, out); err != nil {
			return fmt.Errorf("适配脚本输出解析失败：%w", err)
		}
		return nil
	}
	var wrapper map[string]json.RawMessage
	if err := json.Unmarshal(data, &wrapper); err != nil {
		return fmt.Errorf("适配脚本输出不是 JSON：%w：%s", err, truncate(string(data), 200))
	}
	raw, ok := wrapper[key]
	if !ok {
		return fmt.Errorf("适配脚本输出缺少 %q 字段", key)
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("适配脚本的 %s 字段解析失败：%w", key, err)
	}
	return nil
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
