package model

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/wyh0626/tact/engine/internal/reasoning"
)

func TestClaudeReasoningWireParameters(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name           string
		config         reasoning.Config
		limit, wantCap int
		wantThinking   map[string]any
		wantEffort     any
		wantTemp       bool
	}{
		{name: "adaptive effort", config: reasoning.Config{Format: "anthropic_effort", Effort: "high"}, limit: 300, wantCap: 300,
			wantThinking: map[string]any{"type": "adaptive", "display": "omitted"}, wantEffort: "high"},
		{name: "new effort extension", config: reasoning.Config{Format: "anthropic_effort", Effort: "xhigh", ThinkingType: "adaptive"}, limit: 6000, wantCap: 6000,
			wantThinking: map[string]any{"type": "adaptive", "display": "omitted"}, wantEffort: "xhigh"},
		{name: "effort without thinking", config: reasoning.Config{Format: "anthropic_effort", Effort: "high", ThinkingType: "disabled"}, limit: 300, wantCap: 300,
			wantThinking: map[string]any{"type": "disabled"}, wantEffort: "high", wantTemp: true},
		{name: "budget raises insufficient cap", config: reasoning.Config{Format: "anthropic_budget", Effort: "enabled", BudgetTokens: 2048}, limit: 300, wantCap: 2348,
			wantThinking: map[string]any{"type": "enabled", "budget_tokens": float64(2048), "display": "omitted"}, wantEffort: "max"},
		{name: "budget preserves adequate cap", config: reasoning.Config{Format: "anthropic_budget", Effort: "enabled", BudgetTokens: 2048}, limit: 4096, wantCap: 4096,
			wantThinking: map[string]any{"type": "enabled", "budget_tokens": float64(2048), "display": "omitted"}, wantEffort: "max"},
		{name: "budget off retains independent effort", config: reasoning.Config{Format: "anthropic_budget", Effort: "none"}, limit: 300, wantCap: 300,
			wantThinking: map[string]any{"type": "disabled"}, wantEffort: "max", wantTemp: true},
		{name: "budget default retains independent effort", config: reasoning.Config{Format: "anthropic_budget"}, limit: 300, wantCap: 300,
			wantEffort: "max", wantTemp: true},
		{name: "thinking off", config: reasoning.Config{Format: "anthropic_effort", Effort: "none"}, limit: 300, wantCap: 300,
			wantThinking: map[string]any{"type": "disabled"}, wantTemp: true},
		{name: "between tools off", config: reasoning.Config{Format: "anthropic_effort", Effort: "none", ThinkingType: "between_tools"}, limit: 300, wantCap: 300,
			wantThinking: map[string]any{"type": "between_tools"}},
		{name: "explicit provider default", config: reasoning.Config{Format: "anthropic_effort"}, limit: 300, wantCap: 300,
			wantTemp: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, claudeOK)
			schema := map[string]any{"type": "json_schema", "schema": map[string]any{"type": "object"}}
			extra := map[string]any{
				"thinking":      map[string]any{"type": "enabled", "budget_tokens": 8192, "display": "omitted"},
				"output_config": map[string]any{"effort": "max", "format": schema},
				"metadata":      map[string]any{"user_id": "local-test"},
			}
			before, err := json.Marshal(extra)
			if err != nil {
				t.Fatal(err)
			}
			c := &Client{Provider: "anthropic", BaseURL: srv.URL, Model: "claude-test", APIKey: "test-key", MaxTokens: tt.limit,
				Temperature: .3, Reasoning: &tt.config, ExtraBody: extra}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
				t.Fatal(err)
			}
			body := (<-requests).body
			thinking, _ := body["thinking"].(map[string]any)
			if !reflect.DeepEqual(thinking, tt.wantThinking) {
				t.Errorf("thinking = %#v, want %#v", body["thinking"], tt.wantThinking)
			}
			output, _ := body["output_config"].(map[string]any)
			if output["effort"] != tt.wantEffort || !reflect.DeepEqual(output["format"], schema) {
				t.Errorf("output_config = %#v, want effort %#v and preserved schema", output, tt.wantEffort)
			}
			if body["max_tokens"] != float64(tt.wantCap) {
				t.Errorf("max_tokens = %v, want %d", body["max_tokens"], tt.wantCap)
			}
			if _, exists := body["temperature"]; exists != tt.wantTemp {
				t.Errorf("temperature present = %v, want %v", exists, tt.wantTemp)
			}
			after, err := json.Marshal(extra)
			if err != nil || string(after) != string(before) {
				t.Errorf("request mutated saved extra_body: %s -> %s (%v)", before, after, err)
			}
		})
	}
}

