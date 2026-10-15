// Package suggest is the engine's request handler: it resolves the chat,
// fetches its recent messages, asks the model, and returns one suggestion
// bound to the newest message it saw.
package suggest

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/wyh0626/tact/engine/internal/adapter"
	"github.com/wyh0626/tact/engine/internal/chatgpt"
	"github.com/wyh0626/tact/engine/internal/config"
	"github.com/wyh0626/tact/engine/internal/feedback"
	"github.com/wyh0626/tact/engine/internal/local"
	"github.com/wyh0626/tact/engine/internal/model"
	"github.com/wyh0626/tact/engine/internal/modelcatalog"
	"github.com/wyh0626/tact/engine/internal/prompt"
	"github.com/wyh0626/tact/engine/internal/resolve"
)

const Version = "0.2.0"

// Completer is the part of the model client the service uses.
type Completer interface {
	Complete(ctx context.Context, msgs []model.Message) (string, error)
}

type Request struct {
	Op            string         `json:"op"`
	RequestID     string         `json:"request_id,omitempty"`
	PlatformID    string         `json:"platform_id,omitempty"`
	ChatID        string         `json:"chat_id,omitempty"`
	OCRLines      []resolve.Line `json:"ocr_lines,omitempty"`
	Title         string         `json:"title,omitempty"`
	Input         string         `json:"input,omitempty"`
	LastMessageID string         `json:"last_message_id,omitempty"`
	Limit         int            `json:"limit,omitempty"`
	// Screen carries the chat for a screen platform, in place of a lookup.
	Screen *ScreenChat `json:"screen,omitempty"`
	// Connection is a temporary model-list connection from the settings form.
	// Its key is used only in memory and is never stored by the engine.
	Connection *modelcatalog.Connection `json:"connection,omitempty"`

	// feedback
	Event         string `json:"event,omitempty"`
	Mode          string `json:"mode,omitempty"`
	SuggestionLen int    `json:"suggestion_len,omitempty"`
	EditDistance  *int   `json:"edit_distance,omitempty"`
	LatencyMS     int64  `json:"latency_ms,omitempty"`
	Detail        string `json:"detail,omitempty"`
}

type ChatRef struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Type  string `json:"type,omitempty"`
}

type Response struct {
	OK            bool                 `json:"ok"`
	Error         string               `json:"error,omitempty"`
	ErrorCode     string               `json:"error_code,omitempty"`
	Version       string               `json:"version,omitempty"`
	PlatformID    string               `json:"platform_id,omitempty"`
	Platforms     *[]PlatformStatus    `json:"platforms,omitempty"`
	Count         *int                 `json:"count,omitempty"`
	Chat          *ChatRef             `json:"chat,omitempty"`
	MatchedLine   string               `json:"matched_line,omitempty"`
	Method        string               `json:"method,omitempty"`
	Candidates    []string             `json:"candidates,omitempty"`
	Mode          string               `json:"mode,omitempty"`
	Suggestion    *string              `json:"suggestion,omitempty"`
	Commits       bool                 `json:"commits,omitempty"`
	NeedsCheck    bool                 `json:"needs_check,omitempty"`
	Sensitive     bool                 `json:"sensitive,omitempty"`
	LastMessageID string               `json:"last_message_id,omitempty"`
	Valid         *bool                `json:"valid,omitempty"`
	Chats         []ChatRef            `json:"chats,omitempty"`
	Messages      []adapter.Message    `json:"messages,omitempty"`
	Stats         string               `json:"stats,omitempty"`
	ChatGPT       *chatgpt.Status      `json:"chatgpt,omitempty"`
	AuthURL       string               `json:"auth_url,omitempty"`
	Models        []chatgpt.Model      `json:"models,omitempty"`
	Catalog       []modelcatalog.Model `json:"catalog,omitempty"`
	StatsData     *feedback.Numbers    `json:"stats_data,omitempty"`
	Note          string               `json:"note,omitempty"`
	TimingMS      map[string]int64     `json:"timing_ms,omitempty"`
}

