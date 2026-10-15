// Package model adapts Eino's model components to the engine's text-only
// completion interface. ChatGPT account sign-in uses its own Responses client.
package model

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/cloudwego/eino-ext/components/model/openai"
	eino "github.com/cloudwego/eino/components/model"
	"github.com/cloudwego/eino/schema"
	"github.com/wyh0626/tact/engine/internal/reasoning"
)

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type Client struct {
	// Provider selects the wire protocol. Branded provider configuration is
	// resolved by config.ModelConfig.EffectiveProtocol before creating a client.
	Provider string
	// Preset identifies the service independently of its wire protocol.
	Preset      string
	BaseURL     string
	Model       string
	APIKey      string
	Temperature float64
	MaxTokens   int
	JSONMode    bool
	// ReasoningEffort and ServiceTier are left out of the request when empty.
	ReasoningEffort string
	Reasoning       *reasoning.Config
	ServiceTier     string
	ExtraBody       map[string]any
	Headers         map[string]string
	HTTP            *http.Client
}

// NewHTTPClient never follows redirects, so a misbehaving endpoint cannot
// bounce chat content to a host outside the allowlist.
func NewHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{
		Timeout: timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return errors.New("模型接口返回了重定向，已拒绝跟随")
		},
	}
}

type maxTokensKey struct{}

// WithMaxTokens raises the output limit of the requests made with ctx, for
// a reply that has to be as long as a long draft. A configured limit is
// never lowered, and no limit is never added.
func WithMaxTokens(ctx context.Context, n int) context.Context {
	return context.WithValue(ctx, maxTokensKey{}, n)
}

// MaxTokensFor is the output limit a request made with ctx uses.
func MaxTokensFor(ctx context.Context, configured int) int {
	if n, ok := ctx.Value(maxTokensKey{}).(int); ok && configured > 0 && n > configured {
		return n
	}
	return configured
}

func (c *Client) Complete(ctx context.Context, msgs []Message) (string, error) {
	if strings.TrimSpace(c.BaseURL) == "" {
		return "", errors.New("模型接口地址不能为空")
	}
	if err := c.Reasoning.Validate(c.Provider); err != nil {
		return "", fmt.Errorf("配置模型失败：%w", err)
	}
	if err := ValidateHeaders(c.Headers); err != nil {
		return "", err
	}
	limit := reasoningLimit(MaxTokensFor(ctx, c.MaxTokens), c.Reasoning)
	callCtx, cancel := completionContext(ctx, c.HTTP)
	defer cancel()
	refused := c.refused()
	for {
		httpClient, transport := completionHTTP(c.HTTP, cancel, c.Headers)
		call, sent, err := c.prepare(callCtx, httpClient, msgs, limit, refused)
		if err != nil {
			return "", fmt.Errorf("配置模型失败：%w", err)
		}
		out, finish, err := call(callCtx)
		if err == nil {
			return c.reply(out, finish, limit)
		}
		var named []string
		for _, field := range refusedFields(transport.apiError(), sent) {
			if !refused[field] {
				refused[field] = true
				named = append(named, field)
			}
		}
		if len(named) == 0 || callCtx.Err() != nil {
			return "", completionError(ctx, callCtx, transport, err)
		}
		c.remember(named)
	}
}

// completion sends one prepared request and returns its text and finish reason.
type completion func(context.Context) (out, finish string, err error)

// prepare builds the request for the configured protocol without the refused
// fields, and names the optional fields it sends.
func (c *Client) prepare(ctx context.Context, httpClient *http.Client, msgs []Message, limit int, refused map[string]bool) (completion, map[string]bool, error) {
	switch c.Provider {
	case "responses":
		return func(ctx context.Context) (string, string, error) {
			out, err := c.apiResponses(ctx, httpClient, msgs, limit)
			return out, "", err
		}, nil, nil
	case "anthropic":
		body, err := c.claudeRequest(msgs, limit, refused)
		if err != nil {
			return nil, nil, err
		}
		return func(ctx context.Context) (string, string, error) { return c.claude(ctx, httpClient, body) }, presentFields(body), nil
	case "gemini":
		body, err := c.geminiRequest(msgs, limit)
		if err != nil {
			return nil, nil, err
		}
		return func(ctx context.Context) (string, string, error) { return c.gemini(ctx, httpClient, body) }, nil, nil
	case "", "openai", "deepseek":
		chatModel, sent, err := c.openAIModel(ctx, httpClient, limit, refused)
		if err != nil {
			return nil, nil, err
		}
		messages := make([]*schema.Message, len(msgs))
		for i, msg := range msgs {
			messages[i] = &schema.Message{Role: schema.RoleType(msg.Role), Content: msg.Content}
		}
		return func(ctx context.Context) (string, string, error) {
			reply, err := chatModel.Generate(ctx, messages)
			if err != nil {
				return "", "", err
			}
			if reply == nil {
				return "", "", errors.New("模型没有返回消息")
			}
			finish := ""
			if reply.ResponseMeta != nil {
				finish = reply.ResponseMeta.FinishReason
			}
			return reply.Content, finish, nil
		}, sent, nil
	default:
		return nil, nil, fmt.Errorf("不支持的模型提供方 %q", c.Provider)
	}
}

