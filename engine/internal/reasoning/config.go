// Package reasoning defines the optional, provider-specific reasoning controls
// shared by saved configuration and the model adapter.
package reasoning

import (
	"errors"
	"fmt"
)

// Config selects exactly one parameter family. A nil Config retains all legacy
// reasoning settings; an empty Effort explicitly selects the provider default.
type Config struct {
	Format       string `json:"format"`
	Effort       string `json:"effort"`
	BudgetTokens int    `json:"budget_tokens,omitempty"`
	ThinkingType string `json:"thinking_type,omitempty"`
}

// Validate checks protocol compatibility and numeric constraints before a
// request can be sent. Individual model support is chosen in the desktop UI.
func (c *Config) Validate(provider string) error {
	if c == nil {
		return nil
	}
	if provider == "chatgpt" || provider == "local" {
		return errors.New("model.reasoning 只适用于 API 接口；ChatGPT 账号和本机模型请使用原有推理设置")
	}
	if provider == "anthropic" && c.Format != "anthropic_effort" && c.Format != "anthropic_budget" {
		return errors.New("Claude 原生接口的 model.reasoning.format 必须是 anthropic_effort 或 anthropic_budget")
	}
	if provider == "gemini" && c.Format != "gemini_level" && c.Format != "gemini_budget" {
		return errors.New("Gemini 原生接口的 model.reasoning.format 必须是 gemini_level 或 gemini_budget")
	}
	if provider == "responses" && c.Format != "openai" && c.Format != "reasoning" {
		return errors.New("Responses 协议的 model.reasoning.format 必须是 openai 或 reasoning")
	}
	var efforts []string
	switch c.Format {
	case "openai":
		efforts = []string{"", "none", "minimal", "low", "medium", "high", "xhigh", "max"}
	case "reasoning":
		efforts = []string{"", "none", "minimal", "low", "medium", "high", "xhigh", "max"}
	case "deepseek":
		efforts = []string{"", "none", "low", "high", "max"}
	case "thinking":
		efforts = []string{"", "none", "enabled", "auto", "adaptive"}
	case "qwen", "siliconflow":
		efforts = []string{"", "none", "enabled"}
		if c.BudgetTokens < 0 {
			return errors.New("思考预算必须为大于 0 的 tokens，0 表示服务商默认")
		}
	case "anthropic_effort":
		efforts = []string{"", "none", "low", "medium", "high", "xhigh", "max"}
	case "anthropic_budget":
		efforts = []string{"", "none", "enabled"}
		if c.Effort == "enabled" && c.BudgetTokens < 1024 {
			return errors.New("Claude 思考预算至少需要 1024 tokens")
		}
	case "gemini_level":
		efforts = []string{"", "minimal", "low", "medium", "high"}
	case "gemini_budget":
		efforts = []string{"", "none", "enabled"}
		if c.Effort == "enabled" && (c.BudgetTokens == 0 || c.BudgetTokens < -1 || c.BudgetTokens > 2147483647) {
			return errors.New("Gemini 思考预算必须为 -1（动态）或大于 0 的 tokens")
		}
	default:
		return fmt.Errorf("不支持的 model.reasoning.format %q", c.Format)
	}
	valid := false
	for _, effort := range efforts {
		valid = valid || c.Effort == effort
	}
	if !valid {
		return fmt.Errorf("model.reasoning.effort %q 不适用于 %s", c.Effort, c.Format)
	}
	if c.BudgetTokens < -1 || c.BudgetTokens > 2147483647 {
		return errors.New("model.reasoning.budget_tokens 超出支持范围")
	}
	if c.ThinkingType != "" {
		if c.Format != "anthropic_effort" && c.Format != "anthropic_budget" {
			return errors.New("model.reasoning.thinking_type 只适用于 Claude")
		}
		switch c.ThinkingType {
		case "adaptive", "enabled", "disabled", "between_tools":
		default:
			return fmt.Errorf("不支持的 model.reasoning.thinking_type %q", c.ThinkingType)
		}
		if c.Effort != "" && c.Effort != "none" {
			if c.Format == "anthropic_effort" && c.ThinkingType == "enabled" {
				return errors.New("Claude enabled 思考需要 anthropic_budget 和 budget_tokens")
			}
			if c.Format == "anthropic_budget" && c.ThinkingType != "enabled" {
				return errors.New("Claude 预算思考的 thinking_type 必须是 enabled")
			}
		}
	}
	return nil
}