// Error codes returned to the app.
const (
	CodeBadRequest          = "bad_request"
	CodeNotResolved         = "not_resolved"
	CodeAmbiguous           = "ambiguous"
	CodeDraftConflict       = "draft_conflict"
	CodeAdapter             = "adapter_error"
	CodeModel               = "model_error"
	CodeModelOutput         = "model_bad_output"
	CodeCancelled           = "cancelled"
	CodePlatformUnavailable = "platform_unavailable"
	CodePlatformRequired    = "platform_required"
	CodeDraftTooLong        = "draft_too_long"
)

type codedError struct {
	code       string
	msg        string
	candidates []string
	line       string
}

func (e *codedError) Error() string { return e.msg }

func fail(code, format string, args ...any) *codedError {
	return &codedError{code: code, msg: fmt.Sprintf(format, args...)}
}

type Service struct {
	cfg          config.Config
	adapter      adapter.Adapter
	model        Completer
	log          *feedback.Logger
	platformID   string
	platforms    *platformRegistry
	capabilities map[string]bool
	now          func() time.Time

	mu      sync.Mutex
	chats   []adapter.Chat
	chatsAt time.Time

	// chatgpt manages the ChatGPT sign-in; nil when not configured.
	chatgpt *chatgpt.Manager
	// local runs the downloaded model; nil unless the provider is "local".
	local *local.Server

	histMu    sync.Mutex
	histories map[adapter.ID]historyEntry
	fetching  map[adapter.ID]*historyFetch

	screenMu sync.Mutex
	screens  map[string]*Service
}

type historyEntry struct {
	msgs []adapter.Message
	at   time.Time
}

type historyFetch struct {
	done chan struct{}
	msgs []adapter.Message
	err  error
}

// Prefetched messages are dropped after this, so chat text does not linger
// in memory for chats the user has left.
const historyRetention = 5 * time.Minute

func New(cfg config.Config, a adapter.Adapter, m Completer, log *feedback.Logger) *Service {
	return &Service{cfg: cfg, adapter: a, model: m, log: log, now: time.Now,
		histories: map[adapter.ID]historyEntry{}, fetching: map[adapter.ID]*historyFetch{}}
}

// NewFromConfig wires the configured chat tool plugins and the model.
func NewFromConfig(cfg config.Config) *Service {
	temp := 0.3
	if cfg.Model.Temperature != nil {
		temp = *cfg.Model.Temperature
	}
	key := ""
	if cfg.Model.APIKeyEnv != "" {
		key = os.Getenv(cfg.Model.APIKeyEnv)
	}
	signIn := chatgpt.NewManager(filepath.Join(config.Dir(), "chatgpt.json"))
	httpClient := model.NewHTTPClient(time.Duration(cfg.Model.TimeoutMS) * time.Millisecond)
	var m Completer
	var localServer *local.Server
	if cfg.Model.Provider == "chatgpt" {
		m = &model.ResponsesClient{BaseURL: cfg.Model.BaseURL, Model: cfg.Model.Model,
			ReasoningEffort: cfg.Model.ReasoningEffort, ServiceTier: cfg.Model.ServiceTier,
			Token: signIn.AccessToken, HTTP: httpClient}
	} else if cfg.Model.Provider == "local" {
		localServer = newLocalServer(cfg.Model)
		m = &localModel{server: localServer, client: model.Client{
			Model:       cfg.Model.Model,
			Temperature: temp,
			MaxTokens:   cfg.Model.MaxTokens,
			JSONMode:    cfg.Model.JSONMode,
			ExtraBody:   cfg.Model.ExtraBody,
			HTTP:        httpClient,
		}}
	} else {
		m = &model.Client{
			Provider:        cfg.Model.EffectiveProtocol(),
			Preset:          cfg.Model.Provider,
			BaseURL:         cfg.Model.BaseURL,
			Model:           cfg.Model.Model,
			APIKey:          key,
			Temperature:     temp,
			MaxTokens:       cfg.Model.MaxTokens,
			JSONMode:        cfg.Model.JSONMode,
			ReasoningEffort: cfg.Model.ReasoningEffort,
			Reasoning:       cfg.Model.Reasoning,
			ServiceTier:     cfg.Model.ServiceTier,
			ExtraBody:       cfg.Model.ExtraBody,
			Headers:         cfg.Model.Headers,
			HTTP:            httpClient,
		}
	}
	// Chat requests always go to a plugin; the service itself reads no chat.
	svc := New(cfg, noChatTool{}, m, feedback.NewLogger(cfg.Feedback.File, cfg.Feedback.LogPlaintext))
	svc.chatgpt = signIn
	svc.local = localServer
	svc.configurePlatforms(cfg.Platforms)
	return svc
}

