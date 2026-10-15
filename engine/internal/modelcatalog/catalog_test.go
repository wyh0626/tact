package modelcatalog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestDiscoverProtocols(t *testing.T) {
	for _, tc := range []struct {
		name, protocol, basePath, path, authName, authValue, body string
	}{
		{"chat", "openai", "/proxy/v1/", "/proxy/v1/models", "Authorization", "Bearer catalog-key", `{"data":[{"id":"text-model"}]}`},
		{"responses", "responses", "/v1", "/v1/models", "Authorization", "Bearer catalog-key", `{"data":[{"id":"text-model"}]}`},
		{"claude", "anthropic", "/proxy/v1/", "/proxy/v1/models", "x-api-key", "catalog-key", `{"data":[{"id":"text-model","display_name":"Text Model"}],"has_more":false}`},
		{"gemini", "gemini", "/proxy", "/proxy/v1beta/models", "x-goog-api-key", "catalog-key", `{"models":[{"name":"models/text-model","supportedGenerationMethods":["generateContent"]}]}`},
		{"gemini v1", "gemini", "/proxy/v1/", "/proxy/v1/models", "x-goog-api-key", "catalog-key", `{"models":[{"name":"models/text-model"}]}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != tc.path {
					t.Errorf("request = %s %s", r.Method, r.URL.Path)
				}
				if got := r.Header.Get(tc.authName); got != tc.authValue {
					t.Errorf("auth = %q", got)
				}
				if r.URL.Query().Has("key") || r.Header.Get("X-Workspace") != "workspace" {
					t.Error("custom header missing or key exposed in query")
				}
				if tc.protocol == "anthropic" && r.Header.Get("anthropic-version") != "2023-06-01" {
					t.Error("anthropic version missing")
				}
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			models, err := Discover(context.Background(), Connection{
				Provider: "custom", Protocol: tc.protocol, BaseURL: server.URL + tc.basePath,
				APIKey: "catalog-key", Headers: map[string]string{"X-Workspace": "workspace"},
			}, nil)
			if err != nil || len(models) != 1 || models[0].ID != "text-model" {
				t.Fatalf("models = %#v, err = %v", models, err)
			}
			if models[0].Capabilities != nil {
				t.Fatalf("model ID alone must not infer capabilities: %#v", models[0].Capabilities)
			}
		})
	}
}

func TestDiscoverClaudeCapabilitiesAndPagination(t *testing.T) {
	var calls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/v1/models" || r.URL.Query().Get("limit") != "1000" {
			t.Errorf("unexpected URL %s", r.URL)
		}
		if calls == 1 {
			fmt.Fprint(w, `{"data":[{"id":"future-model","display_name":"Future Model","max_tokens":64000,"capabilities":{"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"max":{"supported":false}},"thinking":{"supported":true,"types":{"adaptive":{"supported":true},"enabled":{"supported":false},"disabled":{"supported":false}}}}}],"has_more":true,"last_id":"future-model"}`)
			return
		}
		if r.URL.Query().Get("after_id") != "future-model" {
			t.Errorf("cursor = %q", r.URL.Query().Get("after_id"))
		}
		fmt.Fprint(w, `{"data":[{"id":"future-model"},{"id":"budget-model","capabilities":{"effort":{"supported":false},"thinking":{"supported":true,"types":{"adaptive":{"supported":false},"enabled":{"supported":true},"disabled":{"supported":true}}}}},{"id":"no-thinking","capabilities":{"effort":{"supported":false},"thinking":{"supported":false,"types":{"enabled":{"supported":false},"disabled":{"supported":true}}}}}],"has_more":false}`)
	}))
	defer server.Close()
	models, err := Discover(context.Background(), Connection{Provider: "anthropic", BaseURL: server.URL, APIKey: "key"}, nil)
	if err != nil || len(models) != 3 || calls != 2 {
		t.Fatalf("models = %#v, calls = %d, err = %v", models, calls, err)
	}
	capability := models[0].Capabilities
	if models[0].Name != "Future Model" || capability.ReasoningFormat != "anthropic_effort" || capability.ReasoningSupported == nil || !*capability.ReasoningSupported || capability.CanDisable == nil || *capability.CanDisable || capability.MaxOutputTokens == nil || *capability.MaxOutputTokens != 64000 {
		t.Fatalf("capability = %#v", capability)
	}
	if capability.EffortLevels == nil || !reflect.DeepEqual(*capability.EffortLevels, []string{"low", "medium", "high"}) || capability.ThinkingTypes == nil || !reflect.DeepEqual(*capability.ThinkingTypes, []string{"adaptive"}) {
		t.Fatalf("levels/types = %#v", capability)
	}
	if models[1].Capabilities.ReasoningFormat != "anthropic_budget" || !*models[1].Capabilities.CanDisable {
		t.Fatalf("budget capability = %#v", models[1].Capabilities)
	}
	if models[2].Capabilities.ReasoningSupported == nil || *models[2].Capabilities.ReasoningSupported {
		t.Fatalf("explicit unsupported was lost: %#v", models[2].Capabilities)
	}
}

func TestClaudePartialEffortMetadataPreservesUnknownLevels(t *testing.T) {
	for _, tc := range []struct {
		name, effort string
		want         []string
		unknown      bool
	}{
		{name: "support without level flags", effort: `{"supported":true}`, unknown: true},
		{name: "unsupported without level flags", effort: `{"supported":false}`, want: []string{}},
		{name: "reported accepted level", effort: `{"supported":true,"high":{"supported":true},"low":{"supported":false}}`, want: []string{"high"}},
		{name: "reported rejected level", effort: `{"low":{"supported":false}}`, want: []string{}},
		{name: "null level remains unknown", effort: `{"supported":true,"high":{"supported":null}}`, unknown: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := []byte(`{"data":[{"id":"partial-model","capabilities":{"effort":` + tc.effort + `}}]}`)
			models, _, err := parsePage("anthropic", "anthropic", body)
			if err != nil || len(models) != 1 || models[0].Capabilities == nil {
				t.Fatalf("models = %#v, err = %v", models, err)
			}
			levels := models[0].Capabilities.EffortLevels
			if tc.unknown {
				if levels != nil {
					t.Fatalf("missing effort flags became authoritative levels: %v", *levels)
				}
			} else if levels == nil || !reflect.DeepEqual(*levels, tc.want) {
				t.Fatalf("effort levels = %v, want %v", levels, tc.want)
			}
			encoded, err := json.Marshal(models[0].Capabilities)
			if err != nil || strings.Contains(string(encoded), `"effort_levels"`) == tc.unknown {
				t.Fatalf("effort presence in JSON = %s, unknown = %v, err = %v", encoded, tc.unknown, err)
			}
		})
	}
}

func TestDiscoverGeminiCapabilitiesAndPagination(t *testing.T) {
	var calls int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			fmt.Fprint(w, `{"models":[{"name":"models/thinking-model","displayName":"Thinking Model","thinking":true,"outputTokenLimit":32000,"supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/embedding","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"token?https://example.org/key"}`)
			return
		}
		if r.URL.Path != "/v1beta/models" || r.URL.Query().Get("pageToken") != "token?https://example.org/key" {
			t.Errorf("pagination must keep its origin/path: %s", r.URL)
		}
		fmt.Fprint(w, `{"models":[{"name":"models/no-thinking","thinking":false,"supportedGenerationMethods":["generateContent"]},{"name":"models/unknown-thinking","supportedGenerationMethods":["generateContent"]}]}`)
	}))
	defer server.Close()
	models, err := Discover(context.Background(), Connection{Provider: "gemini", BaseURL: server.URL}, nil)
	if err != nil || len(models) != 3 || calls != 2 {
		t.Fatalf("models = %#v, calls = %d, err = %v", models, calls, err)
	}
	capability := models[0].Capabilities
	if capability.ReasoningSupported == nil || !*capability.ReasoningSupported || capability.EffortLevels != nil || capability.ReasoningFormat != "" || *capability.MaxOutputTokens != 32000 {
		t.Fatalf("must only expose declared Gemini metadata: %#v", capability)
	}
	if models[1].Capabilities.ReasoningSupported == nil || *models[1].Capabilities.ReasoningSupported || models[2].Capabilities != nil {
		t.Fatalf("false vs unknown lost: %#v", models)
	}
}

