package model

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/wyh0626/tact/engine/internal/reasoning"
)

const chatOK = `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`

// refusal is a service's answer to a request carrying field.
type refusal struct {
	field, body string
	status      int
}

func openAIRefusal(field, code string) refusal {
	message := "Unsupported parameter: '" + field + "' is not supported with this model."
	if field == "max_tokens" {
		message += " Use 'max_completion_tokens' instead."
	}
	return refusal{field: field, body: `{"error":{"message":"` + message + `","type":"invalid_request_error","param":"` + field + `","code":"` + code + `"}}`}
}

// refusingServer answers like a service that refuses some request fields:
// a request carrying one of them gets the first matching refusal, any other
// request gets ok. It returns every request body it received.
func refusingServer(t *testing.T, ok string, refusals ...refusal) (*httptest.Server, func() []map[string]any) {
	t.Helper()
	var mu sync.Mutex
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
		}
		mu.Lock()
		bodies = append(bodies, body)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		for _, refused := range refusals {
			if _, sent := body[refused.field]; sent {
				status := refused.status
				if status == 0 {
					status = http.StatusBadRequest
				}
				w.WriteHeader(status)
				_, _ = w.Write([]byte(refused.body))
				return
			}
		}
		_, _ = w.Write([]byte(ok))
	}))
	t.Cleanup(srv.Close)
	return srv, func() []map[string]any {
		mu.Lock()
		defer mu.Unlock()
		return append([]map[string]any(nil), bodies...)
	}
}

// uniqueModel keeps refusals one test teaches away from other tests, which
// may reuse its server's port.
func uniqueModel(t *testing.T) string {
	return strings.ReplaceAll(t.Name(), "/", "-")
}

func TestRefusedFieldsAreLeftOutAndRemembered(t *testing.T) {
	t.Parallel()
	srv, requests := refusingServer(t, chatOK,
		openAIRefusal("max_tokens", "unsupported_parameter"),
		openAIRefusal("temperature", "unsupported_value"),
		openAIRefusal("top_p", "unsupported_parameter"),
		openAIRefusal("logprobs", "unsupported_parameter"),
		openAIRefusal("top_logprobs", "unsupported_parameter"))
	extra := map[string]any{"max_tokens": 1, "max_completion_tokens": 2, "temperature": .1, "top_p": .9,
		"logprobs": true, "top_logprobs": 3, "metadata": map[string]string{"tag": "keep"}}
	before, err := json.Marshal(extra)
	if err != nil {
		t.Fatal(err)
	}
	c := &Client{Provider: "openai", Preset: "openai", BaseURL: srv.URL, Model: uniqueModel(t),
		MaxTokens: 300, Temperature: .3, ExtraBody: extra}
	ctx := WithMaxTokens(context.Background(), 900)
	if got, err := c.Complete(ctx, []Message{{Role: "user", Content: "hello"}}); err != nil || got != "OK" {
		t.Fatalf("Complete = %q, %v", got, err)
	}
	sent := requests()
	if len(sent) != 6 {
		t.Fatalf("requests = %d, want one per refused field and the accepted one", len(sent))
	}
	body := sent[len(sent)-1]
	if body["max_completion_tokens"] != float64(900) || body["stream"] != false || !reflect.DeepEqual(body["metadata"], map[string]any{"tag": "keep"}) {
		t.Fatalf("accepted request = %#v", body)
	}
	for _, field := range []string{"max_tokens", "temperature", "top_p", "logprobs", "top_logprobs"} {
		if _, present := body[field]; present {
			t.Errorf("refused %s sent again", field)
		}
	}
	if after, err := json.Marshal(extra); err != nil || string(after) != string(before) {
		t.Fatal("leaving fields out mutated saved advanced options")
	}

	if _, err := c.Complete(ctx, []Message{{Role: "user", Content: "again"}}); err != nil {
		t.Fatal(err)
	}
	if again := requests()[len(sent):]; len(again) != 1 || !reflect.DeepEqual(again[0]["max_completion_tokens"], float64(900)) {
		t.Fatalf("later request did not start without the refused fields: %#v", again)
	}
}