func (s *Service) Handle(ctx context.Context, req Request) Response {
	switch req.Op {
	case "ping":
		return Response{OK: true, Version: Version}
	case "platforms":
		statuses := s.platformStatuses()
		return Response{OK: true, Platforms: &statuses}
	case "chats", "platform_test", "resolve", "history", "suggest", "prepare", "check", "feedback":
		if screen := s.screenService(req.PlatformID); screen != nil {
			resp := screen.handleScreen(ctx, req)
			resp.PlatformID = req.PlatformID
			return resp
		}
		if req.Screen != nil {
			return errorResponse(fail(CodeBadRequest, "只有内置平台接受屏幕上读到的会话"))
		}
		selectPlatform := s.selectPlatform
		if req.Op == "platform_test" {
			selectPlatform = s.selectTestPlatform
		}
		selected, err := selectPlatform(req.PlatformID)
		if err != nil {
			resp := errorResponse(err)
			resp.PlatformID = req.PlatformID
			return resp
		}
		req.PlatformID = selected.platformID
		resp := selected.handlePlatform(ctx, req)
		resp.PlatformID = selected.platformID
		return resp
	case "stats":
		sum, err := feedback.Stats(s.cfg.Feedback.File)
		if err != nil {
			return errorResponse(fail(CodeBadRequest, "读取反馈日志失败：%v", err))
		}
		numbers := sum.Numbers()
		return Response{OK: true, Stats: sum.String(), StatsData: &numbers}
	case "model_test":
		return s.modelTest(ctx)
	case "model_catalog":
		return s.modelCatalog(ctx, req.Connection)
	case "chatgpt_status", "chatgpt_login", "chatgpt_logout", "chatgpt_models":
		return s.chatgptOp(ctx, req.Op)
	default:
		return errorResponse(fail(CodeBadRequest, "未知操作 %q", req.Op))
	}
}

func (s *Service) modelCatalog(ctx context.Context, input *modelcatalog.Connection) Response {
	if input == nil {
		return errorResponse(fail(CodeBadRequest, "获取模型列表需要 connection 设置"))
	}
	connection := *input
	selected := config.ModelConfig{Provider: connection.Provider, Protocol: connection.Protocol}
	connection.Protocol = selected.EffectiveProtocol()
	if connection.APIKey == "" && connection.Provider == s.cfg.Model.Provider &&
		connection.Protocol == s.cfg.Model.EffectiveProtocol() && sameModelOrigin(connection.BaseURL, s.cfg.Model.BaseURL) {
		// Changing the endpoint or protocol must never forward the saved key.
		connection.APIKey = os.Getenv(s.cfg.Model.APIKeyEnv)
	}
	client := model.NewHTTPClient(time.Duration(s.cfg.Model.TimeoutMS) * time.Millisecond)
	models, err := modelcatalog.Discover(ctx, connection, client)
	if err != nil {
		return errorResponse(err)
	}
	return Response{OK: true, Catalog: models}
}

func sameModelOrigin(a, b string) bool {
	left, err := url.Parse(strings.TrimSpace(a))
	if err != nil || left.Host == "" || left.User != nil {
		return false
	}
	right, err := url.Parse(strings.TrimSpace(b))
	if err != nil || right.Host == "" || right.User != nil {
		return false
	}
	port := func(u *url.URL) string {
		if p := u.Port(); p != "" {
			if n, err := strconv.Atoi(p); err == nil {
				return strconv.Itoa(n)
			}
			return p
		}
		if strings.EqualFold(u.Scheme, "https") {
			return "443"
		}
		return "80"
	}
	return strings.EqualFold(left.Scheme, right.Scheme) &&
		strings.EqualFold(left.Hostname(), right.Hostname()) && port(left) == port(right)
}