func TestDiscoverOpenRouterCapabilities(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"data":[{"id":"provider/thinking","name":"Thinking","reasoning":{"supported_efforts":["high","medium","low","none"],"mandatory":true}},{"id":"provider/all-efforts","reasoning":{"supported_efforts":null,"mandatory":false}},{"id":"provider/budget-only","reasoning":{"supports_max_tokens":true}},{"id":"provider/no-thinking","supported_parameters":["temperature","max_tokens"]}]}`)
	}))
	defer server.Close()
	models, err := Discover(context.Background(), Connection{Provider: "openrouter", BaseURL: server.URL}, nil)
	if err != nil || len(models) != 4 {
		t.Fatalf("models = %#v, err = %v", models, err)
	}
	first := models[0].Capabilities
	if first.ReasoningFormat != "reasoning" || first.CanDisable == nil || *first.CanDisable || !reflect.DeepEqual(*first.EffortLevels, []string{"high", "medium", "low"}) {
		t.Fatalf("mandatory model = %#v", first)
	}
	if !reflect.DeepEqual(*models[1].Capabilities.EffortLevels, []string{"none", "minimal", "low", "medium", "high", "xhigh", "max"}) {
		t.Fatalf("null effort capability = %#v", models[1].Capabilities)
	}
	if models[2].Capabilities.EffortLevels != nil || *models[3].Capabilities.ReasoningSupported {
		t.Fatalf("omitted efforts/nonreasoning = %#v", models)
	}
}

func TestDiscoverPreservesClientAndBlocksRedirect(t *testing.T) {
	var leaked atomic.Int32
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked.Add(1) }))
	defer other.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL, http.StatusTemporaryRedirect)
	}))
	defer server.Close()
	client := &http.Client{Timeout: time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return nil }}
	_, err := Discover(context.Background(), Connection{BaseURL: server.URL, APIKey: "secret-key"}, client)
	if err == nil || leaked.Load() != 0 || client.Timeout != time.Second || client.CheckRedirect == nil {
		t.Fatalf("redirect/client policy: leaked = %d, err = %v", leaked.Load(), err)
	}
}

func TestDiscoverTimeoutAndCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()
	_, err := Discover(context.Background(), Connection{BaseURL: server.URL}, &http.Client{Timeout: 30 * time.Millisecond})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("timeout = %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = Discover(ctx, Connection{BaseURL: server.URL}, nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation = %v", err)
	}
}

func TestDiscoverTimeoutIncludesResponseBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"data":[`)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	_, err := Discover(context.Background(), Connection{BaseURL: server.URL}, &http.Client{Timeout: 30 * time.Millisecond})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("body timeout = %v", err)
	}
}

