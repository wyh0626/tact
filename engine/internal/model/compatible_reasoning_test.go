package model

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"

	"github.com/wyh0626/tact/engine/internal/reasoning"
)

func TestCompatibleProviderReasoningUsesDeclaredParameterFamily(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name         string
		config       reasoning.Config
		wantThinking map[string]any
		wantEnabled  any
		wantBudget   any
	}{
		{name: "thinking on", config: reasoning.Config{Format: "thinking", Effort: "enabled"}, wantThinking: map[string]any{"type": "enabled", "extension": "retained"}},
		{name: "thinking off", config: reasoning.Config{Format: "thinking", Effort: "none"}, wantThinking: map[string]any{"type": "disabled", "extension": "retained"}},
		{name: "thinking automatic", config: reasoning.Config{Format: "thinking", Effort: "auto"}, wantThinking: map[string]any{"type": "auto", "extension": "retained"}},
		{name: "thinking adaptive", config: reasoning.Config{Format: "thinking", Effort: "adaptive"}, wantThinking: map[string]any{"type": "adaptive", "extension": "retained"}},
		{name: "thinking default", config: reasoning.Config{Format: "thinking"}, wantThinking: map[string]any{"extension": "retained"}},
		{name: "qwen on", config: reasoning.Config{Format: "qwen", Effort: "enabled"}, wantThinking: map[string]any{"type": "disabled", "extension": "retained"}, wantEnabled: true},
		{name: "qwen budget", config: reasoning.Config{Format: "qwen", Effort: "enabled", BudgetTokens: 4096}, wantThinking: map[string]any{"type": "disabled", "extension": "retained"}, wantEnabled: true, wantBudget: float64(4096)},
		{name: "qwen off", config: reasoning.Config{Format: "qwen", Effort: "none"}, wantThinking: map[string]any{"type": "disabled", "extension": "retained"}, wantEnabled: false},
		{name: "qwen default", config: reasoning.Config{Format: "qwen"}, wantThinking: map[string]any{"type": "disabled", "extension": "retained"}},
		{name: "siliconflow on", config: reasoning.Config{Format: "siliconflow", Effort: "enabled", BudgetTokens: 2048}, wantThinking: map[string]any{"type": "disabled", "extension": "retained"}, wantEnabled: true, wantBudget: float64(2048)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`)
			extra := map[string]any{"thinking": map[string]any{"type": "disabled", "extension": "retained"}, "metadata": map[string]string{"tag": "keep"}}
			if tc.config.Format == "qwen" || tc.config.Format == "siliconflow" {
				extra["enable_thinking"], extra["thinking_budget"] = true, 8192
			}
			before, err := json.Marshal(extra)
			if err != nil {
				t.Fatal(err)
			}
			c := &Client{Provider: "openai", BaseURL: srv.URL, Model: "manual-model", MaxTokens: 300, ExtraBody: extra, Reasoning: &tc.config}
			if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil || got != "OK" {
				t.Fatalf("Complete = %q, %v", got, err)
			}
			body := (<-requests).body
			if !reflect.DeepEqual(body["thinking"], tc.wantThinking) || body["enable_thinking"] != tc.wantEnabled || body["thinking_budget"] != tc.wantBudget {
				t.Errorf("thinking fields = %#v / %#v / %#v", body["thinking"], body["enable_thinking"], body["thinking_budget"])
			}
			if _, present := body["reasoning_effort"]; present {
				t.Fatal("provider-specific thinking must not inject DeepSeek/OpenAI effort")
			}
			after, err := json.Marshal(extra)
			if err != nil || string(after) != string(before) {
				t.Fatal("saved parameters mutated")
			}
		})
	}
}

func TestOpenRouterMaxEffortWire(t *testing.T) {
	t.Parallel()
	srv, requests := nativeServer(t, `{"choices":[{"message":{"content":"OK"},"finish_reason":"stop"}]}`)
	c := &Client{Provider: "openai", Preset: "openrouter", BaseURL: srv.URL, Model: "manual-model", MaxTokens: 4096,
		Reasoning: &reasoning.Config{Format: "reasoning", Effort: "max"},
		ExtraBody: map[string]any{"reasoning": map[string]any{"summary": "auto"}}}
	if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil || got != "OK" {
		t.Fatalf("Complete = %q, %v", got, err)
	}
	body := (<-requests).body
	if !reflect.DeepEqual(body["reasoning"], map[string]any{"effort": "max", "summary": "auto"}) {
		t.Fatalf("reasoning = %#v", body["reasoning"])
	}
}

func TestMiniMaxSeparatesReasoningFromReply(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, preset, model string
		extra               map[string]any
		want                any
	}{
		{name: "M3 preset default", preset: "minimax", model: "MiniMax-M3", want: true},
		{name: "M2 preset default", preset: "minimax", model: "MiniMax-M2.7", want: true},
		{name: "explicit split", preset: "minimax", model: "MiniMax-M3", extra: map[string]any{"reasoning_split": true}, want: true},
		{name: "explicit override", preset: "minimax", model: "MiniMax-M3", extra: map[string]any{"reasoning_split": false}, want: false},
		{name: "custom endpoint preserved", preset: "custom", model: "MiniMax-M3"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv, requests := nativeServer(t, `{"choices":[{"message":{"content":"Reply only","reasoning_content":"private thoughts"},"finish_reason":"stop"}]}`)
			c := &Client{Provider: "openai", Preset: tc.preset, BaseURL: srv.URL, Model: tc.model, MaxTokens: 4096, ExtraBody: tc.extra}
			if got, err := c.Complete(context.Background(), []Message{{Role: "user", Content: "hello"}}); err != nil || got != "Reply only" {
				t.Fatalf("Complete = %q, %v", got, err)
			}
			body := (<-requests).body
			if body["reasoning_split"] != tc.want {
				t.Fatalf("reasoning_split = %#v, want %#v", body["reasoning_split"], tc.want)
			}
			if tc.extra != nil && tc.extra["reasoning_split"] != tc.want {
				t.Fatal("saved split override was mutated")
			}
		})
	}
}
