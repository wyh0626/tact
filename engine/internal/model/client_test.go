package model

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func serve(t *testing.T, body string) *Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return &Client{BaseURL: srv.URL, Model: "m", MaxTokens: 20}
}

func TestCompleteReturnsContent(t *testing.T) {
	c := serve(t, `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`)
	got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "OK" {
		t.Fatalf("got %q, want %q", got, "OK")
	}
}

func TestCompleteRejectsReasoningTruncation(t *testing.T) {
	c := serve(t, `{"choices":[{"message":{"content":"","reasoning_content":"thinking..."},"finish_reason":"length"}]}`)
	_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}})
	if err == nil || !strings.Contains(err.Error(), "max_tokens") {
		t.Fatalf("want max_tokens error, got %v", err)
	}
}

func TestCompleteKeepsEmptyStop(t *testing.T) {
	c := serve(t, `{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}`)
	got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

func TestCompleteMergesExtraBodyWithoutOverridingCoreFields(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Errorf("decode request: %v", err)
		}
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`))
	}))
	t.Cleanup(srv.Close)
	c := &Client{BaseURL: srv.URL, Model: "m", ExtraBody: map[string]any{
		"thinking": map[string]any{"type": "disabled"},
		"model":    "other",
		"stream":   true,
	}}
	if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if th, _ := got["thinking"].(map[string]any); th["type"] != "disabled" {
		t.Fatalf("extra_body not merged: %v", got)
	}
	if got["model"] != "m" || got["stream"] != false {
		t.Fatalf("extra_body overrode core fields: model=%v stream=%v", got["model"], got["stream"])
	}
}

func TestCompleteSendsReasoningEffortAndTier(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`))
	}))
	t.Cleanup(srv.Close)
	c := &Client{BaseURL: srv.URL, Model: "m", ReasoningEffort: "high", ServiceTier: "priority"}
	if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
		t.Fatal(err)
	}
	if got["reasoning_effort"] != "high" || got["service_tier"] != "priority" {
		t.Fatalf("body = %v", got)
	}
	got = nil // decoding into a non-nil map would keep the first request's keys
	c = &Client{BaseURL: srv.URL, Model: "m"}
	if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
		t.Fatal(err)
	}
	if _, ok := got["reasoning_effort"]; ok {
		t.Fatalf("unset effort must not be sent: %v", got)
	}
}

