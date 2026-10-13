// Package config loads ~/.tact/config.json. The same file also carries an
// "app" section that only the macOS companion app reads.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	Socket string `json:"socket"`
	// Adapter is a platform's command and limits, from its manifest; it is
	// not read from the file.
	Adapter AdapterConfig `json:"-"`
	// Platforms are the imported chat tool plugins; none means no chat tool.
	Platforms []PlatformConfig `json:"platforms"`
	Model     ModelConfig      `json:"model"`
	Context   ContextConfig    `json:"context"`
	Style     StyleConfig      `json:"style"`
	Feedback  FeedbackConfig   `json:"feedback"`
	App       json.RawMessage  `json:"app,omitempty"`
}

// PlatformConfig identifies one installed platform plugin instance.
type PlatformConfig struct {
	ID       string          `json:"id"`
	Manifest string          `json:"manifest"`
	Enabled  bool            `json:"enabled"`
	Command  []string        `json:"command,omitempty"`
	Desktop  json.RawMessage `json:"desktop,omitempty"`
}

type AdapterConfig struct {
	// Command is the adapter executable plus fixed leading arguments. The
	// engine appends the operation ("chats", "history <id> <limit>",
	// "drafts").
	Command           []string `json:"command"`
	TimeoutMS         int      `json:"timeout_ms"`
	ChatsCacheSeconds int      `json:"chats_cache_seconds"`
}

type ModelConfig struct {
	// Provider is "" (or "openai") for any OpenAI-compatible
	// /chat/completions endpoint with an API key, "chatgpt" for the
	// Responses API with a ChatGPT sign-in, billed to the user's plan, or
	// "local" for a downloaded model run by the bundled llama-server.
	Provider        string   `json:"provider"`
	BaseURL         string   `json:"base_url"`
	Model           string   `json:"model"`
	APIKeyEnv       string   `json:"api_key_env"`
	TimeoutMS       int      `json:"timeout_ms"`
	Temperature     *float64 `json:"temperature"`
	MaxTokens       int      `json:"max_tokens"`
	JSONMode        bool     `json:"json_mode"`
	AppendNoThink   bool     `json:"append_no_think"`
	AllowedBaseURLs []string `json:"allowed_base_urls"`
	// ReasoningEffort ("low", "medium", "high", ...) is sent as
	// reasoning.effort (Responses) or reasoning_effort (Chat Completions);
	// empty leaves the model's default. Which values work depends on the
	// model.
	ReasoningEffort string `json:"reasoning_effort"`
	// ServiceTier "priority" asks for Fast mode: quicker answers that use
	// more of the plan or cost more. Empty is the standard tier.
	ServiceTier string `json:"service_tier"`
	// ExtraBody is merged into every request for provider-specific switches,
	// e.g. {"thinking": {"type": "disabled"}} for DeepSeek.
	ExtraBody map[string]any `json:"extra_body"`
	Local     LocalModel     `json:"local"`
}

// LocalModel is a downloaded model for the "local" provider.
type LocalModel struct {
	// Path is the model's .gguf file.
	Path string `json:"path"`
	// Server is llama-server; empty means the one next to the engine.
	Server      string `json:"server"`
	ContextSize int    `json:"context_size"`
}

type ContextConfig struct {
	HistoryLimit       int `json:"history_limit"`
	MaxMessageChars    int `json:"max_message_chars"`
	MaxSuggestionChars int `json:"max_suggestion_chars"`
	// HistoryCacheSeconds is how long messages fetched by "prepare" (the
	// app prefetching while a chat is open) are reused by "suggest". 0
	// always fetches fresh.
	HistoryCacheSeconds int `json:"history_cache_seconds"`
}

type StyleConfig struct {
	File           string            `json:"file"`
	DefaultSection string            `json:"default_section"`
	ChatSections   map[string]string `json:"chat_sections"`
}

type FeedbackConfig struct {
	File         string `json:"file"`
	LogPlaintext bool   `json:"log_plaintext"`
}

// Dir is the per-user state directory (~/.tact).
func Dir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		home = "."
	}
	return filepath.Join(home, ".tact")
}

// DefaultPath honours $TACT_CONFIG, otherwise ~/.tact/config.json.
func DefaultPath() string {
	if p := os.Getenv("TACT_CONFIG"); p != "" {
		return ExpandHome(p)
	}
	return filepath.Join(Dir(), "config.json")
}