func errorResponse(err error) Response {
	var ce *codedError
	if errors.As(err, &ce) {
		return Response{OK: false, Error: ce.msg, ErrorCode: ce.code, Candidates: ce.candidates, MatchedLine: ce.line}
	}
	if errors.Is(err, context.Canceled) {
		return Response{OK: false, Error: "请求已取消", ErrorCode: CodeCancelled}
	}
	return Response{OK: false, Error: err.Error(), ErrorCode: CodeBadRequest}
}

func (s *Service) getChats(ctx context.Context, force bool) ([]adapter.Chat, error) {
	ttl := time.Duration(s.cfg.Adapter.ChatsCacheSeconds) * time.Second
	s.mu.Lock()
	if !force && ttl > 0 && s.chats != nil && s.now().Sub(s.chatsAt) < ttl {
		chats := s.chats
		s.mu.Unlock()
		return chats, nil
	}
	s.mu.Unlock()

	chats, err := s.adapter.Chats(ctx)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.chats, s.chatsAt = chats, s.now()
	s.mu.Unlock()
	return chats, nil
}

func ref(c adapter.Chat) *ChatRef {
	return &ChatRef{ID: string(c.ID), Title: c.Title, Type: c.Type}
}

func (s *Service) listChats(ctx context.Context) Response {
	chats, err := s.getChats(ctx, true)
	if err != nil {
		return errorResponse(fail(CodeAdapter, "读取会话列表失败：%v", err))
	}
	out := make([]ChatRef, 0, len(chats))
	for _, c := range chats {
		out = append(out, *ref(c))
	}
	return Response{OK: true, Chats: out}
}

type resolved struct {
	chat   adapter.Chat
	line   string
	method string
}

func (s *Service) resolveChat(ctx context.Context, req Request) (resolved, error) {
	if req.ChatID != "" {
		for _, force := range []bool{false, true} {
			chats, err := s.getChats(ctx, force)
			if err != nil {
				return resolved{}, fail(CodeAdapter, "读取会话列表失败：%v", err)
			}
			for _, c := range chats {
				if string(c.ID) == req.ChatID {
					return resolved{chat: c, method: "chat_id"}, nil
				}
			}
		}
		// Not in the list; still usable as an ID.
		return resolved{chat: adapter.Chat{ID: adapter.ID(req.ChatID)}, method: "chat_id"}, nil
	}

	lines := req.OCRLines
	if len(lines) == 0 && strings.TrimSpace(req.Title) != "" {
		lines = []resolve.Line{{Text: req.Title, Height: 1}}
	}
	if len(lines) == 0 {
		return resolved{}, fail(CodeBadRequest, "需要 chat_id、ocr_lines 或 title 之一")
	}

	var lastErr error
	for _, force := range []bool{false, true} {
		chats, err := s.getChats(ctx, force)
		if err != nil {
			return resolved{}, fail(CodeAdapter, "读取会话列表失败：%v", err)
		}
		r, err := resolve.Resolve(lines, chats)
		if err == nil {
			return resolved{chat: r.Chat, line: r.Line, method: r.Method}, nil
		}
		lastErr = err
		var amb *resolve.AmbiguousError
		if errors.As(err, &amb) {
			e := fail(CodeAmbiguous, "%s", amb.Error())
			e.candidates, e.line = amb.Titles, amb.Line
			return resolved{}, e
		}
		// Not found: refresh the chat list once in case the chat is new.
	}
	top := resolve.Headline(lines)
	e := fail(CodeNotResolved, "没认出当前会话（识别到「%s」）：%v", top, lastErr)
	e.line = top
	return resolved{}, e
}

