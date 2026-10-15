package suggest

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/wyh0626/tact/engine/internal/chatgpt"
	"github.com/wyh0626/tact/engine/internal/config"
)

type modelProtocolRequest struct {
	method string
	path   string
	header http.Header
	body   map[string]any
}

func modelProtocolServer(t *testing.T, contentType, response string) (*httptest.Server, <-chan modelProtocolRequest) {
	t.Helper()
	requests := make(chan modelProtocolRequest, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode model request: %v", err)
		}
		requests <- modelProtocolRequest{method: r.Method, path: r.URL.Path, header: r.Header.Clone(), body: body}
		w.Header().Set("Content-Type", contentType)
		if _, err := io.WriteString(w, response); err != nil {
			t.Errorf("write model response: %v", err)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, requests
}

func modelProtocolConfig(t *testing.T, provider, baseURL string) config.Config {
	t.Helper()
	cfg := config.Default()
	cfg.Model.Provider = provider
	cfg.Model.BaseURL = baseURL
	cfg.Model.AllowedBaseURLs = []string{baseURL}
	cfg.Model.Model = "wire-model"
	cfg.Model.TimeoutMS = 3000
	cfg.Style.File = filepath.Join(t.TempDir(), "style.md")
	cfg.Feedback.File = filepath.Join(t.TempDir(), "feedback.jsonl")
	if err := cfg.Validate(); err != nil {
		t.Fatalf("test configuration is invalid: %v", err)
	}
	return cfg
}

func TestNewFromConfigModelProtocolWiring(t *testing.T) {
	const keyEnv = "TACT_EINO_SERVICE_TEST_KEY"
	const testKey = "test-service-api-key"
	t.Setenv(keyEnv, testKey)
	const compatibleOK = `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`
	cases := []struct {
		name       string
		provider   string
		basePath   string
		path       string
		authHeader string
		authValue  string
		response   string
	}{
		{name: "legacy compatible", basePath: "/v1", path: "/v1/chat/completions", authHeader: "Authorization", authValue: "Bearer " + testKey, response: compatibleOK},
		{name: "OpenAI", provider: "openai", basePath: "/v1", path: "/v1/chat/completions", authHeader: "Authorization", authValue: "Bearer " + testKey, response: compatibleOK},
		{name: "DeepSeek", provider: "deepseek", basePath: "/v1", path: "/v1/chat/completions", authHeader: "Authorization", authValue: "Bearer " + testKey, response: compatibleOK},
		{name: "Anthropic", provider: "anthropic", path: "/v1/messages", authHeader: "X-Api-Key", authValue: testKey,
			response: `{"id":"msg_wire","type":"message","role":"assistant","model":"wire-model","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2}}`},
		{name: "Gemini", provider: "gemini", path: "/v1beta/models/wire-model:generateContent", authHeader: "X-Goog-Api-Key", authValue: testKey,
			response: `{"candidates":[{"content":{"role":"model","parts":[{"text":"OK"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":2,"totalTokenCount":6}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv, requests := modelProtocolServer(t, "application/json", tc.response)
			cfg := modelProtocolConfig(t, tc.provider, srv.URL+tc.basePath)
			cfg.Model.APIKeyEnv = keyEnv
			svc := NewFromConfig(cfg)
			svc.chatgpt.Path = filepath.Join(t.TempDir(), "unused-chatgpt.json")
			t.Cleanup(svc.Close)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			resp := svc.Handle(ctx, Request{Op: "model_test"})
			if !resp.OK || resp.Note != "OK" {
				t.Fatalf("Handle(model_test) = %+v, want OK note", resp)
			}
			req := <-requests
			if req.method != http.MethodPost || req.path != tc.path {
				t.Errorf("request = %s %s, want POST %s", req.method, req.path, tc.path)
			}
			if got := req.header.Get(tc.authHeader); got != tc.authValue {
				t.Errorf("%s = %q, want configured test credential", tc.authHeader, got)
			}
			if tc.provider == "gemini" {
				generation, _ := req.body["generationConfig"].(map[string]any)
				if generation["maxOutputTokens"] != float64(cfg.Model.MaxTokens) {
					t.Errorf("maxOutputTokens = %v, want %d", generation["maxOutputTokens"], cfg.Model.MaxTokens)
				}
			} else if req.body["model"] != cfg.Model.Model || req.body["max_tokens"] != float64(cfg.Model.MaxTokens) {
				t.Errorf("request model/output limit = %v / %v, want %q / %d", req.body["model"], req.body["max_tokens"], cfg.Model.Model, cfg.Model.MaxTokens)
			}
		})
	}
}

func TestNewFromConfigChatGPTUsesStoredSignIn(t *testing.T) {
	t.Parallel()
	const testToken = "test-chatgpt-access-token"
	stream := "data: {\"type\":\"response.output_text.delta\",\"delta\":\"OK\"}\n\n" +
		"data: {\"type\":\"response.completed\"}\n\n"
	srv, requests := modelProtocolServer(t, "text/event-stream", stream)
	cfg := modelProtocolConfig(t, "chatgpt", srv.URL+"/v1")
	cfg.Model.ReasoningEffort = "low"
	cfg.Model.ServiceTier = "priority"
	svc := NewFromConfig(cfg)
	t.Cleanup(svc.Close)
	credentialsPath := filepath.Join(t.TempDir(), "chatgpt.json")
	data, err := json.Marshal(chatgpt.Credentials{
		HostID: "test-host", ClientID: "test-client", AccessToken: testToken,
		RefreshToken: "test-chatgpt-refresh-token", TokenType: "Bearer",
		ExpiresAt: time.Now().Add(time.Hour), Scopes: []string{chatgpt.PlanScope},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credentialsPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	// The model's token closure uses this same manager. Keep credentials and
	// any unexpected refresh requests entirely within the test's resources.
	svc.chatgpt.Path = credentialsPath
	svc.chatgpt.AuthBase = srv.URL
	svc.chatgpt.APIBase = srv.URL + "/v1"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp := svc.Handle(ctx, Request{Op: "model_test"})
	if !resp.OK || resp.Note != "OK" {
		t.Fatalf("Handle(model_test) = %+v, want OK note from Responses stream", resp)
	}
	req := <-requests
	if req.method != http.MethodPost || req.path != "/v1/responses" {
		t.Errorf("request = %s %s, want POST /v1/responses", req.method, req.path)
	}
	if got := req.header.Get("Authorization"); got != "Bearer "+testToken {
		t.Errorf("Authorization = %q, want the saved test sign-in token", got)
	}
	if req.body["model"] != cfg.Model.Model || req.body["stream"] != true || req.body["store"] != false {
		t.Errorf("Responses request model/stream/store = %v / %v / %v", req.body["model"], req.body["stream"], req.body["store"])
	}
	reasoning, _ := req.body["reasoning"].(map[string]any)
	if reasoning["effort"] != cfg.Model.ReasoningEffort || req.body["service_tier"] != cfg.Model.ServiceTier {
		t.Errorf("Responses effort/tier = %v / %v, want %q / %q", reasoning["effort"], req.body["service_tier"], cfg.Model.ReasoningEffort, cfg.Model.ServiceTier)
	}
	for _, field := range []string{"temperature", "max_tokens", "max_output_tokens"} {
		if _, exists := req.body[field]; exists {
			t.Errorf("ChatGPT plan request unexpectedly includes %s", field)
		}
	}
}
