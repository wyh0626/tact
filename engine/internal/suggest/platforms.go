package suggest

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/wyh0626/tact/engine/internal/adapter"
	"github.com/wyh0626/tact/engine/internal/config"
	"github.com/wyh0626/tact/engine/internal/platform"
)

// PlatformStatus reports registration state, not an authenticated connection.
type PlatformStatus struct {
	ID           string            `json:"id"`
	PluginID     string            `json:"plugin_id,omitempty"`
	Name         string            `json:"name"`
	Version      string            `json:"version,omitempty"`
	Enabled      bool              `json:"enabled"`
	Available    bool              `json:"available"`
	State        string            `json:"state"`
	Manifest     string            `json:"manifest,omitempty"`
	Error        string            `json:"error,omitempty"`
	Capabilities map[string]bool   `json:"capabilities"`
	Desktop      *platform.Desktop `json:"desktop,omitempty"`
	Command      []string          `json:"command,omitempty"`
}

type platformEntry struct {
	status      PlatformStatus
	service     *Service
	testService *Service
}

// platformRegistry is immutable after construction. Each service owns its own
// caches, including outstanding history fetches keyed by the platform chat ID.
type platformRegistry struct {
	entries []*platformEntry
}

func (s *Service) configurePlatforms(instances []config.PlatformConfig) {
	s.platforms = &platformRegistry{}
	counts := make(map[string]int, len(instances))
	for _, instance := range instances {
		counts[instance.ID]++
	}
	for _, instance := range instances {
		status := PlatformStatus{ID: instance.ID, Name: instance.ID, Enabled: instance.Enabled,
			Manifest: config.ExpandHome(instance.Manifest), State: "invalid", Capabilities: map[string]bool{}}
		entry := &platformEntry{status: status}
		s.platforms.entries = append(s.platforms.entries, entry)
		if !platform.ValidID(instance.ID) {
			entry.status.Error = "平台实例 id 需要 1 至 128 个英文字母、数字、点、下划线或连字符，并以字母或数字开头"
			continue
		}
		if counts[instance.ID] > 1 {
			entry.status.Error = fmt.Sprintf("平台实例 id %q 重复", instance.ID)
			continue
		}
		manifest, err := platform.Load(status.Manifest)
		if manifest.Name != "" {
			entry.status.Name = manifest.Name
		}
		entry.status.PluginID, entry.status.Version = manifest.ID, manifest.Version
		if manifest.Capabilities != nil {
			entry.status.Capabilities = manifest.Capabilities
		}
		if err != nil {
			entry.status.Error = err.Error()
			if errors.Is(err, platform.ErrUnsupported) {
				entry.status.State = "unsupported"
			}
			continue
		}
		entry.status.Desktop = &manifest.Desktop
		command, err := manifest.Command(status.Manifest, instance.Command)
		if err != nil {
			entry.status.Error = err.Error()
			continue
		}
		entry.status.Command = command
		cfg := s.cfg
		cfg.Adapter = config.AdapterConfig{Command: command, TimeoutMS: manifest.Limits.TimeoutMS,
			ChatsCacheSeconds: manifest.Limits.ChatsCacheSeconds}
		child := New(cfg, &adapter.Script{Command: command,
			Timeout: time.Duration(manifest.Limits.TimeoutMS) * time.Millisecond}, s.model, s.log)
		child.platformID = instance.ID
		child.capabilities = manifest.Capabilities
		entry.testService = child
		if !instance.Enabled {
			entry.status.State = "disabled"
			continue
		}
		entry.service = child
		entry.status.State, entry.status.Available = "ready", true
	}
}

// noChatTool stands in for the adapter of a service whose chats come only
// from its plugins.
type noChatTool struct{}

func (noChatTool) err() error {
	return errors.New("没有启用的聊天工具：先在 Tact 里导入并启用一个")
}

func (n noChatTool) Chats(context.Context) ([]adapter.Chat, error) { return nil, n.err() }
func (n noChatTool) History(context.Context, string, int) ([]adapter.Message, error) {
	return nil, n.err()
}
func (n noChatTool) Drafts(context.Context) ([]adapter.Draft, error) { return nil, n.err() }

// selectTestPlatform allows an explicit user connection test before enabling
// a valid plugin. Disabled instances never participate in inferred routing.
func (s *Service) selectTestPlatform(id string) (*Service, error) {
	if s.platforms == nil || id == "" {
		return s.selectPlatform(id)
	}
	for _, entry := range s.platforms.entries {
		if entry.status.ID == id && entry.testService != nil {
			return entry.testService, nil
		}
	}
	return s.selectPlatform(id)
}

func (s *Service) platformStatuses() []PlatformStatus {
	if s.platforms == nil {
		return []PlatformStatus{}
	}
	statuses := make([]PlatformStatus, 0, len(s.platforms.entries))
	for _, entry := range s.platforms.entries {
		statuses = append(statuses, entry.status)
	}
	return statuses
}

func (s *Service) selectPlatform(id string) (*Service, error) {
	if s.platforms == nil {
		if id != "" && id != s.platformID {
			return nil, fail(CodePlatformUnavailable, "未知平台实例 %q", id)
		}
		return s, nil
	}
	var available []*Service
	for _, entry := range s.platforms.entries {
		if id != "" && entry.status.ID == id {
			if entry.service == nil {
				return nil, fail(CodePlatformUnavailable, "平台实例 %q 不可用（%s）：%s", id, entry.status.State, entry.status.Error)
			}
			return entry.service, nil
		}
		if entry.service != nil {
			available = append(available, entry.service)
		}
	}
	if id != "" {
		return nil, fail(CodePlatformUnavailable, "未知平台实例 %q", id)
	}
	if len(available) == 1 {
		return available[0], nil
	}
	if len(available) == 0 {
		return nil, fail(CodePlatformUnavailable, "没有已启用且可用的平台实例")
	}
	return nil, fail(CodePlatformRequired, "已启用多个平台，请指定 platform_id")
}

func (s *Service) handlePlatform(ctx context.Context, req Request) Response {
	switch req.Op {
	case "chats":
		return s.listChats(ctx)
	case "platform_test":
		resp := s.listChats(ctx)
		if resp.OK {
			count := len(resp.Chats)
			resp.Count, resp.Chats = &count, nil
		}
		return resp
	case "resolve":
		return s.resolveOp(ctx, req)
	case "history":
		return s.history(ctx, req)
	case "suggest":
		return s.suggest(ctx, req)
	case "prepare":
		return s.prepare(ctx, req)
	case "check":
		return s.check(ctx, req)
	case "feedback":
		return s.feedback(req)
	default:
		return errorResponse(fail(CodeBadRequest, "未知操作 %q", req.Op))
	}
}