func (s *Service) resolveOp(ctx context.Context, req Request) Response {
	r, err := s.resolveChat(ctx, req)
	if err != nil {
		return errorResponse(err)
	}
	return Response{OK: true, Chat: ref(r.chat), MatchedLine: r.line, Method: r.method}
}

func (s *Service) history(ctx context.Context, req Request) Response {
	r, err := s.resolveChat(ctx, req)
	if err != nil {
		return errorResponse(err)
	}
	limit := req.Limit
	if limit <= 0 {
		limit = s.cfg.Context.HistoryLimit
	}
	msgs, err := s.adapter.History(ctx, string(r.chat.ID), limit)
	if err != nil {
		return errorResponse(fail(CodeAdapter, "读取消息失败：%v", err))
	}
	return Response{OK: true, Chat: ref(r.chat), Messages: msgs}
}

// normalizeInput treats non-breaking spaces (⌥Space) as whitespace.
func normalizeInput(s string) string {
	return strings.TrimSpace(strings.ReplaceAll(s, " ", " "))
}

func (s *Service) suggest(ctx context.Context, req Request) Response {
	start := s.now()
	timing := map[string]int64{}
	since := func(t time.Time) int64 { return s.now().Sub(t).Milliseconds() }

	input := normalizeInput(req.Input)
	mode := "complete"
	if input != "" {
		mode = "rewrite"
	}
	logBase := feedback.Event{RequestID: req.RequestID, PlatformID: s.platformID, Mode: mode, InputLen: len([]rune(input)), Input: input}
	logError := func(err error) Response {
		resp := errorResponse(err)
		if resp.ErrorCode != CodeCancelled {
			e := logBase
			e.Event, e.ErrorCode = "error", resp.ErrorCode
			if s.cfg.Feedback.LogPlaintext {
				e.Detail = resp.Error
			}
			e.Chat = s.hashChat(req.ChatID)
			_ = s.log.Append(e)
		}
		return resp
	}

	if n := utf8.RuneCountInString(input); n > prompt.MaxDraftRunes {
		return logError(fail(CodeDraftTooLong, "草稿有 %d 字，超过 %d 字，先分成几条再改写", n, prompt.MaxDraftRunes))
	}
	var r resolved
	var screenMsgs []adapter.Message
	var err error
	if req.Screen != nil {
		r, screenMsgs, err = req.Screen.resolved()
	} else {
		r, err = s.resolveChat(ctx, req)
	}
	timing["resolve"] = since(start)
	if err != nil {
		return logError(err)
	}
	logBase.Chat = s.hashChat(string(r.chat.ID))

	if input != "" {
		if conflict := s.draftConflict(ctx, r.chat, input); conflict != "" {
			return logError(fail(CodeDraftConflict, "输入框内容和会话「%s」的草稿一致，当前会话可能认错了", conflict))
		}
	}

	t := s.now()
	msgs, cached := screenMsgs, false
	if req.Screen == nil {
		maxAge := time.Duration(s.cfg.Context.HistoryCacheSeconds) * time.Second
		msgs, cached, err = s.recentHistory(ctx, r.chat.ID, maxAge)
	}
	timing["history"] = since(t)
	if cached {
		timing["history_cached"] = 1
	}
	if err != nil {
		if ctx.Err() != nil {
			return errorResponse(ctx.Err())
		}
		return logError(fail(CodeAdapter, "读取消息失败：%v", err))
	}

	resp := Response{OK: true, Chat: ref(r.chat), MatchedLine: r.line, Method: r.method, Mode: mode, TimingMS: timing}
	if len(msgs) > 0 {
		resp.LastMessageID = string(msgs[len(msgs)-1].ID)
	}
	var screenLines []prompt.ScreenLine
	if req.Screen != nil && req.Screen.Lines != nil {
		screenLines = make([]prompt.ScreenLine, 0, len(req.Screen.Lines))
		for _, line := range req.Screen.Lines {
			line.Text = strings.TrimSpace(line.Text)
			if line.Text != "" {
				screenLines = append(screenLines, line)
			}
		}
	}
	if len(msgs) == 0 && len(screenLines) == 0 && input == "" {
		resp.Note = "这个会话没有消息"
		timing["total"] = since(start)
		e := logBase
		e.Event, e.Detail, e.LatencyMS = "empty", "no_messages", timing["total"]
		_ = s.log.Append(e)
		return resp
	}

	msgsPrompt := s.promptFor(r.chat, msgs, input, screenLines...)
	t = s.now()
	limit := s.cfg.Context.MaxSuggestionChars
	modelCtx := ctx
	if prompt.IsLongDraft(input) {
		// A rewrite of a long draft is as long as the draft.
		n := utf8.RuneCountInString(input)
		limit = max(limit, 2*n)
		modelCtx = model.WithMaxTokens(ctx, 3*n+300)
	}
	raw, err := s.model.Complete(modelCtx, msgsPrompt)
	timing["model"] = since(t)
	if err != nil {
		if ctx.Err() != nil {
			return errorResponse(ctx.Err())
		}
		return logError(fail(CodeModel, "%v", err))
	}
	out, err := prompt.Parse(raw)
	if err != nil {
		return logError(fail(CodeModelOutput, "%v", err))
	}
	if out.Suggestion != nil {
		if cleaned, ok := prompt.Clean(*out.Suggestion, limit); ok {
			resp.Suggestion = &cleaned
			resp.Commits = out.Commits
			resp.NeedsCheck = out.NeedsCheck
			resp.Sensitive = prompt.Sensitive(cleaned)
		}
	}
	timing["total"] = since(start)

	e := logBase
	e.LatencyMS = timing["total"]
	if resp.Suggestion != nil {
		e.Event = "generated"
		e.SuggestionLen = len([]rune(*resp.Suggestion))
		e.Suggestion = *resp.Suggestion
		e.Commits, e.NeedsCheck, e.Sensitive = resp.Commits, resp.NeedsCheck, resp.Sensitive
	} else {
		e.Event, e.Detail = "empty", "model_declined"
	}
	_ = s.log.Append(e)
	return resp
}