func TestOpus45EffortWithoutThinkingNativeAndCompatible(t *testing.T) {
	t.Parallel()
	for _, provider := range []string{"anthropic", "openai"} {
		t.Run(provider, func(t *testing.T) {
			t.Parallel()
			response := claudeOK
			if provider == "openai" {
				response = `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`
			}
			srv, requests := nativeServer(t, response)
			c := &Client{Provider: provider, BaseURL: srv.URL, Model: "claude-opus-4-5", APIKey: "test-key", MaxTokens: 300, Temperature: .3,
				Reasoning: &reasoning.Config{Format: "anthropic_effort", Effort: "low", ThinkingType: "disabled"},
				ExtraBody: map[string]any{"thinking": map[string]any{"type": "enabled", "budget_tokens": 8192, "display": "omitted"}}}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
				t.Fatal(err)
			}
			body := (<-requests).body
			if !reflect.DeepEqual(body["thinking"], map[string]any{"type": "disabled"}) || !reflect.DeepEqual(body["output_config"], map[string]any{"effort": "low"}) {
				t.Errorf("Opus4.5 effort parameters = %#v", body)
			}
			if body["temperature"] == nil || body["max_tokens"] != float64(300) {
				t.Errorf("Opus4.5 sampling or cap changed unexpectedly: %#v", body)
			}
		})
	}
}

func TestGeminiReasoningWireParameters(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name string
		cfg  reasoning.Config
		want map[string]any
	}{
		{"level", reasoning.Config{Format: "gemini_level", Effort: "medium"}, map[string]any{"includeThoughts": true, "thinkingLevel": "MEDIUM"}},
		{"budget", reasoning.Config{Format: "gemini_budget", Effort: "enabled", BudgetTokens: 2048}, map[string]any{"includeThoughts": true, "thinkingBudget": float64(2048)}},
		{"dynamic", reasoning.Config{Format: "gemini_budget", Effort: "enabled", BudgetTokens: -1}, map[string]any{"includeThoughts": true, "thinkingBudget": float64(-1)}},
		{"off", reasoning.Config{Format: "gemini_budget", Effort: "none"}, map[string]any{"includeThoughts": true, "thinkingBudget": float64(0)}},
		{"provider default", reasoning.Config{Format: "gemini_level"}, map[string]any{"includeThoughts": true}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, geminiOK)
			extra := map[string]any{"generationConfig": map[string]any{
				"thinkingConfig": map[string]any{"includeThoughts": true, "thinkingBudget": 4096, "thinkingLevel": "HIGH"},
				"responseSchema": map[string]any{"type": "OBJECT"}, "candidateCount": 1,
			}}
			before, err := json.Marshal(extra)
			if err != nil {
				t.Fatal(err)
			}
			c := &Client{Provider: "gemini", BaseURL: srv.URL, Model: "gemini-test", APIKey: "test-key", MaxTokens: 300, Reasoning: &tt.cfg, ExtraBody: extra}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
				t.Fatal(err)
			}
			generation, _ := (<-requests).body["generationConfig"].(map[string]any)
			if !reflect.DeepEqual(generation["thinkingConfig"], tt.want) {
				t.Errorf("thinkingConfig = %#v, want %#v", generation["thinkingConfig"], tt.want)
			}
			if generation["maxOutputTokens"] != float64(300) || generation["candidateCount"] != float64(1) {
				t.Errorf("generation options changed: %#v", generation)
			}
			if !reflect.DeepEqual(generation["responseSchema"], map[string]any{"type": "OBJECT"}) {
				t.Errorf("responseSchema lost: %#v", generation)
			}
			after, err := json.Marshal(extra)
			if err != nil || string(after) != string(before) {
				t.Errorf("request mutated saved extra_body: %s -> %s (%v)", before, after, err)
			}
		})
	}
}