func TestRefusalMessagesNameTheirFields(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, body string
		left       []string
	}{
		{"parameter field", `{"error":{"message":"Unsupported value","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}`, []string{"temperature"}},
		{"message only", `{"error":{"message":"invalid temperature: only 1 is allowed for this model","type":"invalid_request_error"}}`, []string{"temperature"}},
		{"quoted names", "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"`temperature` and `top_p` cannot both be specified for this model.\"}}", []string{"temperature", "top_p"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := refusingServer(t, chatOK, refusal{field: "temperature", body: tc.body})
			c := &Client{Provider: "openai", BaseURL: srv.URL, Model: uniqueModel(t), MaxTokens: 300, Temperature: .3,
				ExtraBody: map[string]any{"top_p": .9, "top_k": 40}}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil {
				t.Fatal(err)
			}
			sent := requests()
			body := sent[len(sent)-1]
			for _, field := range tc.left {
				if _, present := body[field]; present {
					t.Errorf("%s still sent", field)
				}
			}
			if body["top_k"] != float64(40) || body["max_tokens"] != float64(300) {
				t.Errorf("fields the service did not name were dropped: %#v", body)
			}
		})
	}
}

func TestRawTokenCapMovesWhenTheServiceRefusesIt(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name  string
		extra map[string]any
		want  float64
	}{
		{"legacy raw cap", map[string]any{"max_tokens": 2000}, 2000},
		{"modern raw cap wins", map[string]any{"max_tokens": 2000, "max_completion_tokens": 4000}, 4000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := refusingServer(t, chatOK, openAIRefusal("max_tokens", "unsupported_parameter"))
			original := copyFields(tc.extra)
			c := &Client{Provider: "openai", BaseURL: srv.URL, Model: uniqueModel(t), ExtraBody: tc.extra}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil {
				t.Fatal(err)
			}
			sent := requests()
			body := sent[len(sent)-1]
			if body["max_completion_tokens"] != tc.want {
				t.Fatalf("max_completion_tokens = %#v", body["max_completion_tokens"])
			}
			if _, present := body["max_tokens"]; present {
				t.Fatal("legacy raw token field survived")
			}
			if !reflect.DeepEqual(tc.extra, original) {
				t.Fatal("raw cap configuration mutated")
			}
		})
	}
}

func TestRefusalsAreRememberedPerReasoningSetting(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	var bodies []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
		}
		mu.Lock()
		bodies = append(bodies, body)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		if _, sampled := body["temperature"]; sampled && body["reasoning_effort"] != "none" {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(openAIRefusal("temperature", "unsupported_value").body))
			return
		}
		_, _ = w.Write([]byte(chatOK))
	}))
	t.Cleanup(srv.Close)
	count := func() int {
		mu.Lock()
		defer mu.Unlock()
		return len(bodies)
	}
	model := uniqueModel(t)
	complete := func(effort string) map[string]any {
		t.Helper()
		c := &Client{Provider: "openai", BaseURL: srv.URL, Model: model, MaxTokens: 300, Temperature: .3, ReasoningEffort: effort}
		if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil {
			t.Fatal(err)
		}
		mu.Lock()
		defer mu.Unlock()
		return bodies[len(bodies)-1]
	}

	if body := complete("high"); body["temperature"] != nil || count() != 2 {
		t.Fatalf("high effort: %d requests, last %#v", count(), body)
	}
	if body := complete("none"); body["temperature"] != .3 || count() != 3 {
		t.Fatalf("a refusal under high effort applied without reasoning: %d requests, last %#v", count(), body)
	}
	if body := complete("high"); body["temperature"] != nil || count() != 4 {
		t.Fatalf("high effort refusal not remembered: %d requests, last %#v", count(), body)
	}
}

func TestOtherErrorsAreNotSentAgain(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name     string
		refusal  refusal
		requests int
	}{
		{"cap too large", refusal{field: "max_tokens", body: `{"error":{"message":"max_tokens is too large: 300 > 200","type":"invalid_request_error","param":"max_tokens"}}`}, 1},
		{"field not sent", refusal{field: "temperature", body: `{"error":{"message":"top_k is not supported","type":"invalid_request_error"}}`}, 1},
		{"unauthorized", refusal{field: "temperature", status: http.StatusUnauthorized, body: `{"error":{"message":"temperature key rejected","type":"invalid_request_error"}}`}, 1},
		{"server error", refusal{field: "temperature", status: http.StatusInternalServerError, body: `{"error":{"message":"temperature overloaded","type":"server_error"}}`}, 1},
		{"named after leaving out", refusal{field: "messages", body: `{"error":{"message":"temperature is not supported","type":"invalid_request_error"}}`}, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := refusingServer(t, chatOK, tc.refusal)
			c := &Client{Provider: "openai", BaseURL: srv.URL, Model: uniqueModel(t), MaxTokens: 300, Temperature: .3}
			_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}})
			if err == nil || !strings.Contains(err.Error(), "模型接口返回 HTTP") {
				t.Fatalf("err = %v, want the service's error", err)
			}
			if got := len(requests()); got != tc.requests {
				t.Fatalf("requests = %d, want %d", got, tc.requests)
			}
		})
	}
}