// chatgptOp drives the ChatGPT sign-in for the settings window. The engine
// owns the sign-in so that token refreshes and requests share one lock.
func (s *Service) chatgptOp(ctx context.Context, op string) Response {
	if s.chatgpt == nil {
		return errorResponse(fail(CodeBadRequest, "这个引擎没有启用 ChatGPT 登录"))
	}
	switch op {
	case "chatgpt_login":
		authURL, err := s.chatgpt.StartLogin()
		if err != nil {
			return errorResponse(fail(CodeBadRequest, "%v", err))
		}
		return Response{OK: true, AuthURL: authURL}
	case "chatgpt_logout":
		revoked, err := s.chatgpt.Logout(ctx)
		if err != nil {
			return errorResponse(fail(CodeBadRequest, "%v", err))
		}
		resp := Response{OK: true}
		if !revoked {
			resp.Note = "本机的登录信息已清除，但没能确认 OpenAI 那边已吊销。可以在 ChatGPT 设置里断开这个应用"
		}
		return resp
	case "chatgpt_models":
		models, err := s.chatgpt.Models(ctx)
		if err != nil {
			return errorResponse(fail(CodeModel, "%v", err))
		}
		return Response{OK: true, Models: models}
	default:
		status, err := s.chatgpt.Status()
		if err != nil {
			return errorResponse(fail(CodeBadRequest, "%v", err))
		}
		return Response{OK: true, ChatGPT: &status}
	}
}

// Warm loads the chat list in the background when the engine starts, so the
// first trigger does not wait for it.
func (s *Service) Warm(ctx context.Context) {
	if s.local != nil {
		// Loading the model takes seconds; do it before the first request.
		go func() {
			if _, _, err := s.local.Endpoint(ctx); err != nil && ctx.Err() == nil {
				fmt.Fprintf(os.Stderr, "本机模型预热失败：%v\n", err)
			}
		}()
	}
	if s.platforms != nil {
		for _, entry := range s.platforms.entries {
			if entry.service != nil {
				entry.service.Warm(ctx)
			}
		}
		return
	}
	if _, err := s.getChats(ctx, false); err != nil && ctx.Err() == nil {
		fmt.Fprintf(os.Stderr, "预热会话列表失败：%v\n", err)
	}
}

