package model

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func sse(events ...string) string {
	var b strings.Builder
	for _, e := range events {
		var ev struct{ Type string }
		_ = json.Unmarshal([]byte(e), &ev)
		fmt.Fprintf(&b, "event: %s\ndata: %s\n\n", ev.Type, e)
	}
	return b.String()
}

func responsesServer(t *testing.T, status int, body string, got *map[string]any, auth *string) *ResponsesClient {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/responses" {
			t.Errorf("path = %s", r.URL.Path)
		}
		if got != nil {
			_ = json.NewDecoder(r.Body).Decode(got)
		}
		if auth != nil {
			*auth = r.Header.Get("Authorization")
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(status)
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)
	return &ResponsesClient{BaseURL: srv.URL, Model: "gpt-fast",
		Token: func(context.Context) (string, error) { return "tok", nil }}
}

func TestResponsesCollectsStreamedText(t *testing.T) {
	var body map[string]any
	var auth string
	c := responsesServer(t, 200, sse(
		`{"type":"response.created"}`,
		`{"type":"response.output_text.delta","delta":"好"}`,
		`{"type":"response.output_text.delta","delta":"的"}`,
		`{"type":"response.completed"}`,
	), &body, &auth)
	out, err := c.Complete(context.Background(), []Message{
		{Role: "system", Content: "规则"}, {Role: "user", Content: "聊天记录"},
	})
	if err != nil || out != "好的" {
		t.Fatalf("got %q, %v", out, err)
	}
	if auth != "Bearer tok" {
		t.Errorf("Authorization = %q", auth)
	}
	if body["store"] != false || body["stream"] != true || body["instructions"] != "规则" || body["model"] != "gpt-fast" {
		t.Errorf("body = %v", body)
	}
	for _, unsupported := range []string{"temperature", "max_output_tokens", "max_tokens"} {
		if _, ok := body[unsupported]; ok {
			t.Errorf("body must not carry %s", unsupported)
		}
	}
	input, _ := body["input"].([]any)
	if len(input) != 1 || input[0].(map[string]any)["role"] != "user" {
		t.Errorf("input = %v", body["input"])
	}
}

func TestResponsesFailedEventCarriesCode(t *testing.T) {
	c := responsesServer(t, 200, sse(
		`{"type":"response.output_text.delta","delta":"半"}`,
		`{"type":"response.failed","response":{"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit"}}}`,
	), nil, nil)
	_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "x"}})
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Code != "subscription_sharing_usage_limit_exceeded" ||
		!strings.Contains(err.Error(), "chatgpt.com/settings/usage") {
		t.Fatalf("err = %v", err)
	}
}

func TestResponsesHTTPErrorBody(t *testing.T) {
	c := responsesServer(t, 403, `{"error":{"code":"subscription_sharing_user_not_eligible","message":"no"}}`, nil, nil)
	_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "x"}})
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != 403 || !strings.Contains(err.Error(), "不能在第三方应用") {
		t.Fatalf("err = %v", err)
	}
}

func TestResponsesUnauthorized(t *testing.T) {
	c := responsesServer(t, 401, `{"error":{"message":"bad token"}}`, nil, nil)
	_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "x"}})
	if err == nil || !strings.Contains(err.Error(), "重新登录") {
		t.Fatalf("err = %v", err)
	}
}

func TestResponsesStreamCutShort(t *testing.T) {
	c := responsesServer(t, 200, sse(`{"type":"response.output_text.delta","delta":"半句"}`), nil, nil)
	if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "x"}}); err == nil {
		t.Fatal("a stream without response.completed must fail")
	}
}

func TestResponsesIncomplete(t *testing.T) {
	c := responsesServer(t, 200, sse(`{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}`), nil, nil)
	_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "x"}})
	if err == nil || !strings.Contains(err.Error(), "max_output_tokens") {
		t.Fatalf("err = %v", err)
	}
}

func TestResponsesTokenError(t *testing.T) {
	want := errors.New("not signed in")
	c := &ResponsesClient{BaseURL: "http://127.0.0.1:1", Token: func(context.Context) (string, error) { return "", want }}
	if _, err := c.Complete(context.Background(), nil); !errors.Is(err, want) {
		t.Fatalf("err = %v", err)
	}
}

func TestResponsesReasoningAndServiceTier(t *testing.T) {
	var body map[string]any
	c := responsesServer(t, 200, sse(`{"type":"response.completed"}`), &body, nil)
	c.ReasoningEffort, c.ServiceTier = "low", "priority"
	if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "x"}}); err != nil {
		t.Fatal(err)
	}
	reasoning, _ := body["reasoning"].(map[string]any)
	if reasoning["effort"] != "low" || body["service_tier"] != "priority" {
		t.Fatalf("body = %v", body)
	}
}

func TestResponsesOmitsUnsetSpeedOptions(t *testing.T) {
	var body map[string]any
	c := responsesServer(t, 200, sse(`{"type":"response.completed"}`), &body, nil)
	if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "x"}}); err != nil {
		t.Fatal(err)
	}
	if _, ok := body["reasoning"]; ok {
		t.Fatalf("reasoning must be left to the model default: %v", body)
	}
	if _, ok := body["service_tier"]; ok {
		t.Fatalf("service_tier must be left to the standard tier: %v", body)
	}
}