func TestALongReplyRaisesTheOutputLimitForItsRequestOnly(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = nil
		_ = json.NewDecoder(r.Body).Decode(&got)
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`))
	}))
	t.Cleanup(srv.Close)
	c := &Client{BaseURL: srv.URL, Model: "m", MaxTokens: 300}
	send := func(ctx context.Context) any {
		if _, err := c.Complete(ctx, []Message{{Role: "user", Content: "hi"}}); err != nil {
			t.Fatal(err)
		}
		return got["max_tokens"]
	}
	if v := send(WithMaxTokens(context.Background(), 1500)); v != float64(1500) {
		t.Fatalf("raised limit = %v", v)
	}
	if v := send(WithMaxTokens(context.Background(), 100)); v != float64(300) {
		t.Fatalf("a configured limit is never lowered: %v", v)
	}
	if v := send(context.Background()); v != float64(300) {
		t.Fatalf("other requests keep the configured limit: %v", v)
	}
	c.MaxTokens = 0
	if _, err := c.Complete(WithMaxTokens(context.Background(), 1500), []Message{{Role: "user", Content: "hi"}}); err != nil {
		t.Fatal(err)
	}
	if _, ok := got["max_tokens"]; ok {
		t.Fatalf("no configured limit means none is added: %v", got)
	}
}

func TestCompletePreservesOpenAIRequestContract(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name        string
		basePath    string
		apiKey      string
		temperature float64
	}{
		{name: "gateway path and zero temperature", basePath: "/gateway/v1/", apiKey: "test-key"},
		{name: "local model without key", basePath: "/v1", temperature: 0.75},
		{name: "root endpoint", temperature: 0.25},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			messages := []Message{
				{Role: "system", Content: "用中文回复。"},
				{Role: "user", Content: "first\nsecond"},
				{Role: "assistant", Content: "previous reply"},
			}
			requests := make(chan map[string]any, 1)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				wantPath := strings.TrimSuffix(tt.basePath, "/") + "/chat/completions"
				if r.Method != http.MethodPost || r.URL.Path != wantPath {
					t.Errorf("request = %s %s, want POST %s", r.Method, r.URL.Path, wantPath)
				}
				if got := r.Header.Get("Content-Type"); got != "application/json" {
					t.Errorf("Content-Type = %q, want application/json", got)
				}
				wantAuth := ""
				if tt.apiKey != "" {
					wantAuth = "Bearer " + tt.apiKey
				}
				if got := r.Header.Get("Authorization"); got != wantAuth {
					t.Errorf("Authorization = %q, want %q", got, wantAuth)
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Errorf("decode request: %v", err)
				}
				requests <- body
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`))
			}))
			t.Cleanup(srv.Close)
			c := &Client{BaseURL: srv.URL + tt.basePath, Model: "model/exact-name", APIKey: tt.apiKey, Temperature: tt.temperature}
			if got, err := c.Complete(context.Background(), messages); err != nil || got != "OK" {
				t.Fatalf("Complete() = %q, %v, want OK, nil", got, err)
			}
			body := <-requests
			if body["model"] != c.Model || body["stream"] != false || body["temperature"] != tt.temperature {
				t.Errorf("core request fields = %v", body)
			}
			encoded, err := json.Marshal(messages)
			if err != nil {
				t.Fatal(err)
			}
			var wantMessages any
			if err := json.Unmarshal(encoded, &wantMessages); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(body["messages"], wantMessages) {
				t.Errorf("messages = %#v, want %#v", body["messages"], wantMessages)
			}
			for _, key := range []string{"max_tokens", "response_format", "reasoning_effort", "service_tier"} {
				if _, ok := body[key]; ok {
					t.Errorf("unset %s must not be sent: %v", key, body)
				}
			}
		})
	}
}