// modelTest sends a one-word prompt with the configured model settings, for
// the "test connection" button.
func (s *Service) modelTest(ctx context.Context) Response {
	start := s.now()
	out, err := s.model.Complete(ctx, []model.Message{{Role: "user", Content: "只回复两个字母：OK"}})
	elapsed := s.now().Sub(start).Milliseconds()
	if err != nil {
		if ctx.Err() != nil {
			return errorResponse(ctx.Err())
		}
		return errorResponse(fail(CodeModel, "%v", err))
	}
	reply := strings.TrimSpace(out)
	if reply == "" {
		return errorResponse(fail(CodeModelOutput, "模型返回了空回复"))
	}
	if r := []rune(reply); len(r) > 40 {
		reply = string(r[:40]) + "…"
	}
	return Response{OK: true, Note: reply, TimingMS: map[string]int64{"model": elapsed}}
}

// prepare resolves the chat and fetches its messages ahead of a suggest, so
// that pressing the hotkey only waits for the model.
func (s *Service) prepare(ctx context.Context, req Request) Response {
	start := s.now()
	r, err := s.resolveChat(ctx, req)
	if err != nil {
		return errorResponse(err)
	}
	msgs, _, err := s.recentHistory(ctx, r.chat.ID, 0)
	if err != nil {
		if ctx.Err() != nil {
			return errorResponse(ctx.Err())
		}
		return errorResponse(fail(CodeAdapter, "读取消息失败：%v", err))
	}
	resp := Response{OK: true, Chat: ref(r.chat), MatchedLine: r.line, Method: r.method,
		TimingMS: map[string]int64{"total": s.now().Sub(start).Milliseconds()}}
	if len(msgs) > 0 {
		resp.LastMessageID = string(msgs[len(msgs)-1].ID)
		// A local model reads the prompt now, while nobody is waiting, so
		// the hotkey only waits for what changed by then.
		if warm, ok := s.model.(prewarmer); ok {
			go func(msgs []model.Message) {
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
				defer cancel()
				warm.Prewarm(ctx, msgs)
			}(s.promptFor(r.chat, msgs, ""))
		}
	}
	return resp
}

// prewarmer is a model that can read a prompt ahead of the request.
type prewarmer interface {
	Prewarm(ctx context.Context, msgs []model.Message)
}

// promptFor builds the prompt for a chat. A prefetch and the request after
// it build it the same way, so a local model's prefetched reading matches.
func (s *Service) promptFor(chat adapter.Chat, msgs []adapter.Message, intent string, screenLines ...prompt.ScreenLine) []model.Message {
	return prompt.Build(prompt.Input{
		Chat:            chat,
		Messages:        msgs,
		ScreenLines:     screenLines,
		ScreenApp:       screenPlatforms[s.platformID],
		Intent:          intent,
		Style:           s.styleFor(chat),
		Now:             s.now(),
		MaxMessageChars: s.cfg.Context.MaxMessageChars,
		AppendNoThink:   s.cfg.Model.AppendNoThink,
	})
}

// recentHistory returns the chat's messages from the cache when they are
// younger than maxAge, and otherwise fetches them. A fetch already running
// for the chat (usually a prefetch) is joined rather than repeated. The fetch
// is not tied to ctx so that a cancelled request does not waste it for the
// next one; the adapter's own timeout bounds it.
func (s *Service) recentHistory(ctx context.Context, chatID adapter.ID, maxAge time.Duration) ([]adapter.Message, bool, error) {
	s.histMu.Lock()
	if e, ok := s.histories[chatID]; ok && maxAge > 0 && s.now().Sub(e.at) < maxAge {
		s.histMu.Unlock()
		return e.msgs, true, nil
	}
	f, running := s.fetching[chatID]
	if !running {
		f = &historyFetch{done: make(chan struct{})}
		s.fetching[chatID] = f
		go s.fetchHistory(chatID, f)
	}
	s.histMu.Unlock()

	select {
	case <-f.done:
		return f.msgs, false, f.err
	case <-ctx.Done():
		return nil, false, ctx.Err()
	}
}

