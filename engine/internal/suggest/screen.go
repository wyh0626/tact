package suggest

import (
	"context"
	"errors"
	"math"
	"strings"
	"unicode/utf8"

	"github.com/wyh0626/tact/engine/internal/adapter"
	"github.com/wyh0626/tact/engine/internal/feedback"
	"github.com/wyh0626/tact/engine/internal/prompt"
)

// PracticePlatformID is the practice chat in Tact's first-run guide: its
// suggestions come from the real model, but none of it goes into the stats.
const PracticePlatformID = "practice"

// Built-in platforms whose messages the app sends with each request: chat
// apps read off the screen or through accessibility (WeChat, DingTalk),
// and the practice chat.
var screenPlatforms = map[string]string{"wechat": "微信", "dingtalk": "钉钉", PracticePlatformID: "练习"}

// Bounds on what a request may carry: a window shows far fewer messages.
const (
	maxScreenMessages   = 200
	maxScreenTitleRunes = 200
	maxScreenLines      = 400
	maxScreenTextRunes  = 32000
)

// ScreenChat is the chat as the app read it from the screen.
type ScreenChat struct {
	Title    string            `json:"title"`
	Type     string            `json:"type,omitempty"`
	Messages []adapter.Message `json:"messages"`
	// Lines is the current app's OCR path. Messages remains accepted for
	// older clients; the two representations cannot be mixed.
	Lines []prompt.ScreenLine `json:"lines,omitempty"`
}

// screenSource stands in for an adapter: a screen platform's messages come
// with the request, so nothing may ask it for chats or history.
type screenSource struct{ name string }

func (s screenSource) err() error {
	return errors.New(s.name + "的消息由 Tact 从屏幕读取，没有会话列表和历史接口")
}

func (s screenSource) Chats(context.Context) ([]adapter.Chat, error) { return nil, s.err() }
func (s screenSource) History(context.Context, string, int) ([]adapter.Message, error) {
	return nil, s.err()
}
func (s screenSource) Drafts(context.Context) ([]adapter.Draft, error) { return nil, s.err() }

// screenService returns the service for a built-in screen platform, or nil
// when id is not one.
func (s *Service) screenService(id string) *Service {
	name, ok := screenPlatforms[id]
	if !ok {
		return nil
	}
	s.screenMu.Lock()
	defer s.screenMu.Unlock()
	if svc := s.screens[id]; svc != nil {
		return svc
	}
	log := s.log
	if id == PracticePlatformID {
		log = feedback.NewLogger("", false)
	}
	svc := New(s.cfg, screenSource{name: name}, s.model, log)
	svc.platformID = id
	// No composer.read: there are no drafts to check the chat against.
	svc.capabilities = map[string]bool{"messages.read": true}
	if s.screens == nil {
		s.screens = map[string]*Service{}
	}
	s.screens[id] = svc
	return svc
}

func (s *Service) handleScreen(ctx context.Context, req Request) Response {
	switch req.Op {
	case "suggest":
		if req.Screen == nil {
			return errorResponse(fail(CodeBadRequest, "%s的建议请求需要带上屏幕上读到的会话", screenPlatforms[req.PlatformID]))
		}
		return s.suggest(ctx, req)
	case "feedback":
		return s.feedback(req)
	default:
		return errorResponse(fail(CodeBadRequest, "%s不支持操作 %q", screenPlatforms[req.PlatformID], req.Op))
	}
}

// resolved checks what the app read and turns it into the chat and its
// messages. Messages without text are dropped.
func (c *ScreenChat) resolved() (resolved, []adapter.Message, error) {
	title := strings.TrimSpace(c.Title)
	if len([]rune(title)) > maxScreenTitleRunes {
		return resolved{}, nil, fail(CodeBadRequest, "会话名称太长")
	}
	if len(c.Messages) > maxScreenMessages {
		return resolved{}, nil, fail(CodeBadRequest, "消息太多：最多 %d 条", maxScreenMessages)
	}
	if c.Lines != nil {
		if title == "" {
			return resolved{}, nil, fail(CodeBadRequest, "没读到当前会话名，请重新识别")
		}
		if len(c.Messages) != 0 {
			return resolved{}, nil, fail(CodeBadRequest, "画面文字和已解析消息不能同时提供")
		}
		if len(c.Lines) > maxScreenLines {
			return resolved{}, nil, fail(CodeBadRequest, "画面文字太多：最多 %d 段", maxScreenLines)
		}
		total := 0
		for _, line := range c.Lines {
			for _, v := range []float64{line.X, line.Y, line.Width, line.Height} {
				if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 || v > 1 {
					return resolved{}, nil, fail(CodeBadRequest, "画面文字坐标超出了聊天区")
				}
			}
			if line.Width <= 0 || line.Height <= 0 || line.X+line.Width > 1.000001 || line.Y+line.Height > 1.000001 {
				return resolved{}, nil, fail(CodeBadRequest, "画面文字区域无效")
			}
			total += utf8.RuneCountInString(line.Text)
			if total > maxScreenTextRunes {
				return resolved{}, nil, fail(CodeBadRequest, "画面文字过长，请缩小聊天窗口后重试")
			}
		}
	}
	switch c.Type {
	case "", "private", "group":
	default:
		return resolved{}, nil, fail(CodeBadRequest, "未知会话类型 %q", c.Type)
	}
	msgs := make([]adapter.Message, 0, len(c.Messages))
	for _, m := range c.Messages {
		m.Text = strings.TrimSpace(m.Text)
		m.Sender = strings.TrimSpace(m.Sender)
		if m.Text != "" {
			msgs = append(msgs, m)
		}
	}
	chat := adapter.Chat{ID: adapter.ID(title), Title: title, Type: c.Type}
	return resolved{chat: chat, line: title, method: "screen"}, msgs, nil
}
