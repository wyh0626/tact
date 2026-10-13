// Package model calls an OpenAI-compatible /chat/completions endpoint, such
// as Ollama (http://127.0.0.1:11434/v1) or a company gateway.
package model

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type Client struct {
	BaseURL     string
	Model       string
	APIKey      string
	Temperature float64
	MaxTokens   int
	JSONMode    bool
	// ReasoningEffort and ServiceTier are left out of the request when empty.
	ReasoningEffort string
	ServiceTier     string
	ExtraBody       map[string]any
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
	body := make(map[string]any, len(c.ExtraBody)+6)
	for k, v := range c.ExtraBody {
		body[k] = v
	}
	// The fields below always win over extra_body, so it cannot redirect the
	// model, the messages or streaming.
	for k, v := range map[string]any{
		"model":       c.Model,
		"messages":    msgs,
		"temperature": c.Temperature,
		"stream":      false,
	} {
		body[k] = v
	}
	limit := MaxTokensFor(ctx, c.MaxTokens)
	if limit > 0 {
		body["max_tokens"] = limit
	}
	if c.JSONMode {
		body["response_format"] = map[string]string{"type": "json_object"}
	}
	if c.ReasoningEffort != "" {
		body["reasoning_effort"] = c.ReasoningEffort
	}
	if c.ServiceTier != "" {
		body["service_tier"] = c.ServiceTier
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	endpoint := strings.TrimSuffix(c.BaseURL, "/") + "/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}
	httpClient := c.HTTP
	if httpClient == nil {
		httpClient = NewHTTPClient(30 * time.Second)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("调用模型失败：%w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return "", fmt.Errorf("读取模型响应失败：%w", err)
	}
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("模型接口返回 HTTP %d：%s", resp.StatusCode, truncate(strings.TrimSpace(string(data)), 300))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
			FinishReason string `json:"finish_reason"`
		} `json:"choices"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return "", fmt.Errorf("模型响应不是预期的格式：%w", err)
	}
	if len(out.Choices) == 0 {
		return "", errors.New("模型响应里没有 choices")
	}
	choice := out.Choices[0]
	// Reasoning models spend max_tokens on hidden thinking first; when that
	// runs out the visible answer is empty, which must not pass as a reply.
	if strings.TrimSpace(choice.Message.Content) == "" && choice.FinishReason == "length" {
		return "", fmt.Errorf("模型输出在正文前就达到了 max_tokens（%d），推理模型需要调大 model.max_tokens", limit)
	}
	return choice.Message.Content, nil
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
