// Package modelcatalog reads model names and declared capabilities from the
// configured model endpoint. It never infers capabilities from a model ID.
package modelcatalog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/wyh0626/tact/engine/internal/model"
)

const (
	maxBodyBytes = 4 << 20
	maxModels    = 2000
	maxPages     = 10
)

// Connection may describe an unsaved connection. APIKey is only sent to its
// BaseURL, never to a public catalog or a pagination URL returned by a server.
type Connection struct {
	Provider string            `json:"provider"`
	Protocol string            `json:"protocol"`
	BaseURL  string            `json:"base_url"`
	APIKey   string            `json:"api_key,omitempty"`
	Headers  map[string]string `json:"headers,omitempty"`
}

type Model struct {
	ID           string        `json:"id"`
	Name         string        `json:"name"`
	Capabilities *Capabilities `json:"capabilities,omitempty"`
}

// Pointer fields distinguish an unknown capability from an explicit false or
// empty list. A client may fill unknown fields from its fallback catalog.
type Capabilities struct {
	Source             string    `json:"source"`
	ReasoningSupported *bool     `json:"reasoning_supported,omitempty"`
	ReasoningFormat    string    `json:"reasoning_format,omitempty"`
	EffortLevels       *[]string `json:"effort_levels,omitempty"`
	ThinkingTypes      *[]string `json:"thinking_types,omitempty"`
	CanDisable         *bool     `json:"can_disable,omitempty"`
	BudgetMin          *int      `json:"budget_min,omitempty"`
	BudgetMax          *int      `json:"budget_max,omitempty"`
	MaxOutputTokens    *int      `json:"max_output_tokens,omitempty"`
}

// Discover performs bounded, non-redirecting GET requests. The supplied client
// is cloned, so discovery does not change the caller's transport or policy.
func Discover(ctx context.Context, connection Connection, client *http.Client) ([]Model, error) {
	protocol, endpoint, err := connection.endpoint()
	if err != nil {
		return nil, err
	}
	if err := model.ValidateHeaders(connection.Headers); err != nil {
		return nil, err
	}
	if strings.ContainsAny(connection.APIKey, "\r\n") {
		return nil, errors.New("API Key 不能包含换行")
	}
	timeout := 30 * time.Second
	if client != nil && client.Timeout > 0 {
		timeout = client.Timeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var httpClient http.Client
	if client != nil {
		httpClient = *client
	}
	httpClient.Timeout = 0
	httpClient.CheckRedirect = func(*http.Request, []*http.Request) error {
		return errors.New("模型列表接口不允许重定向")
	}

	result := make([]Model, 0)
	seenModels := make(map[string]bool)
	seenCursors := make(map[string]bool)
	cursor := ""
	for page := 0; page < maxPages; page++ {
		pageURL := *endpoint
		query := pageURL.Query()
		switch protocol {
		case "anthropic":
			query.Set("limit", "1000")
			if cursor != "" {
				query.Set("after_id", cursor)
			}
		case "gemini":
			query.Set("pageSize", "1000")
			if cursor != "" {
				query.Set("pageToken", cursor)
			}
		}
		pageURL.RawQuery = query.Encode()
		body, err := getPage(ctx, &httpClient, pageURL.String(), protocol, connection)
		if err != nil {
			return nil, err
		}
		models, nextCursor, err := parsePage(protocol, connection.Provider, body)
		if err != nil {
			return nil, err
		}
		for _, item := range models {
			if seenModels[item.ID] {
				continue
			}
			seenModels[item.ID] = true
			if len(result) >= maxModels {
				return nil, errors.New("模型列表超过 2000 项，请使用手动填写模型")
			}
			result = append(result, item)
		}
		if nextCursor == "" {
			return result, nil
		}
		if len(nextCursor) > 4096 || seenCursors[nextCursor] {
			return nil, errors.New("模型列表分页信息无效")
		}
		seenCursors[nextCursor] = true
		cursor = nextCursor
	}
	return nil, errors.New("模型列表分页过多，请使用手动填写模型")
}

func (c Connection) endpoint() (string, *url.URL, error) {
	if c.Provider == "chatgpt" || c.Provider == "local" {
		return "", nil, errors.New("ChatGPT 账号和本机模型请使用各自的模型列表")
	}
	protocol := c.Protocol
	if protocol == "" {
		protocol = "openai"
		if c.Provider == "anthropic" || c.Provider == "gemini" {
			protocol = c.Provider
		}
	}
	u, err := url.Parse(strings.TrimSpace(c.BaseURL))
	if err != nil || u == nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" {
		return "", nil, errors.New("模型接口地址必须是 HTTP(S) 地址，且不能包含账号、查询参数或片段")
	}
	u.Path = strings.TrimRight(u.Path, "/")
	u.RawPath = ""
	switch protocol {
	case "openai", "responses":
		u.Path += "/models"
	case "anthropic":
		u.Path = strings.TrimSuffix(u.Path, "/v1") + "/v1/models"
	case "gemini":
		if !strings.HasSuffix(u.Path, "/v1beta") && !strings.HasSuffix(u.Path, "/v1") {
			u.Path += "/v1beta"
		}
		u.Path += "/models"
	default:
		return "", nil, errors.New("不支持的模型接口协议")
	}
	return protocol, u, nil
}

func getPage(ctx context.Context, client *http.Client, endpoint, protocol string, connection Connection) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, errors.New("无法创建模型列表请求")
	}
	for name, value := range connection.Headers {
		req.Header.Set(name, value)
	}
	req.Header.Set("Accept", "application/json")
	switch protocol {
	case "anthropic":
		req.Header.Set("anthropic-version", "2023-06-01")
		if connection.APIKey != "" {
			req.Header.Set("x-api-key", connection.APIKey)
		}
	case "gemini":
		if connection.APIKey != "" {
			req.Header.Set("x-goog-api-key", connection.APIKey)
		}
	default:
		if connection.APIKey != "" {
			req.Header.Set("Authorization", "Bearer "+connection.APIKey)
		}
	}
	response, err := client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("获取模型列表失败：%w", ctx.Err())
		}
		// Do not echo transport URLs or a gateway body, which may contain keys.
		return nil, errors.New("无法连接模型列表接口，请检查接口地址与网络")
	}
	defer response.Body.Close()
	if response.StatusCode/100 != 2 {
		return nil, fmt.Errorf("模型列表接口返回 HTTP %d，请检查接口地址、API Key 与权限", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, maxBodyBytes+1))
	if err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("读取模型列表失败：%w", ctx.Err())
		}
		return nil, errors.New("读取模型列表失败")
	}
	if len(body) > maxBodyBytes {
		return nil, errors.New("模型列表响应超过 4 MiB")
	}
	if !json.Valid(body) {
		return nil, errors.New("模型列表响应不是合法的单个 JSON 文档")
	}
	return body, nil
}