func Default() Config {
	t := 0.3
	return Config{
		Socket: filepath.Join(Dir(), "engine.sock"),
		Adapter: AdapterConfig{
			TimeoutMS:         3000,
			ChatsCacheSeconds: 30,
		},
		Model: ModelConfig{
			BaseURL:         "http://127.0.0.1:11434/v1",
			Model:           "qwen2.5:7b",
			TimeoutMS:       20000,
			Temperature:     &t,
			MaxTokens:       300,
			AllowedBaseURLs: []string{"http://127.0.0.1:11434", "http://localhost:11434"},
		},
		Context: ContextConfig{
			HistoryLimit:        20,
			MaxMessageChars:     500,
			MaxSuggestionChars:  300,
			HistoryCacheSeconds: 20,
		},
		Style: StyleConfig{
			File:           filepath.Join(Dir(), "style.md"),
			DefaultSection: "工作聊天",
		},
		Feedback: FeedbackConfig{
			File: filepath.Join(Dir(), "feedback.jsonl"),
		},
	}
}

// Load reads the file at path on top of the defaults. Fields missing from the
// file keep their default values.
func Load(path string) (Config, error) {
	cfg := Default()
	path = ExpandHome(path)
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("读取配置 %s 失败：%w", path, err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("配置 %s 不是合法的 JSON：%w", path, err)
	}
	cfg.expand()
	absolutePath, err := filepath.Abs(path)
	if err != nil {
		return cfg, fmt.Errorf("解析配置路径失败：%w", err)
	}
	for i := range cfg.Platforms {
		manifest := cfg.Platforms[i].Manifest
		if manifest != "" && !filepath.IsAbs(manifest) {
			cfg.Platforms[i].Manifest = filepath.Join(filepath.Dir(absolutePath), manifest)
		}
	}
	return cfg, cfg.Validate()
}

func (c *Config) expand() {
	c.Socket = ExpandHome(c.Socket)
	c.Style.File = ExpandHome(c.Style.File)
	c.Feedback.File = ExpandHome(c.Feedback.File)
	c.Model.Local.Path = ExpandHome(c.Model.Local.Path)
	c.Model.Local.Server = ExpandHome(c.Model.Local.Server)
	for i := range c.Platforms {
		c.Platforms[i].Manifest = ExpandHome(c.Platforms[i].Manifest)
		for j, a := range c.Platforms[i].Command {
			c.Platforms[i].Command[j] = ExpandHome(a)
		}
	}
	if c.Model.TimeoutMS <= 0 {
		c.Model.TimeoutMS = 20000
	}
	if c.Context.HistoryLimit <= 0 {
		c.Context.HistoryLimit = 20
	}
	if c.Context.MaxMessageChars <= 0 {
		c.Context.MaxMessageChars = 500
	}
	if c.Context.MaxSuggestionChars <= 0 {
		c.Context.MaxSuggestionChars = 300
	}
}

// Validate checks the settings the engine cannot run without.
func (c Config) Validate() error {
	var problems []string
	if strings.TrimSpace(c.Model.Model) == "" {
		problems = append(problems, "model.model 不能为空")
	}
	switch c.Model.Provider {
	case "", "openai", "chatgpt":
	case "local":
		if strings.TrimSpace(c.Model.Local.Path) == "" {
			problems = append(problems, "本机模型需要 model.local.path（下载好的 .gguf 文件）")
		}
	default:
		problems = append(problems, fmt.Sprintf("model.provider 只能是 openai、chatgpt 或 local，现在是 %q", c.Model.Provider))
	}
	// A local model never leaves the machine; there is no endpoint to allow.
	if c.Model.Provider != "local" && !BaseURLAllowed(c.Model.BaseURL, c.Model.AllowedBaseURLs) {
		problems = append(problems, fmt.Sprintf("model.base_url %q 不在 model.allowed_base_urls 白名单里", c.Model.BaseURL))
	}
	// sockaddr_un.sun_path is 104 bytes on macOS, including the trailing NUL.
	if len(c.Socket) >= 104 {
		problems = append(problems, fmt.Sprintf("socket 路径太长（%d 字节，macOS 上限 103）", len(c.Socket)))
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "；"))
	}
	return nil
}

// BaseURLAllowed reports whether base sits under one of the allowed URL
// prefixes: same scheme, same host and port, and a path at or below the
// allowed path.
func BaseURLAllowed(base string, allowed []string) bool {
	b, err := url.Parse(strings.TrimSpace(base))
	if err != nil || b.Host == "" || (b.Scheme != "http" && b.Scheme != "https") {
		return false
	}
	bp := strings.TrimSuffix(b.Path, "/")
	for _, a := range allowed {
		u, err := url.Parse(strings.TrimSpace(a))
		if err != nil || u.Host == "" {
			continue
		}
		if !strings.EqualFold(u.Scheme, b.Scheme) || !strings.EqualFold(u.Host, b.Host) {
			continue
		}
		ap := strings.TrimSuffix(u.Path, "/")
		if ap == "" || bp == ap || strings.HasPrefix(bp, ap+"/") {
			return true
		}
	}
	return false
}

func ExpandHome(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, strings.TrimPrefix(p, "~"))
		}
	}
	return p
}
