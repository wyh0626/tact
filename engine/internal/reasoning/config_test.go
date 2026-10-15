package reasoning

import "testing"

func TestConfigValidate(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name, provider string
		cfg            *Config
		valid          bool
	}{
		{"legacy nil", "gemini", nil, true},
		{"OpenAI default", "openai", &Config{Format: "openai"}, true},
		{"DeepSeek max", "deepseek", &Config{Format: "deepseek", Effort: "max"}, true},
		{"OpenRouter max", "openai", &Config{Format: "reasoning", Effort: "max"}, true},
		{"custom native format", "", &Config{Format: "anthropic_effort", Effort: "high"}, true},
		{"Claude budget", "anthropic", &Config{Format: "anthropic_budget", Effort: "enabled", BudgetTokens: 1024}, true},
		{"Claude adaptive", "anthropic", &Config{Format: "anthropic_effort", Effort: "max", ThinkingType: "adaptive"}, true},
		{"Claude between tools", "anthropic", &Config{Format: "anthropic_effort", Effort: "none", ThinkingType: "between_tools"}, true},
		{"Gemini dynamic", "gemini", &Config{Format: "gemini_budget", Effort: "enabled", BudgetTokens: -1}, true},
		{"Gemini off", "gemini", &Config{Format: "gemini_budget", Effort: "none"}, true},
		{"Gemini minimal", "gemini", &Config{Format: "gemini_level", Effort: "minimal"}, true},
		{"ChatGPT legacy only", "chatgpt", &Config{Format: "openai", Effort: "high"}, false},
		{"local legacy only", "local", &Config{Format: "openai", Effort: "high"}, false},
		{"native wrong family", "anthropic", &Config{Format: "openai", Effort: "high"}, false},
		{"unknown format", "", &Config{Format: "typo"}, false},
		{"Claude insufficient budget", "anthropic", &Config{Format: "anthropic_budget", Effort: "enabled", BudgetTokens: 1023}, false},
		{"Gemini zero enabled", "gemini", &Config{Format: "gemini_budget", Effort: "enabled"}, false},
		{"budget overflow", "", &Config{Format: "gemini_budget", Effort: "enabled", BudgetTokens: 2147483648}, false},
		{"wrong thinking type family", "", &Config{Format: "openai", Effort: "high", ThinkingType: "adaptive"}, false},
		{"unknown thinking type", "anthropic", &Config{Format: "anthropic_effort", Effort: "high", ThinkingType: "typo"}, false},
		{"Claude enabled without budget", "anthropic", &Config{Format: "anthropic_effort", Effort: "high", ThinkingType: "enabled"}, false},
		{"Claude budget incompatible adaptive", "anthropic", &Config{Format: "anthropic_budget", Effort: "enabled", BudgetTokens: 1024, ThinkingType: "adaptive"}, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if err := tt.cfg.Validate(tt.provider); (err == nil) != tt.valid {
				t.Errorf("Validate(%q) = %v, want valid=%v", tt.provider, err, tt.valid)
			}
		})
	}
}
