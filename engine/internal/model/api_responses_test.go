package model

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wyh0626/tact/engine/internal/reasoning"
)

const apiResponsesOK = `{"status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"API "},{"type":"output_text","text":"OK"}]}]}`

func TestAPIResponsesWireAndAdvancedParameters(t *testing.T) {
	t.Parallel()
	srv, requests := nativeServer(t, apiResponsesOK)
	extra := map[string]any{
		"model": "wrong", "input": "wrong", "instructions": "wrong", "stream": true, "store": true,
		"max_output_tokens": 1, "max_tokens": 1, "messages": "wrong",
		"reasoning":   map[string]any{"effort": "high", "summary": "auto"},
		"text":        map[string]any{"verbosity": "low", "format": map[string]string{"type": "text"}},
		"temperature": 0.7, "metadata": map[string]string{"purpose": "test"},
	}
	before, err := json.Marshal(extra)
	if err != nil {
		t.Fatal(err)
	}
	c := &Client{Provider: "responses", BaseURL: srv.URL + "/v1/", APIKey: "responses-test-key", Model: "manual-model",
		MaxTokens: 300, JSONMode: true, ReasoningEffort: "high", Reasoning: &reasoning.Config{Format: "openai", Effort: "low"},
		ServiceTier: "priority", Headers: map[string]string{"OpenAI-Organization": "test-org"}, ExtraBody: extra}
	msgs := []Message{{Role: "system", Content: "system 1"}, {Role: "user", Content: "question"}, {Role: "system", Content: "system 2"}}
	got, err := c.Complete(WithMaxTokens(context.Background(), 900), msgs)
	if err != nil || got != "API OK" {
		t.Fatalf("Complete = %q, %v", got, err)
	}
	req := <-requests
	if req.path != "/v1/responses" || req.header.Get("Authorization") != "Bearer responses-test-key" || req.header.Get("OpenAI-Organization") != "test-org" {
		t.Fatalf("wrong path or authentication/extension headers: %s", req.path)
	}
	want := map[string]any{
		"model": "manual-model", "instructions": "system 1\n\nsystem 2", "stream": false, "store": false,
		"max_output_tokens": float64(900), "temperature": 0.7, "service_tier": "priority",
		"reasoning": map[string]any{"effort": "low", "summary": "auto"},
		"text":      map[string]any{"verbosity": "low", "format": map[string]any{"type": "json_object"}},
		"metadata":  map[string]any{"purpose": "test"},
		"input":     []any{map[string]any{"role": "user", "content": "question"}},
	}
	if !reflect.DeepEqual(req.body, want) {
		t.Errorf("body = %#v, want %#v", req.body, want)
	}
	after, err := json.Marshal(extra)
	if err != nil || string(after) != string(before) {
		t.Fatal("request mutated advanced parameters")
	}
}

func TestAPIResponsesReasoningDefaultPreservesUnrelatedParameters(t *testing.T) {
	t.Parallel()
	srv, requests := nativeServer(t, apiResponsesOK)
	c := &Client{Provider: "responses", BaseURL: srv.URL, Model: "manual-model", ReasoningEffort: "high",
		Reasoning: &reasoning.Config{Format: "reasoning"}, ExtraBody: map[string]any{"reasoning": map[string]any{"effort": "high", "summary": "auto"}}}
	if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil {
		t.Fatal(err)
	}
	req := <-requests
	if !reflect.DeepEqual(req.body["reasoning"], map[string]any{"summary": "auto"}) {
		t.Errorf("reasoning = %#v", req.body["reasoning"])
	}
	if _, ok := req.body["temperature"]; ok {
		t.Fatal("reasoning API should use default sampling unless explicitly set in advanced parameters")
	}
}