func (s *Service) fetchHistory(chatID adapter.ID, f *historyFetch) {
	msgs, err := s.adapter.History(context.Background(), string(chatID), s.cfg.Context.HistoryLimit)
	now := s.now()
	s.histMu.Lock()
	delete(s.fetching, chatID)
	if err == nil {
		s.histories[chatID] = historyEntry{msgs: msgs, at: now}
	}
	for id, e := range s.histories {
		if now.Sub(e.at) > historyRetention {
			delete(s.histories, id)
		}
	}
	s.histMu.Unlock()
	f.msgs, f.err = msgs, err
	close(f.done)
}

// draftConflict returns the title of another chat whose saved draft equals
// the current input, which means the header was matched to the wrong chat.
// Drafts are optional; any adapter error just skips the check.
func (s *Service) draftConflict(ctx context.Context, chat adapter.Chat, input string) string {
	if s.capabilities != nil && !s.capabilities["composer.read"] {
		return ""
	}
	drafts, err := s.adapter.Drafts(ctx)
	if err != nil {
		return ""
	}
	var owners []adapter.ID
	for _, d := range drafts {
		if normalizeInput(d.Text) == input {
			owners = append(owners, d.ChatID)
		}
	}
	if len(owners) != 1 || owners[0] == chat.ID {
		return ""
	}
	if chats, err := s.getChats(ctx, false); err == nil {
		for _, c := range chats {
			if c.ID == owners[0] {
				return c.Title
			}
		}
	}
	return string(owners[0])
}

func (s *Service) styleFor(chat adapter.Chat) string {
	if s.cfg.Style.File == "" {
		return ""
	}
	data, err := os.ReadFile(s.cfg.Style.File)
	if err != nil {
		return ""
	}
	section := s.cfg.Style.DefaultSection
	if v, ok := s.cfg.Style.ChatSections[string(chat.ID)]; ok {
		section = v
	} else if v, ok := s.cfg.Style.ChatSections[chat.Title]; ok {
		section = v
	}
	return prompt.StyleSection(string(data), section)
}

func (s *Service) check(ctx context.Context, req Request) Response {
	if req.ChatID == "" {
		return errorResponse(fail(CodeBadRequest, "check 需要 chat_id"))
	}
	msgs, err := s.adapter.History(ctx, req.ChatID, 1)
	if err != nil {
		return errorResponse(fail(CodeAdapter, "读取消息失败：%v", err))
	}
	latest := ""
	if len(msgs) > 0 {
		latest = string(msgs[len(msgs)-1].ID)
	}
	valid := latest == req.LastMessageID
	return Response{OK: true, Valid: &valid, LastMessageID: latest}
}

var appEvents = map[string]bool{"shown": true, "accepted": true, "dismissed": true, "voided": true, "sent": true}

func (s *Service) feedback(req Request) Response {
	if !appEvents[req.Event] {
		return errorResponse(fail(CodeBadRequest, "未知反馈事件 %q", req.Event))
	}
	err := s.log.Append(feedback.Event{
		RequestID:     req.RequestID,
		PlatformID:    s.platformID,
		Event:         req.Event,
		Chat:          s.hashChat(req.ChatID),
		Mode:          req.Mode,
		SuggestionLen: req.SuggestionLen,
		LatencyMS:     req.LatencyMS,
		EditDistance:  req.EditDistance,
		Detail:        req.Detail,
	})
	if err != nil {
		return errorResponse(fail(CodeBadRequest, "写反馈日志失败：%v", err))
	}
	return Response{OK: true}
}

func (s *Service) hashChat(id string) string {
	if id == "" || s.platformID == "" {
		return feedback.HashChat(id)
	}
	return feedback.HashChat(fmt.Sprintf("%d:%s%s", len(s.platformID), s.platformID, id))
}

// Close stops what the service started: the local model's server.
func (s *Service) Close() {
	if s.local != nil {
		s.local.Stop()
	}
}
