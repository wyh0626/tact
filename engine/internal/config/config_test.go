package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wyh0626/tact/engine/internal/reasoning"
)

func TestChatToolsComeOnlyFromPlatforms(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name  string
		body  string
		count int
	}{
		{name: "no chat tool", body: `{}`},
		{name: "an old adapter section is ignored", body: `{"adapter":{"command":["python3","adapter.py"]}}`},
		{name: "empty registry", body: `{"platforms":[]}`},
		{name: "a plugin", body: `{"platforms":[{"id":"example","manifest":"~/plugins/example/manifest.json","enabled":true}]}`, count: 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "config.json")
			if err := os.WriteFile(path, []byte(tc.body), 0o600); err != nil {
				t.Fatal(err)
			}
			cfg, err := Load(path)
			if err != nil {
				t.Fatalf("Load error = %v", err)
			}
			if len(cfg.Platforms) != tc.count || len(cfg.Adapter.Command) != 0 {
				t.Fatalf("platforms = %+v, adapter = %+v", cfg.Platforms, cfg.Adapter)
			}
			if data, err := json.Marshal(cfg); err != nil || strings.Contains(string(data), `"adapter"`) {
				t.Fatalf("the adapter section is never written back: %s %v", data, err)
			}
			if tc.count > 0 && strings.HasPrefix(cfg.Platforms[0].Manifest, "~") {
				t.Fatalf("manifest home was not expanded: %q", cfg.Platforms[0].Manifest)
			}
		})
	}
}

func TestLoadStructuredReasoningRetainsRawOptions(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "config.json")
	body := `{"model":{"provider":"anthropic","model":"claude-sonnet-4-6","reasoning":{"format":"anthropic_budget","effort":"enabled","budget_tokens":2048},"extra_body":{"metadata":{"user_id":"local-test"},"output_config":{"format":{"type":"json_schema"}}}}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := cfg.Model.Reasoning; got == nil || got.Format != "anthropic_budget" || got.Effort != "enabled" || got.BudgetTokens != 2048 {
		t.Fatalf("reasoning = %#v", got)
	}
	if _, ok := cfg.Model.ExtraBody["output_config"]; !ok {
		t.Fatal("load lost raw structured-output options")
	}
	cfg.Model.Reasoning = &reasoning.Config{Format: "gemini_level", Effort: "high"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "format") {
		t.Fatalf("Validate incompatible reasoning = %v", err)
	}
}

func TestLoadResolvesRelativePlatformManifest(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	body := `{"platforms":[{"id":"chat","manifest":"plugins/chat/manifest.json","enabled":true}]}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "plugins", "chat", "manifest.json")
	if cfg.Platforms[0].Manifest != want {
		t.Fatalf("manifest = %q, want %q", cfg.Platforms[0].Manifest, want)
	}
}

func TestBaseURLAllowed(t *testing.T) {
	allowed := []string{"http://127.0.0.1:11434", "https://llm.example.internal/v1"}
	cases := map[string]bool{
		"http://127.0.0.1:11434/v1":            true,
		"http://127.0.0.1:11434":               true,
		"http://127.0.0.1:8080/v1":             false,
		"https://llm.example.internal/v1":      true,
		"https://llm.example.internal/v1/":     true,
		"https://llm.example.internal/v2":      false,
		"https://llm.example.internal/v10":     false,
		"https://api.openai.com/v1":            false,
		"http://llm.example.internal/v1":       false,
		"ftp://127.0.0.1:11434":                false,
		"https://llm.example.internal.evil/v1": false,
	}
	for u, want := range cases {
		if got := BaseURLAllowed(u, allowed); got != want {
			t.Errorf("BaseURLAllowed(%q) = %v, want %v", u, got, want)
		}
	}
}

func TestLoadOverlaysDefaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	body := `{
	  "adapter": {"command": ["python3", "x.py"]},
	  "model": {"model": "qwen3:8b", "temperature": 0},
	  "app": {"hotkey": "option+space"}
	}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Model.Model != "qwen3:8b" || cfg.Model.BaseURL != "http://127.0.0.1:11434/v1" {
		t.Fatalf("model config not overlaid: %+v", cfg.Model)
	}
	if cfg.Model.Temperature == nil || *cfg.Model.Temperature != 0 {
		t.Fatalf("explicit temperature 0 lost")
	}
	if cfg.Context.HistoryLimit != 20 {
		t.Fatalf("defaults lost: %+v", cfg.Context)
	}
}

func TestLoadRejectsUnlistedModel(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	body := `{"adapter": {"command": ["x"]}, "model": {"base_url": "https://api.example.com/v1"}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil {
		t.Fatal("a base_url outside the allowlist must be rejected")
	}
}

