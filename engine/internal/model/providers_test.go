package model

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const claudeOK = `{"id":"msg_test","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"native OK"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2}}`
const geminiOK = `{"candidates":[{"content":{"role":"model","parts":[{"text":"native OK"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":2,"totalTokenCount":6}}`

type nativeRequest struct {
	path   string
	header http.Header
	body   map[string]any
}

func nativeServer(t *testing.T, response string) (*httptest.Server, <-chan nativeRequest) {
	t.Helper()
	requests := make(chan nativeRequest, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method = %s, want POST", r.Method)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode native request: %v", err)
		}
		requests <- nativeRequest{path: r.URL.Path, header: r.Header.Clone(), body: body}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(response))
	}))
	t.Cleanup(srv.Close)
	return srv, requests
}

func TestClaudeNativeProtocolAndProtectedFields(t *testing.T) {
	t.Parallel()
	srv, requests := nativeServer(t, claudeOK)
	extra := map[string]any{
		"model": "wrong", "messages": []any{}, "system": "wrong", "stream": true,
		"temperature": 1, "max_tokens": 1,
		"thinking": map[string]any{"type": "disabled"},
		"metadata": map[string]any{"user_id": "local-test"},
	}
	before, _ := json.Marshal(extra)
	c := &Client{Provider: "anthropic", BaseURL: srv.URL, Model: "claude-test", APIKey: "test-anthropic-key",
		MaxTokens: 300, Temperature: 0, ExtraBody: extra}
	msgs := []Message{{Role: "system", Content: "用中文回复。"}, {Role: "user", Content: "native prompt"}}
	got, err := c.Complete(WithMaxTokens(context.Background(), 900), msgs)
	if err != nil || got != "native OK" {
		t.Fatalf("Complete = %q, %v", got, err)
	}
	req := <-requests
	if req.path != "/v1/messages" {
		t.Errorf("path = %q, want /v1/messages", req.path)
	}
	if req.header.Get("X-Api-Key") != c.APIKey || req.header.Get("Anthropic-Version") == "" {
		t.Errorf("native authentication/version headers missing: %v", req.header)
	}
	if req.header.Get("Authorization") != "" {
		t.Errorf("unexpected ambient Authorization header: %v", req.header)
	}
	for key, want := range map[string]any{"model": c.Model, "temperature": float64(0), "max_tokens": float64(900),
		"thinking": map[string]any{"type": "disabled"}, "metadata": map[string]any{"user_id": "local-test"}} {
		if !reflect.DeepEqual(req.body[key], want) {
			t.Errorf("%s = %#v, want %#v", key, req.body[key], want)
		}
	}
	if stream, exists := req.body["stream"]; exists && stream != false {
		t.Errorf("stream = %#v, want omitted or false", stream)
	}
	wantSystem := []any{map[string]any{"type": "text", "text": "用中文回复。"}}
	wantMessages := []any{map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": "native prompt"}}}}
	if !reflect.DeepEqual(req.body["system"], wantSystem) || !reflect.DeepEqual(req.body["messages"], wantMessages) {
		t.Errorf("system/messages = %#v / %#v", req.body["system"], req.body["messages"])
	}
	after, _ := json.Marshal(extra)
	if string(after) != string(before) {
		t.Errorf("Complete mutated ExtraBody: before %s, after %s", before, after)
	}
}

func TestGeminiNativeProtocolAndProtectedFields(t *testing.T) {
	t.Parallel()
	srv, requests := nativeServer(t, geminiOK)
	extra := map[string]any{
		"model": "wrong", "contents": []any{}, "systemInstruction": map[string]any{"parts": []any{}},
		"generationConfig": map[string]any{"temperature": 1, "maxOutputTokens": 1, "responseMimeType": "text/plain",
			"thinkingConfig": map[string]any{"thinkingBudget": 0}},
	}
	before, _ := json.Marshal(extra)
	c := &Client{Provider: "gemini", BaseURL: srv.URL, Model: "gemini-test", APIKey: "test-gemini-key",
		MaxTokens: 300, JSONMode: true, Temperature: 0, ExtraBody: extra}
	msgs := []Message{{Role: "system", Content: "用中文回复。"}, {Role: "user", Content: "native prompt"}, {Role: "assistant", Content: "previous reply"}}
	got, err := c.Complete(WithMaxTokens(context.Background(), 900), msgs)
	if err != nil || got != "native OK" {
		t.Fatalf("Complete = %q, %v", got, err)
	}
	req := <-requests
	if req.path != "/v1beta/models/gemini-test:generateContent" {
		t.Errorf("path = %q", req.path)
	}
	if req.header.Get("X-Goog-Api-Key") != c.APIKey {
		t.Errorf("X-Goog-Api-Key = %q", req.header.Get("X-Goog-Api-Key"))
	}
	wantGeneration := map[string]any{"temperature": float64(0), "maxOutputTokens": float64(900),
		"responseMimeType": "application/json", "thinkingConfig": map[string]any{"thinkingBudget": float64(0)}}
	if !reflect.DeepEqual(req.body["generationConfig"], wantGeneration) {
		t.Errorf("generationConfig = %#v, want %#v", req.body["generationConfig"], wantGeneration)
	}
	wantSystem := map[string]any{"role": "system", "parts": []any{map[string]any{"text": "用中文回复。"}}}
	wantContents := []any{
		map[string]any{"role": "user", "parts": []any{map[string]any{"text": "native prompt"}}},
		map[string]any{"role": "model", "parts": []any{map[string]any{"text": "previous reply"}}},
	}
	if !reflect.DeepEqual(req.body["systemInstruction"], wantSystem) || !reflect.DeepEqual(req.body["contents"], wantContents) {
		t.Errorf("systemInstruction/contents = %#v / %#v", req.body["systemInstruction"], req.body["contents"])
	}
	if _, exists := req.body["model"]; exists {
		t.Errorf("extra_body injected model: %#v", req.body)
	}
	after, _ := json.Marshal(extra)
	if string(after) != string(before) {
		t.Errorf("Complete mutated nested ExtraBody: before %s, after %s", before, after)
	}
}

func TestNativeVersionedBaseURL(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		provider, suffix, path, response string
	}{
		{"anthropic", "/v1/", "/v1/messages", claudeOK},
		{"anthropic", "/gateway/v1/", "/gateway/v1/messages", claudeOK},
		{"gemini", "/v1beta/", "/v1beta/models/native-test:generateContent", geminiOK},
		{"gemini", "/v1/", "/v1/models/native-test:generateContent", geminiOK},
		{"gemini", "/gateway/v1beta/", "/gateway/v1beta/models/native-test:generateContent", geminiOK},
	} {
		t.Run(tt.provider+tt.suffix, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, tt.response)
			c := &Client{Provider: tt.provider, BaseURL: srv.URL + tt.suffix, Model: "native-test", APIKey: "test-key", MaxTokens: 20}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
				t.Fatal(err)
			}
			if req := <-requests; req.path != tt.path {
				t.Errorf("path = %q, want %q", req.path, tt.path)
			}
		})
	}
}