func TestCompatibleReasoningExtensions(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name string
		cfg  reasoning.Config
		key  string
		want any
	}{
		{"openai", reasoning.Config{Format: "openai", Effort: "high"}, "reasoning_effort", "high"},
		{"openai off", reasoning.Config{Format: "openai", Effort: "none"}, "reasoning_effort", "none"},
		{"openrouter", reasoning.Config{Format: "reasoning", Effort: "low"}, "reasoning", map[string]any{"effort": "low", "exclude": true}},
		{"deepseek", reasoning.Config{Format: "deepseek", Effort: "max"}, "thinking", map[string]any{"type": "enabled"}},
		{"deepseek off", reasoning.Config{Format: "deepseek", Effort: "none"}, "thinking", map[string]any{"type": "disabled"}},
		{"claude extension", reasoning.Config{Format: "anthropic_effort", Effort: "medium"}, "output_config", map[string]any{"effort": "medium"}},
		{"gemini extension", reasoning.Config{Format: "gemini_level", Effort: "low"}, "generationConfig", map[string]any{"thinkingConfig": map[string]any{"thinkingLevel": "LOW"}}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`)
			c := &Client{BaseURL: srv.URL, Model: "custom-test", Reasoning: &tt.cfg, MaxTokens: 300,
				ExtraBody: map[string]any{"reasoning": map[string]any{"exclude": true}, "vendor_option": "preserved"}}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err != nil {
				t.Fatal(err)
			}
			body := (<-requests).body
			if !reflect.DeepEqual(body[tt.key], tt.want) || body["vendor_option"] != "preserved" {
				t.Errorf("request body = %#v, want %s=%#v and vendor option", body, tt.key, tt.want)
			}
			if tt.cfg.Format == "deepseek" {
				wantEffort := any(tt.cfg.Effort)
				if tt.cfg.Effort == "none" {
					wantEffort = nil
				}
				if body["reasoning_effort"] != wantEffort {
					t.Errorf("DeepSeek reasoning_effort = %#v, want %#v", body["reasoning_effort"], wantEffort)
				}
			}
		})
	}
}

func TestReasoningRejectsInvalidConfigBeforeTransport(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name, provider, want string
		cfg                  reasoning.Config
	}{
		{"small Claude budget", "anthropic", "1024", reasoning.Config{Format: "anthropic_budget", Effort: "enabled", BudgetTokens: 1000}},
		{"zero Gemini budget", "gemini", "预算", reasoning.Config{Format: "gemini_budget", Effort: "enabled"}},
		{"native wrong protocol", "gemini", "format", reasoning.Config{Format: "openai", Effort: "high"}},
		{"unknown protocol", "", "format", reasoning.Config{Format: "typo", Effort: "high"}},
		{"unsupported level", "gemini", "effort", reasoning.Config{Format: "gemini_level", Effort: "none"}},
		{"enabled without budget", "anthropic", "budget_tokens", reasoning.Config{Format: "anthropic_effort", Effort: "high", ThinkingType: "enabled"}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var calls atomic.Int32
			httpClient := &http.Client{Transport: nativeRoundTripFunc(func(*http.Request) (*http.Response, error) {
				calls.Add(1)
				return nil, errors.New("unexpected transport")
			})}
			c := &Client{Provider: tt.provider, BaseURL: "https://local.invalid", Model: "test", APIKey: "test-key", Reasoning: &tt.cfg, HTTP: httpClient}
			if _, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hi"}}); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("error = %v, want %q", err, tt.want)
			}
			if got := calls.Load(); got != 0 {
				t.Errorf("transport attempts = %d, want 0", got)
			}
		})
	}
}
