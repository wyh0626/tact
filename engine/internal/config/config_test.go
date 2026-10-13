package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
	cfg := Default()
	cfg.Adapter.Command = []string{"x"}
	for _, provider := range []string{"", "openai", "chatgpt"} {
		cfg.Model.Provider = provider
		if err := cfg.Validate(); err != nil {
			t.Fatalf("provider %q: %v", provider, err)
		}
	}
	cfg.Model.Provider = "claude"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "model.provider") {
		t.Fatalf("want a provider error, got %v", err)
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