func TestNativeEmptyTruncationAndMissingResult(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name, provider, response, wantError string
	}{
		{"claude truncation", "anthropic", `{"id":"msg_test","type":"message","role":"assistant","content":[],"stop_reason":"max_tokens","usage":{"input_tokens":1,"output_tokens":20}}`, "max_tokens（20）"},
		{"gemini truncation", "gemini", `{"candidates":[{"content":{"role":"model","parts":[]},"finishReason":"MAX_TOKENS"}]}`, "max_tokens（20）"},
		{"gemini missing candidates", "gemini", `{}`, "gemini result is empty"},
		{"gemini safety block", "gemini", `{"candidates":[{"finishReason":"SAFETY"}]}`, "SAFETY"},
		{"gemini recitation block", "gemini", `{"candidates":[{"finishReason":"RECITATION"}]}`, "RECITATION"},
		{"gemini partial safety block", "gemini", `{"candidates":[{"content":{"role":"model","parts":[{"text":"unsafe partial"}]},"finishReason":"SAFETY"}]}`, "SAFETY"},
		{"claude refusal", "anthropic", `{"id":"msg_test","type":"message","role":"assistant","content":[{"type":"text","text":"refused"}],"stop_reason":"refusal","usage":{"input_tokens":1,"output_tokens":2}}`, "Claude 拒绝"},
		{"claude invalid JSON", "anthropic", `{`, "调用模型失败"},
		{"gemini invalid JSON", "gemini", `{`, "调用模型失败"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srv, _ := nativeServer(t, tt.response)
			c := &Client{Provider: tt.provider, BaseURL: srv.URL, Model: "native-test", APIKey: "test-key", MaxTokens: 20}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err == nil || !strings.Contains(err.Error(), tt.wantError) {
				t.Fatalf("error = %v, want containing %q", err, tt.wantError)
			}
		})
	}
}