func TestCompletePreservesExtraBodyAndConfiguredOptions(t *testing.T) {
	t.Parallel()
	requests := make(chan map[string]any, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
		}
		requests <- body
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`))
	}))
	t.Cleanup(srv.Close)
	extra := map[string]any{
		"model": "wrong", "messages": []any{}, "stream": true, "temperature": 9,
		"max_tokens": 1, "response_format": map[string]any{"type": "text"},
		"reasoning_effort": "low", "service_tier": "wrong",
		"thinking":       map[string]any{"type": "disabled"},
		"vendor_options": map[string]any{"enabled": false, "stops": []any{"END", "STOP"}},
		"seed":           17, "top_p": 0.9,
	}
	before, err := json.Marshal(extra)
	if err != nil {
		t.Fatal(err)
	}
	c := &Client{
		BaseURL: srv.URL, Model: "actual", Temperature: 0, MaxTokens: 300, JSONMode: true,
		ReasoningEffort: "high", ServiceTier: "priority", ExtraBody: extra,
	}
	msgs := []Message{{Role: "user", Content: "keep this message"}}
	if _, err := c.Complete(WithMaxTokens(context.Background(), 700), msgs); err != nil {
		t.Fatal(err)
	}
	body := <-requests
	want := map[string]any{
		"model": "actual", "messages": []any{map[string]any{"role": "user", "content": "keep this message"}},
		"stream": false, "temperature": float64(0), "max_tokens": float64(700),
		"response_format":  map[string]any{"type": "json_object"},
		"reasoning_effort": "high", "service_tier": "priority",
		"thinking":       map[string]any{"type": "disabled"},
		"vendor_options": map[string]any{"enabled": false, "stops": []any{"END", "STOP"}},
		"seed":           float64(17), "top_p": 0.9,
	}
	for key, value := range want {
		if !reflect.DeepEqual(body[key], value) {
			t.Errorf("%s = %#v, want %#v", key, body[key], value)
		}
	}
	after, err := json.Marshal(extra)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Errorf("Complete mutated ExtraBody: before %s, after %s", before, after)
	}
}

func TestCompletePreservesOutputLimitSemantics(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		configured int
		override   int
		extra      map[string]any
		want       any
	}{
		{name: "configured limit", configured: 300, want: float64(300)},
		{name: "raised context limit", configured: 300, override: 900, want: float64(900)},
		{name: "context cannot lower limit", configured: 300, override: 100, want: float64(300)},
		{name: "negative context ignored", configured: 300, override: -100, want: float64(300)},
		{name: "unlimited remains unlimited", override: 900},
		{name: "negative configuration omitted", configured: -1, override: 900},
		{name: "extra limit retained without configured limit", extra: map[string]any{"max_tokens": 123}, want: float64(123)},
		{name: "configured limit overrides extra", configured: 300, extra: map[string]any{"max_tokens": 999}, want: float64(300)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			requests := make(chan map[string]any, 1)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Errorf("decode request: %v", err)
				}
				requests <- body
				_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`))
			}))
			t.Cleanup(srv.Close)
			c := &Client{BaseURL: srv.URL, Model: "m", MaxTokens: tt.configured, ExtraBody: tt.extra}
			if _, err := c.Complete(WithMaxTokens(context.Background(), tt.override), []Message{{Role: "user", Content: "hi"}}); err != nil {
				t.Fatal(err)
			}
			body := <-requests
			if got := body["max_tokens"]; got != tt.want {
				t.Errorf("max_tokens = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestCompleteReportsHTTPStatusErrors(t *testing.T) {
	t.Parallel()
	for _, status := range []int{http.StatusUnauthorized, http.StatusTooManyRequests, http.StatusInternalServerError} {
		t.Run(strconv.Itoa(status), func(t *testing.T) {
			t.Parallel()
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{"error":{"message":"provider rejected request"}}`))
			}))
			t.Cleanup(srv.Close)
			c := &Client{BaseURL: srv.URL, Model: "m"}
			got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}})
			if err == nil || !strings.Contains(err.Error(), strconv.Itoa(status)) || !strings.Contains(err.Error(), "provider rejected request") {
				t.Fatalf("Complete() = %q, %v, want error with status %d and provider detail", got, err, status)
			}
			if got != "" {
				t.Errorf("content on HTTP failure = %q, want empty", got)
			}
		})
	}
}

func TestCompleteRejectsMalformedResponses(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name string
		body string
	}{
		{name: "invalid JSON", body: `{"choices":`},
		{name: "trailing garbage", body: `{"choices":[{"message":{"content":"OK"}}]}garbage`},
		{name: "second JSON document", body: `{"choices":[{"message":{"content":"OK"}}]}{"extra":true}`},
		{name: "empty body"},
		{name: "no choices", body: `{}`},
		{name: "empty choices", body: `{"choices":[]}`},
		{name: "null choices", body: `{"choices":null}`},
		{name: "wrong content type", body: `{"choices":[{"message":{"content":{"unexpected":"object"}}}]}`},
		{name: "blank reasoning truncated", body: `{"choices":[{"message":{"content":" \n\t"},"finish_reason":"length"}]}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			c := serve(t, tt.body)
			if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err == nil || got != "" {
				t.Fatalf("Complete() = %q, %v, want empty content and error", got, err)
			}
		})
	}
}

func TestCompleteBoundsResponseBody(t *testing.T) {
	t.Parallel()
	t.Run("oversized successful response is rejected", func(t *testing.T) {
		t.Parallel()
		body := `{"choices":[{"message":{"content":"` + strings.Repeat("x", 4<<20) + `"},"finish_reason":"stop"}]}`
		c := serve(t, body)
		if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err == nil || got != "" {
			t.Fatalf("Complete returned %d content bytes, %v, want empty content and response-size error", len(got), err)
		}
	})
	t.Run("provider error detail is truncated", func(t *testing.T) {
		t.Parallel()
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte("provider failure: " + strings.Repeat("错", 1000)))
		}))
		t.Cleanup(srv.Close)
		c := &Client{BaseURL: srv.URL, Model: "m"}
		_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}})
		if err == nil || !strings.Contains(err.Error(), "502") || !strings.Contains(err.Error(), "provider failure") {
			t.Fatalf("Complete error = %v, want HTTP 502 and provider detail", err)
		}
		if got := len([]rune(err.Error())); got > 350 {
			t.Errorf("provider error has %d runes, want bounded diagnostic", got)
		}
	})
}

