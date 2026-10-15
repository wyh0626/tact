package modelcatalog

import (
	"encoding/json"
	"errors"
	"strings"
)

func parsePage(protocol, provider string, body []byte) ([]Model, string, error) {
	if protocol == "gemini" {
		return parseGemini(body)
	}
	var page struct {
		Data    []json.RawMessage `json:"data"`
		HasMore bool              `json:"has_more"`
		LastID  string            `json:"last_id"`
	}
	if err := json.Unmarshal(body, &page); err != nil || page.Data == nil {
		return nil, "", errors.New("模型列表响应缺少 data 数组")
	}
	if len(page.Data) > maxModels {
		return nil, "", errors.New("模型列表超过 2000 项，请使用手动填写模型")
	}
	result := make([]Model, 0, len(page.Data))
	for _, raw := range page.Data {
		var entry struct {
			ID          string          `json:"id"`
			Name        string          `json:"name"`
			DisplayName string          `json:"display_name"`
			MaxTokens   *int            `json:"max_tokens"`
			Caps        *claudeCaps     `json:"capabilities"`
			Reasoning   json.RawMessage `json:"reasoning"`
			Parameters  *[]string       `json:"supported_parameters"`
		}
		if err := json.Unmarshal(raw, &entry); err != nil || !validID(entry.ID) {
			continue
		}
		name := entry.Name
		if entry.DisplayName != "" {
			name = entry.DisplayName
		}
		if name == "" {
			name = entry.ID
		}
		item := Model{ID: entry.ID, Name: name}
		if protocol == "anthropic" {
			item.Capabilities = parseClaudeCapabilities(entry.Caps, entry.MaxTokens)
		} else {
			item.Capabilities = parseRouterCapabilities(provider, entry.Reasoning, entry.Parameters)
		}
		result = append(result, item)
	}
	if protocol == "anthropic" && page.HasMore {
		if page.LastID == "" || len(page.Data) == 0 {
			return nil, "", errors.New("模型列表分页信息缺少 last_id")
		}
		return result, page.LastID, nil
	}
	return result, "", nil
}

type support struct {
	Supported *bool `json:"supported"`
}

type claudeCaps struct {
	Effort   map[string]json.RawMessage `json:"effort"`
	Thinking *struct {
		Supported *bool              `json:"supported"`
		Types     map[string]support `json:"types"`
	} `json:"thinking"`
}

func parseClaudeCapabilities(raw *claudeCaps, maxTokens *int) *Capabilities {
	if raw == nil && (maxTokens == nil || *maxTokens <= 0) {
		return nil
	}
	caps := &Capabilities{Source: "api"}
	if maxTokens != nil && *maxTokens > 0 {
		caps.MaxOutputTokens = maxTokens
	}
	if raw == nil {
		return caps
	}
	var effortSupported *bool
	if value, ok := raw.Effort["supported"]; ok {
		_ = json.Unmarshal(value, &effortSupported)
	}
	if raw.Effort != nil {
		levels := make([]string, 0)
		reportedLevels := false
		for _, level := range []string{"minimal", "low", "medium", "high", "xhigh", "max"} {
			var value support
			if json.Unmarshal(raw.Effort[level], &value) == nil && value.Supported != nil {
				reportedLevels = true
				if *value.Supported {
					levels = append(levels, level)
				}
			}
		}
		if effortSupported != nil && !*effortSupported {
			// An explicit unsupported declaration is authoritative, even when
			// a partial gateway payload omits every individual effort flag.
			levels = []string{}
			caps.EffortLevels = &levels
		} else if reportedLevels {
			// "supported: true" alone does not describe the allowed levels.
			// Keep them unknown so clients can retain their existing knowledge.
			caps.EffortLevels = &levels
		}
	}
	adaptive, enabled := false, false
	if thinking := raw.Thinking; thinking != nil {
		caps.ReasoningSupported = thinking.Supported
		if thinking.Types != nil {
			types := make([]string, 0)
			for _, kind := range []string{"adaptive", "enabled", "disabled", "between_tools"} {
				value := thinking.Types[kind].Supported
				if value != nil && *value {
					types = append(types, kind)
					adaptive = adaptive || kind == "adaptive"
					enabled = enabled || kind == "enabled"
				}
			}
			caps.ThinkingTypes = &types
			caps.CanDisable = thinking.Types["disabled"].Supported
		}
	}
	if effortSupported != nil && *effortSupported {
		caps.ReasoningSupported = effortSupported
		caps.ReasoningFormat = "anthropic_effort"
	}
	if enabled && !adaptive {
		caps.ReasoningFormat = "anthropic_budget"
	}
	return caps
}