func TestClaudeRejectsExtraBodyJSONPaths(t *testing.T) {
	t.Parallel()
	for _, key := range []string{"messages.0.content", "messages|0", "messages\\.0", "messages:#", "messages[0]", "messages]", "metadata.#"} {
		t.Run(key, func(t *testing.T) {
			t.Parallel()
			var calls atomic.Int32
			client := &http.Client{Transport: nativeRoundTripFunc(func(*http.Request) (*http.Response, error) {
				calls.Add(1)
				return nil, errors.New("unexpected network request")
			})}
			c := &Client{Provider: "anthropic", BaseURL: "https://native.invalid", Model: "native-test", APIKey: "test-key",
				MaxTokens: 20, HTTP: client, ExtraBody: map[string]any{key: "replacement"}}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "keep original"}}); err == nil || !strings.Contains(err.Error(), "JSON 路径") {
				t.Errorf("error = %v, want rejected extra_body JSON path %q", err, key)
			}
			if got := calls.Load(); got != 0 {
				t.Errorf("transport attempts = %d, want 0", got)
			}
		})
	}
}

func TestNativeOutputLimitStaysPerRequest(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		provider, response string
	}{
		{"anthropic", claudeOK}, {"gemini", geminiOK},
	} {
		t.Run(tt.provider, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, tt.response)
			c := &Client{Provider: tt.provider, BaseURL: srv.URL, Model: "native-test", APIKey: "test-key", MaxTokens: 300}
			for _, call := range []struct{ override, want int }{{900, 900}, {100, 300}, {0, 300}} {
				ctx := context.Background()
				if call.override != 0 {
					ctx = WithMaxTokens(ctx, call.override)
				}
				if _, err := c.Complete(ctx, []Message{{Role: "user", Content: "hi"}}); err != nil {
					t.Fatal(err)
				}
				req := <-requests
				got := req.body["max_tokens"]
				if tt.provider == "gemini" {
					generation, _ := req.body["generationConfig"].(map[string]any)
					got = generation["maxOutputTokens"]
				}
				if got != float64(call.want) {
					t.Errorf("override %d: output limit = %v, want %d", call.override, got, call.want)
				}
			}
		})
	}
}

type nativeRoundTripFunc func(*http.Request) (*http.Response, error)

