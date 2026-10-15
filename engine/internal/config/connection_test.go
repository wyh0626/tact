package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wyh0626/tact/engine/internal/reasoning"
)

func TestEffectiveProtocolRetainsLegacyAndSupportsServicePresets(t *testing.T) {
	t.Parallel()
	cases := []struct{ provider, protocol, want string }{
		{"", "", "openai"}, {"openai", "", "openai"}, {"deepseek", "", "openai"},
		{"anthropic", "", "anthropic"}, {"gemini", "", "gemini"},
		{"chatgpt", "", "chatgpt"}, {"local", "", "local"},
		{"zhipu", "", "openai"}, {"moonshot", "", "openai"}, {"qwen", "", "openai"},
		{"doubao", "", "openai"}, {"siliconflow", "", "openai"}, {"openrouter", "", "openai"}, {"minimax", "", "openai"},
		{"custom", "openai", "openai"}, {"custom", "responses", "responses"},
		{"custom", "anthropic", "anthropic"}, {"custom", "gemini", "gemini"},
		{"anthropic", "openai", "openai"}, {"gemini", "responses", "responses"},
	}
	for _, tc := range cases {
		t.Run(tc.provider+"/"+tc.protocol, func(t *testing.T) {
			t.Parallel()
			cfg := Default()
			cfg.Model.Provider, cfg.Model.Protocol = tc.provider, tc.protocol
			if tc.provider == "local" {
				cfg.Model.Local.Path = "/tmp/test.gguf"
			}
			if got := cfg.Model.EffectiveProtocol(); got != tc.want {
				t.Fatalf("EffectiveProtocol = %q, want %q", got, tc.want)
			}
			if err := cfg.Validate(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestConnectionProtocolValidationUsesProtocolRatherThanBrand(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name      string
		configure func(*ModelConfig)
		want      string
	}{
		{"unknown protocol", func(m *ModelConfig) { m.Protocol = "other" }, "model.protocol"},
		{"ChatGPT protocol override", func(m *ModelConfig) { m.Provider, m.Protocol = "chatgpt", "responses" }, "不能设置"},
		{"local protocol override", func(m *ModelConfig) { m.Provider, m.Protocol, m.Local.Path = "local", "openai", "/tmp/test.gguf" }, "不能设置"},
		{"custom Claude output limit", func(m *ModelConfig) { m.Provider, m.Protocol, m.MaxTokens = "custom", "anthropic", 0 }, "max_tokens"},
		{"custom Claude generic effort", func(m *ModelConfig) { m.Provider, m.Protocol, m.ReasoningEffort = "custom", "anthropic", "high" }, "model.reasoning_effort"},
		{"custom Gemini wrong format", func(m *ModelConfig) {
			m.Provider, m.Protocol = "custom", "gemini"
			m.Reasoning = &reasoning.Config{Format: "openai", Effort: "high"}
		}, "format"},
		{"Responses wrong format", func(m *ModelConfig) {
			m.Protocol = "responses"
			m.Reasoning = &reasoning.Config{Format: "thinking", Effort: "enabled"}
		}, "format"},
		{"reserved header", func(m *ModelConfig) { m.Headers = map[string]string{"Authorization": "wrong"} }, "请求头"},
		{"header injection", func(m *ModelConfig) { m.Headers = map[string]string{"X-User": "test\r\nAuthorization: wrong"} }, "请求头"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := Default()
			tc.configure(&cfg.Model)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate = %v, want %q", err, tc.want)
			}
		})
	}
}

func TestConnectionLoadPreservesProtocolHeadersAndAdvancedBody(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "config.json")
	body := `{"model":{"provider":"custom","protocol":"anthropic","headers":{"Anthropic-Beta":"test-beta"},"extra_body":{"metadata":{"tag":"test"},"output_config":{"effort":"low"}}}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Model.EffectiveProtocol() != "anthropic" || cfg.Model.Headers["Anthropic-Beta"] != "test-beta" {
		t.Fatal("protocol or custom header not loaded")
	}
	encoded, err := json.Marshal(cfg.Model)
	if err != nil || !strings.Contains(string(encoded), `"metadata":{"tag":"test"}`) {
		t.Fatal("advanced fields not retained")
	}
}

func TestEndpointCannotHideCredentialsOrQuery(t *testing.T) {
	t.Parallel()
	for _, address := range []string{
		"https://secret@example.com/v1", "https://example.com/v1?api_key=secret", "https://example.com/v1#fragment",
	} {
		if BaseURLAllowed(address, []string{"https://example.com"}) {
			t.Fatal("invalid endpoint accepted")
		}
	}
}