func parseRouterCapabilities(provider string, raw json.RawMessage, parameters *[]string) *Capabilities {
	hasReasoning := len(raw) > 0 && string(raw) != "null"
	if !hasReasoning && (provider != "openrouter" || parameters == nil) {
		return nil
	}
	caps := &Capabilities{Source: "api"}
	if !hasReasoning {
		supported := false
		for _, name := range *parameters {
			if name == "reasoning" || strings.HasPrefix(name, "reasoning.") {
				supported = true
			}
		}
		caps.ReasoningSupported = &supported
		if supported {
			caps.ReasoningFormat = "reasoning"
		}
		return caps
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return nil
	}
	supported := true
	caps.ReasoningSupported = &supported
	caps.ReasoningFormat = "reasoning"
	if value, ok := fields["mandatory"]; ok {
		var mandatory *bool
		if json.Unmarshal(value, &mandatory) == nil && mandatory != nil {
			canDisable := !*mandatory
			caps.CanDisable = &canDisable
		}
	}
	if value, ok := fields["supported_efforts"]; ok {
		var levels []string
		if string(value) == "null" {
			levels = []string{"none", "minimal", "low", "medium", "high", "xhigh", "max"}
		} else if json.Unmarshal(value, &levels) != nil {
			return caps
		}
		filtered := make([]string, 0, len(levels))
		seen := make(map[string]bool)
		for _, level := range levels {
			if knownEffort(level) && !seen[level] && (level != "none" || caps.CanDisable == nil || *caps.CanDisable) {
				filtered = append(filtered, level)
				seen[level] = true
			}
		}
		caps.EffortLevels = &filtered
	}
	return caps
}

func parseGemini(body []byte) ([]Model, string, error) {
	var page struct {
		Models *[]struct {
			Name       string    `json:"name"`
			Display    string    `json:"displayName"`
			Methods    *[]string `json:"supportedGenerationMethods"`
			Thinking   *bool     `json:"thinking"`
			OutputSize *int      `json:"outputTokenLimit"`
		} `json:"models"`
		NextToken string `json:"nextPageToken"`
	}
	if err := json.Unmarshal(body, &page); err != nil || page.Models == nil {
		return nil, "", errors.New("模型列表响应缺少 models 数组")
	}
	if len(*page.Models) > maxModels {
		return nil, "", errors.New("模型列表超过 2000 项，请使用手动填写模型")
	}
	result := make([]Model, 0, len(*page.Models))
	for _, entry := range *page.Models {
		id := strings.TrimPrefix(entry.Name, "models/")
		if !validID(id) {
			continue
		}
		if entry.Methods != nil {
			generation := false
			for _, method := range *entry.Methods {
				generation = generation || method == "generateContent"
			}
			if !generation {
				continue
			}
		}
		name := entry.Display
		if name == "" {
			name = id
		}
		item := Model{ID: id, Name: name}
		if entry.Thinking != nil || (entry.OutputSize != nil && *entry.OutputSize > 0) {
			item.Capabilities = &Capabilities{Source: "api", ReasoningSupported: entry.Thinking}
			if entry.OutputSize != nil && *entry.OutputSize > 0 {
				item.Capabilities.MaxOutputTokens = entry.OutputSize
			}
		}
		result = append(result, item)
	}
	return result, page.NextToken, nil
}

func validID(id string) bool {
	return strings.TrimSpace(id) != "" && len(id) <= 512 && !strings.ContainsAny(id, "\r\n\x00")
}

func knownEffort(value string) bool {
	switch value {
	case "none", "minimal", "low", "medium", "high", "xhigh", "max":
		return true
	default:
		return false
	}
}