func (f nativeRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestNativeDoesNotRetryStatusOrNetworkFailures(t *testing.T) {
	t.Parallel()
	for _, provider := range []string{"anthropic", "gemini"} {
		t.Run(provider+" status 429", func(t *testing.T) {
			t.Parallel()
			var calls atomic.Int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls.Add(1)
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("X-Should-Retry", "true")
				w.Header().Set("Retry-After", "0")
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = w.Write([]byte(`{"error":{"message":"local rate limit"}}`))
			}))
			t.Cleanup(srv.Close)
			c := &Client{Provider: provider, BaseURL: srv.URL, Model: "native-test", APIKey: "test-key", MaxTokens: 20}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if _, err := c.Complete(ctx, []Message{{Role: "user", Content: "hi"}}); err == nil || !strings.Contains(err.Error(), "HTTP 429") {
				t.Errorf("error = %v, want HTTP 429", err)
			}
			if got := calls.Load(); got != 1 {
				t.Errorf("HTTP attempts = %d, want 1", got)
			}
		})
		t.Run(provider+" network failure", func(t *testing.T) {
			t.Parallel()
			var calls atomic.Int32
			failure := errors.New("local simulated network failure")
			httpClient := &http.Client{Transport: nativeRoundTripFunc(func(*http.Request) (*http.Response, error) {
				calls.Add(1)
				return nil, failure
			})}
			c := &Client{Provider: provider, BaseURL: "https://native.invalid", Model: "native-test", APIKey: "test-key", MaxTokens: 20, HTTP: httpClient}
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if _, err := c.Complete(ctx, []Message{{Role: "user", Content: "hi"}}); !errors.Is(err, failure) {
				t.Errorf("error = %v, want original network failure", err)
			}
			if got := calls.Load(); got != 1 {
				t.Errorf("transport attempts = %d, want 1", got)
			}
		})
	}
}

func TestNativeSettingsRejectBeforeRequest(t *testing.T) {
	// Ambient SDK authentication must never silently select a different key.
	t.Setenv("ANTHROPIC_API_KEY", "ambient-anthropic-key")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "ambient-anthropic-token")
	t.Setenv("GEMINI_API_KEY", "ambient-gemini-key")
	t.Setenv("GOOGLE_API_KEY", "ambient-google-key")
	for _, tt := range []struct {
		name, provider, key, effort, tier string
		max                               int
		json                              bool
		want                              string
	}{
		{name: "claude missing key", provider: "anthropic", max: 20, want: "API Key"},
		{name: "gemini missing key", provider: "gemini", max: 20, want: "API Key"},
		{name: "claude whitespace key", provider: "anthropic", key: "  ", max: 20, want: "API Key"},
		{name: "claude JSON mode", provider: "anthropic", key: "test-key", max: 20, json: true, want: "json_mode"},
		{name: "claude unlimited", provider: "anthropic", key: "test-key", want: "max_tokens"},
		{name: "claude reasoning option", provider: "anthropic", key: "test-key", max: 20, effort: "high", want: "reasoning_effort"},
		{name: "gemini service tier", provider: "gemini", key: "test-key", max: 20, tier: "priority", want: "service_tier"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var calls atomic.Int32
			httpClient := &http.Client{Transport: nativeRoundTripFunc(func(*http.Request) (*http.Response, error) {
				calls.Add(1)
				return nil, errors.New("unexpected network request")
			})}
			c := &Client{Provider: tt.provider, BaseURL: "https://native.invalid", Model: "native-test", APIKey: tt.key,
				MaxTokens: tt.max, JSONMode: tt.json, ReasoningEffort: tt.effort, ServiceTier: tt.tier, HTTP: httpClient}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %v, want containing %q", err, tt.want)
			}
			if got := calls.Load(); got != 0 {
				t.Errorf("transport attempts = %d, want 0", got)
			}
		})
	}
}

// Credentials other tools keep in the environment never reach the API: only
// the configured key is sent.
func TestNativeIgnoresAmbientCredentials(t *testing.T) {
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "ambient-anthropic-token")
	t.Setenv("ANTHROPIC_API_KEY", "ambient-anthropic-key")
	t.Setenv("GOOGLE_API_KEY", "ambient-google-key")
	for _, tt := range []struct{ provider, response, header string }{
		{"anthropic", claudeOK, "X-Api-Key"}, {"gemini", geminiOK, "X-Goog-Api-Key"},
	} {
		srv, requests := nativeServer(t, tt.response)
		c := &Client{Provider: tt.provider, BaseURL: srv.URL, Model: "native-test", APIKey: "configured-key", MaxTokens: 20}
		if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
			t.Fatal(err)
		}
		req := <-requests
		if req.header.Get(tt.header) != "configured-key" || req.header.Get("Authorization") != "" {
			t.Errorf("%s headers = %v", tt.provider, req.header)
		}
	}
}