func TestValidateProvider(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		provider string
		wantErr  bool
	}{
		{name: "legacy default"},
		{name: "OpenAI", provider: "openai"},
		{name: "DeepSeek", provider: "deepseek"},
		{name: "Anthropic", provider: "anthropic"},
		{name: "Gemini", provider: "gemini"},
		{name: "ChatGPT account", provider: "chatgpt"},
		{name: "unknown provider", provider: "claude", wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := Default()
			cfg.Model.Provider = tc.provider
			err := cfg.Validate()
			if tc.wantErr {
				if err == nil || !strings.Contains(err.Error(), "model.provider") {
					t.Fatalf("Validate() = %v, want a provider error", err)
				}
			} else if err != nil {
				t.Fatalf("Validate() = %v, want no error", err)
			}
		})
	}
}

func TestNativeProvidersRequireAllowedEndpoint(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name     string
		provider string
		baseURL  string
	}{
		{name: "Anthropic", provider: "anthropic", baseURL: "https://api.anthropic.com"},
		{name: "Gemini", provider: "gemini", baseURL: "https://generativelanguage.googleapis.com"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := Default()
			cfg.Model.Provider = tc.provider
			cfg.Model.BaseURL = tc.baseURL
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "model.allowed_base_urls") {
				t.Fatalf("Validate() = %v, want an endpoint allowlist error", err)
			}
			cfg.Model.AllowedBaseURLs = []string{tc.baseURL}
			if err := cfg.Validate(); err != nil {
				t.Fatalf("Validate() = %v after allowing the endpoint", err)
			}
		})
	}
}

func TestNativeProviderParameterCompatibility(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name      string
		provider  string
		configure func(*ModelConfig)
		wantErr   string
	}{
		{name: "Anthropic valid", provider: "anthropic"},
		{name: "Anthropic JSON mode", provider: "anthropic", configure: func(m *ModelConfig) { m.JSONMode = true }, wantErr: "model.json_mode"},
		{name: "Anthropic missing output limit", provider: "anthropic", configure: func(m *ModelConfig) { m.MaxTokens = 0 }, wantErr: "model.max_tokens"},
		{name: "Anthropic negative output limit", provider: "anthropic", configure: func(m *ModelConfig) { m.MaxTokens = -1 }, wantErr: "model.max_tokens"},
		{name: "Anthropic unsupported effort", provider: "anthropic", configure: func(m *ModelConfig) { m.ReasoningEffort = "high" }, wantErr: "model.reasoning_effort"},
		{name: "Anthropic unsupported tier", provider: "anthropic", configure: func(m *ModelConfig) { m.ServiceTier = "priority" }, wantErr: "model.service_tier"},
		{name: "Gemini JSON mode", provider: "gemini", configure: func(m *ModelConfig) { m.JSONMode = true }},
		{name: "Gemini default output limit", provider: "gemini", configure: func(m *ModelConfig) { m.MaxTokens = 0 }},
		{name: "Gemini unsupported effort", provider: "gemini", configure: func(m *ModelConfig) { m.ReasoningEffort = "high" }, wantErr: "model.reasoning_effort"},
		{name: "Gemini unsupported tier", provider: "gemini", configure: func(m *ModelConfig) { m.ServiceTier = "priority" }, wantErr: "model.service_tier"},
		{name: "native extra body", provider: "anthropic", configure: func(m *ModelConfig) { m.ExtraBody = map[string]any{"thinking": map[string]any{"type": "disabled"}} }},
		{name: "legacy settings preserved", provider: "", configure: func(m *ModelConfig) {
			m.JSONMode, m.MaxTokens, m.ReasoningEffort, m.ServiceTier = true, 0, "high", "priority"
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := Default()
			cfg.Model.Provider = tc.provider
			if tc.configure != nil {
				tc.configure(&cfg.Model)
			}
			err := cfg.Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("Validate() = %v, want no error", err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("Validate() = %v, want error containing %q", err, tc.wantErr)
			}
		})
	}
}

func TestLocalProviderNeedsAModelFileButNoEndpoint(t *testing.T) {
	cfg := Default()
	cfg.Adapter.Command = []string{"x"}
	cfg.Model.Provider = "local"
	cfg.Model.BaseURL = ""
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "model.local.path") {
		t.Fatalf("want a missing model error, got %v", err)
	}
	cfg.Model.Local.Path = "/models/qwen.gguf"
	if err := cfg.Validate(); err != nil {
		t.Fatalf("a local model needs no endpoint or allowlist: %v", err)
	}
}

func TestLocalModelPathsExpandHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	path := filepath.Join(t.TempDir(), "config.json")
	body := `{"socket":"/tmp/tact-test.sock","adapter":{"command":["x"]},"model":{"provider":"local","model":"qwen3-4b",
		"local":{"path":"~/.tact/models/q.gguf","server":"~/bin/llama-server"}}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Model.Local.Path != filepath.Join(home, ".tact/models/q.gguf") || cfg.Model.Local.Server != filepath.Join(home, "bin/llama-server") {
		t.Fatalf("local = %+v", cfg.Model.Local)
	}
}