func TestDiscoverRejectsBadResponses(t *testing.T) {
	for _, tc := range []struct {
		name, body, want string
		status           int
	}{
		{"status", `{"error":"echo secret-key"}`, "HTTP 401", 401},
		{"body limit", strings.Repeat(" ", maxBodyBytes+1), "4 MiB", 200},
		{"trailing JSON", `{"data":[]} {"data":[]}`, "JSON", 200},
		{"wrong envelope", `{"models":[]}`, "data", 200},
		{"wrong type", `{"data":{}}`, "data", 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			_, err := Discover(context.Background(), Connection{BaseURL: server.URL, APIKey: "secret-key"}, nil)
			if err == nil || !strings.Contains(err.Error(), tc.want) || strings.Contains(err.Error(), "secret-key") {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestDiscoverRejectsInvalidConnection(t *testing.T) {
	for _, tc := range []Connection{
		{BaseURL: ""}, {BaseURL: "file:///etc/passwd"},
		{BaseURL: "https://key@example.org/v1"}, {BaseURL: "https://example.org/v1?key=secret"},
		{BaseURL: "https://example.org/v1#fragment"}, {BaseURL: "https://example.org", Protocol: "unsupported"},
		{BaseURL: "https://example.org", Provider: "chatgpt"}, {BaseURL: "https://example.org", Provider: "local"},
		{BaseURL: "https://example.org", APIKey: "key\r\nInjected: value"},
		{BaseURL: "https://example.org", Headers: map[string]string{"Authorization": "Bearer key"}},
		{BaseURL: "https://example.org", Headers: map[string]string{"X-Test": "value\r\nInjected: value"}},
	} {
		if _, err := Discover(context.Background(), tc, nil); err == nil {
			t.Errorf("accepted invalid connection: %#v", tc)
		}
	}
}

func TestDiscoverPaginationBounds(t *testing.T) {
	for _, repeated := range []bool{false, true} {
		t.Run(fmt.Sprintf("repeated=%v", repeated), func(t *testing.T) {
			var calls int
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				cursor := fmt.Sprint(calls)
				if repeated {
					cursor = "same"
				}
				fmt.Fprintf(w, `{"data":[{"id":"model-%d"}],"has_more":true,"last_id":%q}`, calls, cursor)
			}))
			defer server.Close()
			_, err := Discover(context.Background(), Connection{Provider: "anthropic", BaseURL: server.URL}, nil)
			wantCalls := maxPages
			if repeated {
				wantCalls = 2
			}
			if err == nil || calls != wantCalls {
				t.Fatalf("calls = %d, err = %v", calls, err)
			}
		})
	}
	items := make([]Model, maxModels+1)
	for i := range items {
		items[i].ID = fmt.Sprintf("model-%d", i)
	}
	body, _ := json.Marshal(map[string]any{"data": items})
	if _, _, err := parsePage("openai", "custom", body); err == nil {
		t.Fatal("accepted oversized model list")
	}
}

func TestCapabilitiesJSONPreservesFalseAndEmpty(t *testing.T) {
	value := false
	levels := make([]string, 0)
	body, err := json.Marshal(Capabilities{Source: "api", ReasoningSupported: &value, EffortLevels: &levels})
	if err != nil || !strings.Contains(string(body), `"reasoning_supported":false`) || !strings.Contains(string(body), `"effort_levels":[]`) || strings.Contains(string(body), "can_disable") {
		t.Fatalf("JSON = %s, err = %v", body, err)
	}
}
