package model

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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