func TestCompletePreservesFirstChoiceAndPartialContent(t *testing.T) {
	t.Parallel()
	c := serve(t, `{"choices":[{"message":{"content":"partial reply"},"finish_reason":"length"},{"message":{"content":"second reply"},"finish_reason":"stop"}]}`)
	if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil || got != "partial reply" {
		t.Fatalf("Complete() = %q, %v, want partial reply, nil", got, err)
	}
}

func TestCompleteRejectsRedirectsWithoutLeakingRequest(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name   string
		status int
		http   *http.Client
	}{
		{name: "default client", status: http.StatusTemporaryRedirect},
		{name: "safe client", status: http.StatusPermanentRedirect, http: NewHTTPClient(time.Second)},
		{name: "caller client", status: http.StatusTemporaryRedirect, http: &http.Client{Timeout: time.Second}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var leaked atomic.Int32
			target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				leaked.Add(1)
				_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"leaked"}}]}`))
			}))
			t.Cleanup(target.Close)
			source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", target.URL+"/stolen")
				w.WriteHeader(tt.status)
			}))
			t.Cleanup(source.Close)
			c := &Client{BaseURL: source.URL, Model: "m", APIKey: "private-key", HTTP: tt.http}
			if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "private conversation"}}); err == nil || got != "" {
				t.Fatalf("Complete() = %q, %v, want rejected redirect", got, err)
			}
			if got := leaked.Load(); got != 0 {
				t.Errorf("redirect target received %d requests, want no credentials or chat data sent", got)
			}
			if tt.http != nil && tt.http.CheckRedirect != nil && tt.name == "caller client" {
				t.Error("Complete changed caller-owned HTTP client")
			}
		})
	}
}

func TestCompleteHonorsCancellationAndTimeout(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name           string
		provider       string
		timeout        time.Duration
		contextTimeout time.Duration
		cancel         bool
		status         int
		wantErr        error
	}{
		{name: "in-flight cancellation", cancel: true, wantErr: context.Canceled},
		{name: "HTTP client timeout", timeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
		{name: "success headers then cancellation", status: http.StatusOK, cancel: true, wantErr: context.Canceled},
		{name: "error headers then cancellation", status: http.StatusTooManyRequests, cancel: true, wantErr: context.Canceled},
		{name: "success headers then HTTP timeout", status: http.StatusOK, timeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
		{name: "error headers then HTTP timeout", status: http.StatusTooManyRequests, timeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
		{name: "error headers then context deadline", status: http.StatusTooManyRequests, contextTimeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
		{name: "Claude HTTP timeout", provider: "anthropic", timeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
		{name: "Claude error headers then HTTP timeout", provider: "anthropic", status: http.StatusTooManyRequests, timeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
		{name: "Gemini HTTP timeout", provider: "gemini", timeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
		{name: "Gemini error headers then HTTP timeout", provider: "gemini", status: http.StatusTooManyRequests, timeout: 50 * time.Millisecond, wantErr: context.DeadlineExceeded},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			started := make(chan struct{}, 1)
			release := make(chan struct{})
			defer close(release)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Errorf("decode request: %v", err)
				}
				if tt.status != 0 {
					w.WriteHeader(tt.status)
					w.(http.Flusher).Flush()
				}
				started <- struct{}{}
				select {
				case <-r.Context().Done():
				case <-release:
				}
			}))
			t.Cleanup(srv.Close)
			ctx, cancel := context.WithCancel(context.Background())
			if tt.contextTimeout > 0 {
				cancel()
				ctx, cancel = context.WithTimeout(context.Background(), tt.contextTimeout)
			}
			defer cancel()
			c := &Client{Provider: tt.provider, BaseURL: srv.URL, Model: "m", APIKey: "test-key", MaxTokens: 300, HTTP: NewHTTPClient(tt.timeout)}
			done := make(chan error, 1)
			go func() {
				_, err := c.Complete(ctx, []Message{{Role: "user", Content: "hi"}})
				done <- err
			}()
			select {
			case <-started:
			case <-time.After(2 * time.Second):
				t.Fatal("model request did not reach server")
			}
			if tt.cancel {
				cancel()
			}
			select {
			case err := <-done:
				if !errors.Is(err, tt.wantErr) {
					t.Errorf("Complete error = %v, want wrapped %v", err, tt.wantErr)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("Complete did not honor cancellation or timeout")
			}
		})
	}
}

func TestCompleteConcurrentCallsKeepRequestLimitsIsolated(t *testing.T) {
	t.Parallel()
	const count = 12
	type observed struct {
		message string
		limit   int
	}
	requests := make(chan observed, count)
	release := make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	defer unblock()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages  []Message `json:"messages"`
			MaxTokens int       `json:"max_tokens"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body.Messages) != 1 {
			t.Errorf("invalid concurrent request: %+v, %v", body, err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		message := body.Messages[0].Content
		requests <- observed{message: message, limit: body.MaxTokens}
		<-release
		if err := json.NewEncoder(w).Encode(map[string]any{
			"choices": []any{map[string]any{"message": map[string]any{"content": message}, "finish_reason": "stop"}},
		}); err != nil {
			t.Errorf("encode response: %v", err)
		}
	}))
	t.Cleanup(srv.Close)
	c := &Client{BaseURL: srv.URL, Model: "m", MaxTokens: 300, HTTP: NewHTTPClient(5 * time.Second), ExtraBody: map[string]any{"thinking": map[string]any{"type": "disabled"}}}
	results := make(chan error, count)
	for i := 0; i < count; i++ {
		go func(i int) {
			message := strconv.Itoa(i)
			ctx := WithMaxTokens(context.Background(), (i+1)*100)
			got, err := c.Complete(ctx, []Message{{Role: "user", Content: message}})
			if err == nil && got != message {
				err = fmt.Errorf("reply = %q, want %q", got, message)
			}
			results <- err
		}(i)
	}
	seen := make(map[string]bool, count)
	for i := 0; i < count; i++ {
		select {
		case request := <-requests:
			n, err := strconv.Atoi(request.message)
			if err != nil || n < 0 || n >= count || seen[request.message] {
				t.Errorf("unexpected request message %q: %v", request.message, err)
				continue
			}
			seen[request.message] = true
			want := max(300, (n+1)*100)
			if request.limit != want {
				t.Errorf("request %s limit = %d, want %d", request.message, request.limit, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("concurrent requests did not all reach server")
		}
	}
	unblock()
	for i := 0; i < count; i++ {
		select {
		case err := <-results:
			if err != nil {
				t.Errorf("concurrent Complete: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("concurrent Complete did not return")
		}
	}
	if c.MaxTokens != 300 {
		t.Errorf("configured MaxTokens = %d, want 300", c.MaxTokens)
	}
}