// reply checks how a completed request finished.
func (c *Client) reply(out, finish string, limit int) (string, error) {
	if strings.TrimSpace(out) == "" && (finish == "length" || finish == "max_tokens" || finish == "MAX_TOKENS") {
		return "", fmt.Errorf("模型输出在正文前就达到了 max_tokens（%d），推理模型需要调大 model.max_tokens", limit)
	}
	if c.Provider == "gemini" && finish != "STOP" && finish != "MAX_TOKENS" {
		return "", fmt.Errorf("Gemini 没有正常完成回复（%s）", finish)
	}
	if c.Provider == "anthropic" && finish == "refusal" {
		return "", errors.New("Claude 拒绝了这次请求")
	}
	return out, nil
}

func completionError(ctx, callCtx context.Context, transport *completionTransport, err error) error {
	if ctx.Err() != nil {
		return fmt.Errorf("调用模型失败：%w", ctx.Err())
	}
	if errors.Is(callCtx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("调用模型失败：%w", context.DeadlineExceeded)
	}
	return transport.callError(err)
}

// openAIModel is a Chat Completions model for the request, and the optional
// fields it sends.
func (c *Client) openAIModel(ctx context.Context, httpClient *http.Client, limit int, refused map[string]bool) (eino.BaseChatModel, map[string]bool, error) {
	// Eino's extra fields win over typed fields. Preserve the old precedence
	// and explicit stream=false, which some compatible gateways require.
	extra := copyFields(c.ExtraBody)
	if c.Preset == "minimax" {
		// MiniMax otherwise includes <think> in content. Eino returns content
		// only; split reasoning into its own field to keep drafts reply-only.
		if _, explicit := extra["reasoning_split"]; !explicit {
			extra["reasoning_split"] = true
		}
	}
	delete(extra, "model")
	delete(extra, "messages")
	extra["temperature"] = c.Temperature
	extra["stream"] = false
	if limit > 0 {
		delete(extra, "max_tokens")
	}
	if c.JSONMode {
		extra["response_format"] = map[string]string{"type": "json_object"}
	}
	if c.ReasoningEffort != "" {
		extra["reasoning_effort"] = c.ReasoningEffort
	}
	if c.ServiceTier != "" {
		extra["service_tier"] = c.ServiceTier
	}
	reasoningFields(extra, c.Reasoning)
	if c.Reasoning != nil && (c.Reasoning.Format == "anthropic_effort" || c.Reasoning.Format == "anthropic_budget") && thinkingActive(extra) {
		// Claude accepts no temperature but its default while thinking.
		delete(extra, "temperature")
	}
	completionCap := refused[legacyTokenCap]
	if completionCap {
		// The service caps answer and reasoning together with
		// max_completion_tokens; a raw legacy cap moves there.
		if raw, exists := extra["max_tokens"]; exists {
			if _, modern := extra["max_completion_tokens"]; !modern {
				extra["max_completion_tokens"] = raw
			}
			delete(extra, "max_tokens")
		}
		if limit > 0 {
			delete(extra, "max_completion_tokens")
		}
	}
	for _, field := range optionalFields {
		if refused[field] {
			delete(extra, field)
		}
	}
	sent := presentFields(extra)
	if _, raw := extra["max_tokens"]; raw || (limit > 0 && !completionCap) {
		sent[legacyTokenCap] = true
	}
	cfg := &openai.ChatModelConfig{
		BaseURL: strings.TrimRight(c.BaseURL, "/"), Model: c.Model, APIKey: c.APIKey,
		// Sampling already lives in ExtraFields with its original float64.
		// A redundant typed temperature triggers the SDK's outdated blanket
		// validator for GPT-5 and incorrectly rejects supported none/custom calls.
		HTTPClient: httpClient, ExtraFields: extra,
	}
	if limit > 0 {
		if completionCap {
			cfg.MaxCompletionTokens = &limit
		} else {
			cfg.MaxTokens = &limit
		}
	}
	chatModel, err := openai.NewChatModel(ctx, cfg)
	return chatModel, sent, err
}

func copyFields(fields map[string]any) map[string]any {
	cloned := make(map[string]any, len(fields)+4)
	for key, value := range fields {
		cloned[key] = value
	}
	return cloned
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