func TestModelIDsAloneDoNotChangeTheRequest(t *testing.T) {
	t.Parallel()
	for _, id := range []string{"gpt-5", "o3", "kimi-k2.6", "claude-opus-4-7"} {
		t.Run(id, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, chatOK)
			c := &Client{Provider: "openai", Preset: "openai", BaseURL: srv.URL, Model: id, MaxTokens: 300, Temperature: .3,
				ExtraBody: map[string]any{"top_p": .9}}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil {
				t.Fatal(err)
			}
			body := (<-requests).body
			if body["max_tokens"] != float64(300) || body["temperature"] != .3 || body["top_p"] != .9 {
				t.Fatalf("request = %#v", body)
			}
		})
	}
}

func TestClaudeLeavesOutRefusedSampling(t *testing.T) {
	t.Parallel()
	claudeRefusal := func(field string) refusal {
		return refusal{field: field, body: `{"type":"error","error":{"type":"invalid_request_error","message":"` + field + ` is not supported for this model."}}`}
	}
	for _, effort := range []string{"", "none"} {
		t.Run("effort="+effort, func(t *testing.T) {
			t.Parallel()
			srv, requests := refusingServer(t, claudeOK, claudeRefusal("temperature"), claudeRefusal("top_p"), claudeRefusal("top_k"))
			extra := map[string]any{"temperature": .2, "top_p": .9, "top_k": 50, "metadata": map[string]any{"user_id": "local-test"}}
			c := &Client{Provider: "anthropic", BaseURL: srv.URL, Model: uniqueModel(t), APIKey: "test-key", MaxTokens: 300, Temperature: .3,
				Reasoning: &reasoning.Config{Format: "anthropic_effort", Effort: effort}, ExtraBody: extra}
			if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil || got != "native OK" {
				t.Fatalf("Complete = %q, %v", got, err)
			}
			sent := requests()
			body := sent[len(sent)-1]
			for _, key := range []string{"temperature", "top_p", "top_k"} {
				if _, exists := body[key]; exists {
					t.Errorf("refused %s sent again", key)
				}
				if _, exists := extra[key]; !exists {
					t.Errorf("request mutated saved %s", key)
				}
			}
			if body["max_tokens"] != float64(300) {
				t.Errorf("max_tokens = %#v", body["max_tokens"])
			}
		})
	}
}

func TestMentionsMatchesWholeFieldNames(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		text, word string
		want       bool
	}{
		{"'top_p' is not supported", "top_p", true},
		{"top_p_extra is not supported", "top_p", false},
		{"top_logprobs is not supported", "logprobs", false},
		{"logprobs, top_logprobs", "logprobs", true},
		{"use max_completion_tokens", "max_tokens", false},
		{"temperature", "temperature", true},
	} {
		if got := mentions(tc.text, tc.word); got != tc.want {
			t.Errorf("mentions(%q, %q) = %v", tc.text, tc.word, got)
		}
	}
}

func TestRateLimitSaysWhenToTryAgain(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, retryAfter, want string
	}{
		{"seconds", "20", "约 20 秒后再试"},
		{"date", time.Now().Add(31 * time.Second).UTC().Format(http.TimeFormat), "秒后再试"},
		{"none", "", "稍后再试"},
		{"unreadable", "soon", "稍后再试"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if tc.retryAfter != "" {
					w.Header().Set("Retry-After", tc.retryAfter)
				}
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = w.Write([]byte(`{"error":{"message":"organization max RPM: 3"}}`))
			}))
			t.Cleanup(srv.Close)
			c := &Client{Provider: "openai", BaseURL: srv.URL, Model: uniqueModel(t), MaxTokens: 300}
			_, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}})
			if err == nil || !strings.Contains(err.Error(), "请求太频繁") || !strings.Contains(err.Error(), tc.want) ||
				!strings.Contains(err.Error(), "max RPM") {
				t.Fatalf("err = %v, want a rate-limit message with %q", err, tc.want)
			}
		})
	}
}

func TestRetryAfterSeconds(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 10, 15, 12, 0, 0, 0, time.UTC)
	for _, tc := range []struct {
		value string
		want  int
		ok    bool
	}{
		{"20", 20, true},
		{"0", 1, true},
		{now.Add(90 * time.Second).Format(http.TimeFormat), 90, true},
		{now.Add(-time.Minute).Format(http.TimeFormat), 1, true},
		{"", 0, false},
		{"-3", 0, false},
		{"later", 0, false},
	} {
		if got, ok := retryAfterSeconds(tc.value, now); got != tc.want || ok != tc.ok {
			t.Errorf("retryAfterSeconds(%q) = %d, %v; want %d, %v", tc.value, got, ok, tc.want, tc.ok)
		}
	}
}
