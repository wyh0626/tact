package model

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
)

// TokenSource returns a bearer token that is valid right now.
type TokenSource func(ctx context.Context) (string, error)

// ResponsesClient calls the Responses API with a ChatGPT sign-in token, so
// requests are billed to the user's ChatGPT plan. That route requires
// store=false and stream=true, takes the system prompt as `instructions`,
// and rejects sampling parameters such as temperature and max_output_tokens.
type ResponsesClient struct {
	BaseURL string
	Model   string
	// ReasoningEffort and ServiceTier are left out of the request when empty.
	ReasoningEffort string
	ServiceTier     string
	Token           TokenSource
	HTTP            *http.Client
}

// APIError is an error response from the model endpoint, kept with its code
// so the user gets the recovery the code calls for.
type APIError struct {
	Status  int
	Code    string
	Message string
	Param   string
}

func (e *APIError) Error() string {
	switch e.Code {
	case "subscription_sharing_usage_limit_exceeded":
		return "ChatGPT 套餐的用量到上限了，可以在 chatgpt.com/settings/usage 查看或调整这个应用的额度"
	case "subscription_sharing_usage_unavailable":
		return "暂时查不到 ChatGPT 套餐的用量，稍后再试"
	case "subscription_sharing_user_unavailable":
		return "ChatGPT 暂时不可用，稍后再试"
	case "subscription_sharing_user_not_eligible":
		return "这个 ChatGPT 账号不能在第三方应用里使用套餐额度"
	case "subscription_sharing_invalid_user":
		return "ChatGPT 没有接受这个登录，请在设置里退出后重新登录"
	case "subscription_sharing_unsupported_capability":
		return fmt.Sprintf("ChatGPT 套餐不支持请求里的参数 %s", e.Param)
	}
	if e.Status == http.StatusUnauthorized {
		return "ChatGPT 登录已失效，请在设置里重新登录"
	}
	detail := strings.TrimSpace(strings.Join(nonEmpty(e.Code, e.Message), " "))
	if detail == "" {
		return fmt.Sprintf("模型接口返回 HTTP %d", e.Status)
	}
	return fmt.Sprintf("模型接口返回 HTTP %d：%s", e.Status, truncate(detail, 300))
}

func nonEmpty(xs ...string) []string {
	var out []string
	for _, x := range xs {
		if x != "" {
			out = append(out, x)
		}
	}
	return out
}

type responsesInput struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

func (c *ResponsesClient) Complete(ctx context.Context, msgs []Message) (string, error) {
	token, err := c.Token(ctx)
	if err != nil {
		return "", err
	}
	var instructions []string
	var input []responsesInput
	for _, m := range msgs {
		if m.Role == "system" {
			instructions = append(instructions, m.Content)
			continue
		}
		input = append(input, responsesInput{Role: m.Role, Content: m.Content})
	}
	body := map[string]any{
		"model":        c.Model,
		"instructions": strings.Join(instructions, "\n\n"),
		"input":        input,
		"store":        false,
		"stream":       true,
	}
	if c.ReasoningEffort != "" {
		body["reasoning"] = map[string]string{"effort": c.ReasoningEffort}
	}
	if c.ServiceTier != "" {
		body["service_tier"] = c.ServiceTier
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(c.BaseURL, "/")+"/responses", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+token)
	httpClient := c.HTTP
	if httpClient == nil {
		httpClient = NewHTTPClient(30 * time.Second)
	}
	start := time.Now()
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("调用模型失败：%w", err)
	}
	defer resp.Body.Close()
	answered := time.Since(start)
	if resp.StatusCode/100 != 2 {
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		return "", parseAPIError(resp.StatusCode, data)
	}
	text, spent, err := readResponseStream(resp.Body)
	if err == nil {
		log.Print(spent.describe(c.Model, start, answered))
	}
	return text, err
}

// streamSpend is when a reply's text began and what the model spent on
// it: where the wait for a suggestion went.
type streamSpend struct {
	firstText       time.Time
	outputTokens    int
	reasoningTokens int
}

// describe sizes and times only, never the text, for the engine log.
func (s streamSpend) describe(model string, start time.Time, answered time.Duration) string {
	first := "无"
	if !s.firstText.IsZero() {
		first = s.firstText.Sub(start).Round(time.Millisecond).String()
	}
	return fmt.Sprintf("模型 %s：%v 收到响应，%s 开始出字，%v 写完；思考 %d tokens，输出 %d tokens", model,
		answered.Round(time.Millisecond), first, time.Since(start).Round(time.Millisecond), s.reasoningTokens, s.outputTokens)
}

func parseAPIError(status int, data []byte) *APIError {
	e := &APIError{Status: status}
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Type    string `json:"type"`
			Message string `json:"message"`
			Param   string `json:"param"`
		} `json:"error"`
	}
	if json.Unmarshal(data, &body) == nil {
		e.Code, e.Message, e.Param = body.Error.Code, body.Error.Message, body.Error.Param
		if e.Code == "" {
			e.Code = body.Error.Type
		}
	} else {
		e.Message = string(bytes.TrimSpace(data))
	}
	return e
}

// readResponseStream collects the output text from a Responses event stream.
// Only response.completed counts as success; a stream that ends before it,
// or reports failure, is an error even if some text arrived.
func readResponseStream(r io.Reader) (string, streamSpend, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64<<10), 4<<20)
	var text strings.Builder
	var spent streamSpend
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "" || data == "[DONE]" {
			continue
		}
		var ev struct {
			Type     string `json:"type"`
			Delta    string `json:"delta"`
			Response struct {
				Error *struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
				IncompleteDetails *struct {
					Reason string `json:"reason"`
				} `json:"incomplete_details"`
				Usage *struct {
					OutputTokens        int `json:"output_tokens"`
					OutputTokensDetails struct {
						ReasoningTokens int `json:"reasoning_tokens"`
					} `json:"output_tokens_details"`
				} `json:"usage"`
			} `json:"response"`
			Code    string `json:"code"`
			Message string `json:"message"`
		}
		if err := json.Unmarshal([]byte(data), &ev); err != nil {
			continue
		}
		switch ev.Type {
		case "response.output_text.delta":
			if spent.firstText.IsZero() {
				spent.firstText = time.Now()
			}
			text.WriteString(ev.Delta)
		case "response.completed":
			if u := ev.Response.Usage; u != nil {
				spent.outputTokens, spent.reasoningTokens = u.OutputTokens, u.OutputTokensDetails.ReasoningTokens
			}
			return text.String(), spent, nil
		case "response.failed":
			e := &APIError{Status: http.StatusOK}
			if ev.Response.Error != nil {
				e.Code, e.Message = ev.Response.Error.Code, ev.Response.Error.Message
			}
			return "", spent, e
		case "response.incomplete":
			reason := "未知原因"
			if ev.Response.IncompleteDetails != nil && ev.Response.IncompleteDetails.Reason != "" {
				reason = ev.Response.IncompleteDetails.Reason
			}
			return "", spent, fmt.Errorf("模型回复不完整：%s", reason)
		case "error":
			return "", spent, &APIError{Status: http.StatusOK, Code: ev.Code, Message: ev.Message}
		}
	}
	if err := scanner.Err(); err != nil {
		return "", spent, fmt.Errorf("读取模型回复失败：%w", err)
	}
	return "", spent, errors.New("模型回复在完成前中断了")
}
