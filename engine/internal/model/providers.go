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
)

// Claude and Gemini are called over their HTTP APIs directly. Their SDKs
// would bring AWS Bedrock, Vertex and Google Cloud clients into the engine
// (tens of MB), and read credentials from ANTHROPIC_* and GOOGLE_*
// environment variables beside the configured key.

func (c *Client) nativeSettings() error {
	if strings.TrimSpace(c.APIKey) == "" {
		return errors.New("原生模型接口需要 API Key，请在设置里保存或设置 model.api_key_env 对应的环境变量")
	}
	if c.ReasoningEffort != "" || c.ServiceTier != "" {
		return errors.New("原生 Claude/Gemini 请在模型设置界面或 model.reasoning 设置推理，原生扩展参数使用 model.extra_body；不能使用通用 reasoning_effort 或 service_tier")
	}
	return nil
}

// claudeRequest is the Messages API request without the refused fields, or
// why it cannot be sent.
func (c *Client) claudeRequest(msgs []Message, limit int, refused map[string]bool) (map[string]any, error) {
	if err := c.nativeSettings(); err != nil {
		return nil, err
	}
	if c.JSONMode {
		return nil, errors.New("Claude 原生接口不支持 model.json_mode；结构化输出请通过 model.extra_body.output_config 配置 JSON schema")
	}
	if limit <= 0 {
		return nil, errors.New("Claude 原生接口需要大于 0 的 model.max_tokens")
	}
	body := copyFields(c.ExtraBody)
	reasoningFields(body, c.Reasoning)
	for key := range body {
		// extra_body names top-level API fields; a key shaped like a JSON
		// path is a mistake that would reach the API as a stray field.
		if strings.ContainsAny(key, ".|\\:#[]") {
			return nil, errors.New("Claude 的 model.extra_body 只能使用顶层字段，嵌套参数请写成 JSON 对象，不能使用 JSON 路径")
		}
	}
	for _, key := range []string{"model", "messages", "system", "temperature", "max_tokens", "stream"} {
		delete(body, key)
	}
	if !thinkingActive(body) {
		body["temperature"] = c.Temperature
	}
	for _, field := range optionalFields {
		if refused[field] {
			delete(body, field)
		}
	}
	var system, messages []map[string]any
	for _, msg := range msgs {
		text := []map[string]any{{"type": "text", "text": msg.Content}}
		if msg.Role == "system" {
			system = append(system, text[0])
			continue
		}
		messages = append(messages, map[string]any{"role": msg.Role, "content": text})
	}
	body["model"] = c.Model
	body["max_tokens"] = limit
	body["messages"] = messages
	if len(system) > 0 {
		body["system"] = system
	}
	return body, nil
}

// claude sends a Messages API request and returns its text and stop reason.
func (c *Client) claude(ctx context.Context, client *http.Client, body map[string]any) (string, string, error) {
	base := strings.TrimSuffix(strings.TrimRight(c.BaseURL, "/"), "/v1")
	data, err := c.postNative(ctx, client, base+"/v1/messages", body, map[string]string{
		"X-Api-Key": c.APIKey, "Anthropic-Version": "2023-06-01",
	})
	if err != nil {
		return "", "", err
	}
	var reply struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		StopReason string `json:"stop_reason"`
	}
	if err := json.Unmarshal(data, &reply); err != nil {
		return "", "", fmt.Errorf("Claude 回复看不懂：%w", err)
	}
	var text strings.Builder
	for _, part := range reply.Content {
		if part.Type == "text" {
			text.WriteString(part.Text)
		}
	}
	return text.String(), reply.StopReason, nil
}

// geminiRequest is the generateContent request, or why it cannot be sent.
func (c *Client) geminiRequest(msgs []Message, limit int) (map[string]any, error) {
	if err := c.nativeSettings(); err != nil {
		return nil, err
	}
	body := copyFields(c.ExtraBody)
	reasoningFields(body, c.Reasoning)
	for _, key := range []string{"model", "contents", "systemInstruction"} {
		delete(body, key)
	}
	// extra_body may carry native generation settings (thinking, schemas);
	// only the fields Tact owns are replaced.
	generation := nestedFields(body, "generationConfig")
	generation["temperature"] = c.Temperature
	if limit > 0 {
		generation["maxOutputTokens"] = limit
	}
	if c.JSONMode {
		generation["responseMimeType"] = "application/json"
	}
	body["generationConfig"] = generation
	var system, contents []map[string]any
	for _, msg := range msgs {
		part := map[string]any{"text": msg.Content}
		switch msg.Role {
		case "system":
			system = append(system, part)
		case "assistant":
			contents = append(contents, map[string]any{"role": "model", "parts": []map[string]any{part}})
		default:
			contents = append(contents, map[string]any{"role": msg.Role, "parts": []map[string]any{part}})
		}
	}
	body["contents"] = contents
	if len(system) > 0 {
		body["systemInstruction"] = map[string]any{"role": "system", "parts": system}
	}
	return body, nil
}

// gemini sends a generateContent request and returns its text, without
// thought summaries, and its finish reason.
func (c *Client) gemini(ctx context.Context, client *http.Client, body map[string]any) (string, string, error) {
	base := strings.TrimRight(c.BaseURL, "/")
	version := "v1beta"
	for _, suffix := range []string{"/v1beta", "/v1"} {
		if strings.HasSuffix(base, suffix) {
			version = strings.TrimPrefix(suffix, "/")
			base = strings.TrimSuffix(base, suffix)
			break
		}
	}
	model := strings.TrimPrefix(c.Model, "models/")
	data, err := c.postNative(ctx, client, base+"/"+version+"/models/"+model+":generateContent", body,
		map[string]string{"X-Goog-Api-Key": c.APIKey})
	if err != nil {
		return "", "", err
	}
	var reply struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text    string `json:"text"`
					Thought bool   `json:"thought"`
				} `json:"parts"`
			} `json:"content"`
			FinishReason string `json:"finishReason"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(data, &reply); err != nil {
		return "", "", fmt.Errorf("Gemini 回复看不懂：%w", err)
	}
	if len(reply.Candidates) == 0 {
		return "", "", errors.New("gemini result is empty")
	}
	candidate := reply.Candidates[0]
	var text strings.Builder
	for _, part := range candidate.Content.Parts {
		if !part.Thought {
			text.WriteString(part.Text)
		}
	}
	return text.String(), candidate.FinishReason, nil
}

// postNative posts a JSON body with the native API's headers and returns a
// successful reply's body. The client's transport bounds the reply and
// records any failure status for the caller's message.
func (c *Client) postNative(ctx context.Context, client *http.Client, endpoint string, body map[string]any, auth map[string]string) ([]byte, error) {
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("模型参数不是合法 JSON：%w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	for name, value := range auth {
		req.Header.Set(name, value)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, parseAPIError(resp.StatusCode, data)
	}
	return data, nil
}