func TestAPIResponsesFailures(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, body, want string
		status           int
	}{
		{name: "refusal", body: `{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}`, want: "拒绝"},
		{name: "empty", body: `{"status":"completed","output":[]}`, want: "正文"},
		{name: "incomplete tokens", body: `{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}`, want: "max_output_tokens"},
		{name: "incomplete filtered", body: `{"status":"incomplete","incomplete_details":{"reason":"content_filter"}}`, want: "content_filter"},
		{name: "failure", body: `{"status":"failed","error":{"message":"wire failure"}}`, want: "wire failure"},
		{name: "pending", body: `{"status":"in_progress"}`, want: "in_progress"},
		{name: "invalid JSON", body: `{"status":"completed"} {}`, want: "JSON"},
		{name: "oversized", body: `{"oversized":"` + strings.Repeat("x", 4<<20) + `"}`, want: "request body too large"},
		{name: "HTTP failure", status: http.StatusTooManyRequests, body: `{"error":{"message":"rate limited"}}`, want: "HTTP 429"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var count atomic.Int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				count.Add(1)
				if tc.status != 0 {
					w.WriteHeader(tc.status)
				}
				_, _ = io.WriteString(w, tc.body)
			}))
			defer srv.Close()
			c := &Client{Provider: "responses", BaseURL: srv.URL, Model: "m", MaxTokens: 300}
			got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}})
			if err == nil || !strings.Contains(err.Error(), tc.want) || got != "" {
				t.Fatalf("Complete = %q, %v; want error %q", got, err, tc.want)
			}
			if count.Load() != 1 {
				t.Fatalf("requests = %d, want no retries", count.Load())
			}
		})
	}
}

func TestAPIResponsesDeadlineAndRedirect(t *testing.T) {
	t.Parallel()
	t.Run("deadline covers response body", func(t *testing.T) {
		t.Parallel()
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		}))
		defer srv.Close()
		c := &Client{Provider: "responses", BaseURL: srv.URL, Model: "m", HTTP: NewHTTPClient(30 * time.Millisecond)}
		_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}})
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("Complete error = %v, want deadline", err)
		}
	})
	t.Run("redirect is refused", func(t *testing.T) {
		t.Parallel()
		var targetCalls atomic.Int32
		target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { targetCalls.Add(1) }))
		defer target.Close()
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, target.URL, http.StatusTemporaryRedirect)
		}))
		defer srv.Close()
		c := &Client{Provider: "responses", BaseURL: srv.URL, APIKey: "private-test-key", Model: "m", HTTP: &http.Client{}}
		_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}})
		if err == nil || targetCalls.Load() != 0 {
			t.Fatalf("error = %v, target requests = %d", err, targetCalls.Load())
		}
	})
}

func TestExtensionHeadersAllProtocols(t *testing.T) {
	t.Parallel()
	cases := []struct{ protocol, response, authHeader string }{
		{"openai", `{"choices":[{"message":{"content":"native OK"},"finish_reason":"stop"}]}`, "Authorization"},
		{"anthropic", claudeOK, "X-Api-Key"},
		{"gemini", geminiOK, "X-Goog-Api-Key"},
		{"responses", apiResponsesOK, "Authorization"},
	}
	for _, tc := range cases {
		t.Run(tc.protocol, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, tc.response)
			headers := map[string]string{"X-Test-Extension": "extension-value"}
			c := &Client{Provider: tc.protocol, BaseURL: srv.URL, APIKey: "test-key", Model: "m", MaxTokens: 300, Headers: headers}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil {
				t.Fatal(err)
			}
			req := <-requests
			if req.header.Get("X-Test-Extension") != "extension-value" || req.header.Get(tc.authHeader) == "" {
				t.Fatal("extension or adapter authentication header missing")
			}
			if !reflect.DeepEqual(headers, map[string]string{"X-Test-Extension": "extension-value"}) {
				t.Fatal("headers mutated")
			}
		})
	}
}

func TestValidateExtensionHeaders(t *testing.T) {
	t.Parallel()
	for _, headers := range []map[string]string{
		{"Authorization": "Bearer wrong"}, {"X-Api-Key": "wrong"}, {"x-goog-api-key": "wrong"},
		{"Host": "wrong"}, {"Content-Type": "wrong"}, {"Accept": "wrong"},
		{"Connection": "close"}, {"Transfer-Encoding": "chunked"},
		{"Cookie": "session=wrong"}, {"Set-Cookie": "session=wrong"},
		{"X-Bad\nName": "value"}, {"X-Bad-Value": "hello\r\nAuthorization: bad"},
	} {
		if err := ValidateHeaders(headers); err == nil {
			t.Fatal("invalid or reserved header accepted")
		}
	}
	if err := ValidateHeaders(map[string]string{"Anthropic-Beta": "some-beta", "HTTP-Referer": "https://example.com", "X-Title": "Tact"}); err != nil {
		t.Fatal(err)
	}
}
