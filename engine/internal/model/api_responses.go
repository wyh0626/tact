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

// apiResponses is the API-key JSON Responses protocol. The pinned Eino OpenAI
// component implements Chat Completions only. This small adapter shares its
// bounded, single-attempt HTTP policy and does not use ChatGPT account tokens.
func (c *Client) apiResponses(ctx context.Context, client *http.Client, msgs []Message, limit int) (string, error) {
	body := copyFields(c.ExtraBody)
	for _, key := range []string{"messages", "max_tokens", "reasoning_effort", "response_format"} {
		delete(body, key)
	}
	var instructions []string
	input := make([]responsesInput, 0, len(msgs))
	for _, msg := range msgs {
		if msg.Role == "system" {
			instructions = append(instructions, msg.Content)
			continue
		}
		input = append(input, responsesInput{Role: msg.Role, Content: msg.Content})
	}
	body["model"] = c.Model
	body["instructions"] = strings.Join(instructions, "\n\n")
	body["input"] = input
	body["stream"] = false
	body["store"] = false
	if limit > 0 {
		body["max_output_tokens"] = limit
	}
	// Sampling stays at the service default because reasoning models may reject
	// it. Advanced parameters can explicitly enable sampling on supported models.
	if c.JSONMode {
		text := nestedFields(body, "text")
		text["format"] = map[string]string{"type": "json_object"}
		body["text"] = text
	}
	reasoningBody := nestedFields(body, "reasoning")
	if c.ReasoningEffort != "" {
		reasoningBody["effort"] = c.ReasoningEffort
	}
	if c.Reasoning != nil {
		delete(reasoningBody, "effort")
		if c.Reasoning.Effort != "" {
			reasoningBody["effort"] = c.Reasoning.Effort
		}
	}
	putNestedFields(body, "reasoning", reasoningBody)
	if c.ServiceTier != "" {
		body["service_tier"] = c.ServiceTier
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return "", fmt.Errorf("模型参数不是合法 JSON：%w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+"/responses", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode/100 != 2 {
		return "", parseAPIError(resp.StatusCode, data)
	}
	return responseText(data, limit)
}

func responseText(data []byte, limit int) (string, error) {
	var response struct {
		Status string `json:"status"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
		IncompleteDetails *struct {
			Reason string `json:"reason"`
		} `json:"incomplete_details"`
		Output []struct {
			Type    string `json:"type"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"output"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return "", fmt.Errorf("解析 Responses 回复失败：%w", err)
	}
	if response.Error != nil {
		return "", fmt.Errorf("Responses 调用失败：%s", truncate(response.Error.Message, 300))
	}
	if response.Status == "incomplete" {
		reason := ""
		if response.IncompleteDetails != nil {
			reason = response.IncompleteDetails.Reason
		}
		if reason == "max_output_tokens" {
			return "", fmt.Errorf("模型输出达到了 max_output_tokens（%d），请调大 model.max_tokens", limit)
		}
		return "", fmt.Errorf("Responses 回复不完整（%s）", truncate(reason, 100))
	}
	if response.Status != "completed" {
		return "", fmt.Errorf("Responses 没有正常完成回复（%s）", truncate(response.Status, 100))
	}
	var text strings.Builder
	for _, output := range response.Output {
		if output.Type != "message" {
			continue
		}
		for _, part := range output.Content {
			if part.Type == "refusal" {
				return "", errors.New("模型拒绝了这次请求")
			}
			if part.Type == "output_text" {
				text.WriteString(part.Text)
			}
		}
	}
	if strings.TrimSpace(text.String()) == "" {
		return "", errors.New("Responses 没有返回正文")
	}
	return text.String(), nil
}
