package suggest

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/wyh0626/tact/engine/internal/modelcatalog"
)

func TestNewFromConfigExplicitProtocolAndBrandedPresets(t *testing.T) {
	const keyEnv = "TACT_CONNECTION_PROTOCOL_TEST_KEY"
	t.Setenv(keyEnv, "connection-test-key")
	cases := []struct{ provider, protocol, path, body string }{
		{"zhipu", "", "/v1/chat/completions", `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`},
		{"moonshot", "", "/v1/chat/completions", `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`},
		{"minimax", "", "/v1/chat/completions", `{"choices":[{"message":{"content":"OK","reasoning_content":"thoughts"},"finish_reason":"stop"}]}`},
		{"custom", "anthropic", "/v1/messages", `{"type":"message","role":"assistant","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn","usage":{"input_tokens":2,"output_tokens":2}}`},
		{"custom", "gemini", "/v1/models/wire-model:generateContent", `{"candidates":[{"content":{"role":"model","parts":[{"text":"OK"}]},"finishReason":"STOP"}]}`},
		{"custom", "responses", "/v1/responses", `{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}`},
	}
	for _, tc := range cases {
		t.Run(tc.provider+"/"+tc.protocol, func(t *testing.T) {
			srv, requests := modelProtocolServer(t, "application/json", tc.body)
			cfg := modelProtocolConfig(t, tc.provider, srv.URL+"/v1")
			cfg.Model.Protocol, cfg.Model.APIKeyEnv = tc.protocol, keyEnv
			cfg.Model.Headers = map[string]string{"X-Test-Connection": "from-config"}
			if err := cfg.Validate(); err != nil {
				t.Fatal(err)
			}
			svc := NewFromConfig(cfg)
			t.Cleanup(svc.Close)
			response := svc.Handle(context.Background(), Request{Op: "model_test"})
			if !response.OK || response.Note != "OK" {
				t.Fatalf("model_test = %+v", response)
			}
			req := <-requests
			if req.path != tc.path || req.header.Get("X-Test-Connection") != "from-config" {
				t.Fatalf("path = %s, extension = %q", req.path, req.header.Get("X-Test-Connection"))
			}
			if tc.provider == "minimax" && req.body["reasoning_split"] != true {
				t.Fatal("MiniMax preset must separate thoughts from reply content")
			}
		})
	}
}

func TestModelCatalogStoredKeyStaysOnUnchangedConnection(t *testing.T) {
	const keyEnv = "TACT_CONNECTION_DISCOVERY_TEST_KEY"
	const savedKey = "test-saved-secret-key"
	t.Setenv(keyEnv, savedKey)
	cases := []struct {
		name     string
		change   func(*modelcatalog.Connection, string)
		wantAuth string
	}{
		{name: "same connection", wantAuth: "Bearer " + savedKey},
		{name: "same origin different path", change: func(c *modelcatalog.Connection, _ string) { c.BaseURL += "/alternate" }, wantAuth: "Bearer " + savedKey},
		{name: "different provider", change: func(c *modelcatalog.Connection, _ string) { c.Provider = "moonshot" }},
		{name: "different protocol", change: func(c *modelcatalog.Connection, _ string) { c.Protocol = "responses" }},
		{name: "different origin", change: func(c *modelcatalog.Connection, other string) { c.BaseURL = other + "/v1" }},
		{name: "explicit ephemeral key", change: func(c *modelcatalog.Connection, other string) {
			c.BaseURL, c.APIKey = other+"/v1", "test-ephemeral-key"
		}, wantAuth: "Bearer test-ephemeral-key"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			headers := make(chan http.Header, 1)
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || !strings.HasSuffix(r.URL.Path, "/models") {
					t.Errorf("catalog request = %s %s", r.Method, r.URL.Path)
				}
				headers <- r.Header.Clone()
				_, _ = io.WriteString(w, `{"data":[{"id":"manual-model","name":"Manual model"}]}`)
			})
			srv := httptest.NewServer(handler)
			defer srv.Close()
			other := httptest.NewServer(handler)
			defer other.Close()
			cfg := modelProtocolConfig(t, "zhipu", srv.URL+"/v1")
			cfg.Model.APIKeyEnv = keyEnv
			svc := NewFromConfig(cfg)
			t.Cleanup(svc.Close)
			connection := modelcatalog.Connection{Provider: "zhipu", BaseURL: cfg.Model.BaseURL,
				Headers: map[string]string{"X-Catalog-Test": "unsaved-extension"}}
			if tc.change != nil {
				tc.change(&connection, other.URL)
			}
			response := svc.Handle(context.Background(), Request{Op: "model_catalog", Connection: &connection})
			if !response.OK || len(response.Catalog) != 1 || response.Catalog[0].ID != "manual-model" {
				t.Fatalf("model_catalog = %+v", response)
			}
			header := <-headers
			if header.Get("Authorization") != tc.wantAuth || header.Get("X-Catalog-Test") != "unsaved-extension" {
				t.Fatal("stored key crossed connection boundary or extension was lost")
			}
			data, err := json.Marshal(response)
			if err != nil || strings.Contains(string(data), savedKey) || strings.Contains(string(data), "test-ephemeral-key") {
				t.Fatal("catalog response must not include credentials")
			}
			if connection.APIKey == savedKey {
				t.Fatal("ephemeral connection mutated with stored key")
			}
		})
	}
}

func TestModelCatalogRequiresConnection(t *testing.T) {
	t.Parallel()
	svc := New(modelProtocolConfig(t, "openai", "https://example.com/v1"), nil, nil, nil)
	response := svc.Handle(context.Background(), Request{Op: "model_catalog"})
	if response.OK || response.ErrorCode != CodeBadRequest {
		t.Fatalf("model_catalog = %+v", response)
	}
}

func TestModelCatalogOriginMatchesSwiftDefaultPortNormalization(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		left, right string
		want        bool
	}{
		{"https://api.example.com/v1", "https://API.example.com:443/other", true},
		{"http://api.example.com/v1", "http://api.example.com:80/other", true},
		{"https://api.example.com:0443/v1", "https://api.example.com/other", true},
		{"http://[::1]/v1", "http://[::1]:80/other", true},
		{"https://api.example.com:8443/v1", "https://api.example.com/other", false},
		{"http://api.example.com/v1", "https://api.example.com/other", false},
		{"https://secret@api.example.com/v1", "https://api.example.com/other", false},
		{"https://api.example.com/v1", "https://other.example.com/v1", false},
		{"invalid", "invalid", false},
	} {
		if got := sameModelOrigin(tc.left, tc.right); got != tc.want {
			t.Errorf("sameModelOrigin(%q, %q) = %v, want %v", tc.left, tc.right, got, tc.want)
		}
	}
}
