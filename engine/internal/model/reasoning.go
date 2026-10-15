package model

import (
	"strings"

	"github.com/wyh0626/tact/engine/internal/reasoning"
)

// reasoningFields only changes a cloned request body. In particular, preserving
// a nested output schema or includeThoughts must never modify saved ExtraBody.
func reasoningFields(extra map[string]any, cfg *reasoning.Config) {
	if cfg == nil {
		return
	}
	effort := cfg.Effort
	switch cfg.Format {
	case "openai":
		delete(extra, "reasoning_effort")
		if effort != "" {
			extra["reasoning_effort"] = effort
		}
	case "deepseek":
		delete(extra, "reasoning_effort")
		thinking := nestedFields(extra, "thinking")
		delete(thinking, "type")
		if effort == "none" {
			thinking["type"] = "disabled"
		} else if effort != "" {
			thinking["type"] = "enabled"
			extra["reasoning_effort"] = effort
		}
		putNestedFields(extra, "thinking", thinking)
	case "reasoning":
		fields := nestedFields(extra, "reasoning")
		delete(fields, "effort")
		if effort != "" {
			fields["effort"] = effort
		}
		putNestedFields(extra, "reasoning", fields)
	case "thinking":
		thinking := nestedFields(extra, "thinking")
		delete(thinking, "type")
		switch effort {
		case "none":
			thinking["type"] = "disabled"
		case "enabled", "auto", "adaptive":
			thinking["type"] = effort
		}
		putNestedFields(extra, "thinking", thinking)
	case "qwen", "siliconflow":
		delete(extra, "enable_thinking")
		delete(extra, "thinking_budget")
		if effort != "" {
			extra["enable_thinking"] = effort != "none"
			if effort == "enabled" && cfg.BudgetTokens > 0 {
				extra["thinking_budget"] = cfg.BudgetTokens
			}
		}
	case "anthropic_effort", "anthropic_budget":
		// Claude can use an output effort together with a token budget (for
		// example Opus 4.5). Budget controls must retain that independent field.
		if cfg.Format == "anthropic_effort" {
			fields := nestedFields(extra, "output_config")
			delete(fields, "effort")
			if effort != "" && effort != "none" {
				fields["effort"] = effort
			}
			putNestedFields(extra, "output_config", fields)
		}
		if effort == "" {
			// A display-only thinking object is invalid: the union requires type.
			// Explicit default therefore omits this request envelope entirely.
			delete(extra, "thinking")
			break
		}
		thinking := nestedFields(extra, "thinking")
		delete(thinking, "type")
		delete(thinking, "budget_tokens")
		if effort == "none" {
			delete(thinking, "display")
			thinking["type"] = "disabled"
			if cfg.ThinkingType == "between_tools" {
				thinking["type"] = "between_tools"
			}
		} else if effort != "" {
			kind := cfg.ThinkingType
			if kind == "" {
				kind = "adaptive"
				if cfg.Format == "anthropic_budget" {
					kind = "enabled"
				}
			}
			thinking["type"] = kind
			if kind == "disabled" {
				delete(thinking, "display")
			}
			if cfg.Format == "anthropic_budget" && kind == "enabled" {
				thinking["budget_tokens"] = cfg.BudgetTokens
			}
		}
		putNestedFields(extra, "thinking", thinking)
	case "gemini_level", "gemini_budget":
		generation := nestedFields(extra, "generationConfig")
		thinking := nestedFields(generation, "thinkingConfig")
		delete(thinking, "thinkingLevel")
		delete(thinking, "thinkingBudget")
		if cfg.Format == "gemini_level" && effort != "" {
			thinking["thinkingLevel"] = strings.ToUpper(effort)
		} else if cfg.Format == "gemini_budget" && effort != "" {
			budget := cfg.BudgetTokens
			if effort == "none" {
				budget = 0
			}
			thinking["thinkingBudget"] = budget
		}
		putNestedFields(generation, "thinkingConfig", thinking)
		putNestedFields(extra, "generationConfig", generation)
	}
}

func nestedFields(parent map[string]any, key string) map[string]any {
	fields, _ := parent[key].(map[string]any)
	return copyFields(fields)
}

func putNestedFields(parent map[string]any, key string, fields map[string]any) {
	if len(fields) == 0 {
		delete(parent, key)
	} else {
		parent[key] = fields
	}
}

func thinkingActive(extra map[string]any) bool {
	thinking, _ := extra["thinking"].(map[string]any)
	return thinking["type"] == "enabled" || thinking["type"] == "adaptive" || thinking["type"] == "between_tools"
}

// reasoningLimit satisfies Claude's required max_tokens > budget_tokens when a
// structured UI choice enables budget thinking. Larger configured caps and all
// legacy manually configured requests retain their original output limits.
func reasoningLimit(configured int, cfg *reasoning.Config) int {
	if configured <= 0 || cfg == nil || cfg.Effort == "" || cfg.Effort == "none" || cfg.ThinkingType == "disabled" {
		return configured
	}
	if cfg.Format == "anthropic_budget" && cfg.BudgetTokens > 0 && configured <= cfg.BudgetTokens {
		return cfg.BudgetTokens + max(configured, 300)
	}
	return configured
}
