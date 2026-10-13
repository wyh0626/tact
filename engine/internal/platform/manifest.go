// Package platform validates installed plugin manifests without starting them.
package platform

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"

	"github.com/wyh0626/tact/engine/internal/config"
)

// ErrUnsupported indicates a valid declaration the current host cannot run.
var ErrUnsupported = errors.New("unsupported platform plugin")

var validID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// ValidID reports whether an instance or plugin ID follows the host contract.
func ValidID(id string) bool { return validID.MatchString(id) }

// Manifest describes the command transport and host desktop bridge.
type Manifest struct {
	ProtocolVersion int          `json:"protocol_version"`
	ID              string       `json:"id"`
	Name            string       `json:"name"`
	Version         string       `json:"version"`
	Transport       string       `json:"transport"`
	Entrypoint      []string     `json:"entrypoint"`
	Capabilities    Capabilities `json:"capabilities"`
	Desktop         Desktop      `json:"desktop"`
	Limits          Limits       `json:"limits"`
}

// Capabilities accepts boolean declarations only, including optional features.
type Capabilities map[string]bool

// UnmarshalJSON rejects null values rather than treating them as false.
func (c *Capabilities) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw == nil {
		return errors.New("capabilities 必须是布尔值对象")
	}
	result := make(Capabilities, len(raw))
	for name, value := range raw {
		switch strings.TrimSpace(string(value)) {
		case "true":
			result[name] = true
		case "false":
			result[name] = false
		default:
			return fmt.Errorf("capabilities.%s 必须是布尔值", name)
		}
	}
	*c = result
	return nil
}

// Desktop contains settings for the host's built-in AX and OCR bridge.
type Desktop struct {
	Strategy     string   `json:"strategy"`
	BundleIDs    []string `json:"bundle_ids"`
	Header       Header   `json:"header"`
	Overlay      Overlay  `json:"overlay"`
	SendShortcut string   `json:"send_shortcut"`
}

// Header describes the title recognition area relative to the window.
type Header struct {
	TopOffset   float64 `json:"top_offset"`
	Height      float64 `json:"height"`
	LeftPadding float64 `json:"left_padding"`
}

// Overlay positions a suggestion relative to the desktop input field.
type Overlay struct {
	FontSize float64 `json:"font_size"`
	OffsetX  float64 `json:"offset_x"`
	OffsetY  float64 `json:"offset_y"`
}

// Limits bounds command execution and chat-list caching per instance.
type Limits struct {
	TimeoutMS         int `json:"timeout_ms"`
	ChatsCacheSeconds int `json:"chats_cache_seconds"`
}

// Load reads and validates a manifest. It never invokes its entrypoint.
func Load(path string) (Manifest, error) {
	m := Manifest{Limits: Limits{TimeoutMS: 15000, ChatsCacheSeconds: 300}}
	path = config.ExpandHome(path)
	if !filepath.IsAbs(path) {
		return m, errors.New("manifest 路径必须是绝对路径或 ~/ 开头")
	}
	f, err := os.Open(path)
	if err != nil {
		return m, fmt.Errorf("读取 manifest 失败：%w", err)
	}
	defer f.Close()
	const maxBytes = 256 * 1024
	data, err := io.ReadAll(io.LimitReader(f, maxBytes+1))
	if err != nil {
		return m, fmt.Errorf("读取 manifest 失败：%w", err)
	}
	if len(data) > maxBytes {
		return m, errors.New("manifest 超过 256 KiB 限制")
	}
	if err := json.Unmarshal(data, &m); err != nil {
		return m, fmt.Errorf("manifest 不是合法的插件声明：%w", err)
	}
	return m, m.Validate()
}

// Validate rejects incomplete declarations and unsupported host protocols.
func (m Manifest) Validate() error {
	if !ValidID(m.ID) || strings.TrimSpace(m.Name) == "" || strings.TrimSpace(m.Version) == "" {
		return errors.New("manifest 的 id 不合法，或 name、version 为空")
	}
	if m.ProtocolVersion != 1 {
		return fmt.Errorf("%w：protocol_version 必须是 1", ErrUnsupported)
	}
	if m.Transport != "command-v1" {
		return fmt.Errorf("%w：transport %q", ErrUnsupported, m.Transport)
	}
	if err := validateCommand(m.Entrypoint); err != nil {
		return fmt.Errorf("manifest.entrypoint：%w", err)
	}
	if !m.Capabilities["conversations.list"] || !m.Capabilities["messages.read"] {
		return fmt.Errorf("%w：需要 conversations.list 和 messages.read 能力", ErrUnsupported)
	}
	if m.Capabilities["events.subscribe"] {
		return fmt.Errorf("%w：command-v1 尚未实现 events.subscribe", ErrUnsupported)
	}
	// The desktop strategy is the app's business (Platform.swift); the
	// engine only routes requests and needs to know the name.
	if m.Desktop.Strategy != "ax-ocr-v1" && m.Desktop.Strategy != "screen-ocr-v1" {
		return fmt.Errorf("%w：desktop.strategy %q", ErrUnsupported, m.Desktop.Strategy)
	}
	if len(m.Desktop.BundleIDs) == 0 {
		return errors.New("manifest.desktop.bundle_ids 不能为空")
	}
	for _, id := range m.Desktop.BundleIDs {
		if id == "" || strings.IndexFunc(id, unicode.IsSpace) >= 0 {
			return errors.New("manifest.desktop.bundle_ids 不能包含空值或空白字符")
		}
	}
	d := m.Desktop
	if !finite(d.Header.TopOffset) || d.Header.TopOffset < 0 || !finite(d.Header.Height) || d.Header.Height <= 0 || d.Header.Height > 500 ||
		!finite(d.Header.LeftPadding) || !finite(d.Overlay.FontSize) || d.Overlay.FontSize <= 0 ||
		!finite(d.Overlay.OffsetX) || !finite(d.Overlay.OffsetY) {
		return errors.New("manifest.desktop 的标题区域或浮窗几何参数不合法")
	}
	switch d.SendShortcut {
	case "return", "command+return", "control+return":
	default:
		return errors.New("manifest.desktop.send_shortcut 不受支持")
	}
	if m.Limits.TimeoutMS <= 0 || m.Limits.ChatsCacheSeconds < 0 {
		return errors.New("manifest.limits 需要正数 timeout_ms 和非负 chats_cache_seconds")
	}
	return nil
}

// Command expands the sole supported placeholder without evaluating a shell.
func (m Manifest) Command(manifestPath string, override []string) ([]string, error) {
	command := m.Entrypoint
	if override != nil {
		command = override
	}
	if err := validateCommand(command); err != nil {
		return nil, err
	}
	pluginDir := filepath.Dir(config.ExpandHome(manifestPath))
	result := make([]string, len(command))
	for i, arg := range command {
		result[i] = strings.ReplaceAll(arg, "${plugin_dir}", pluginDir)
		if override != nil {
			result[i] = config.ExpandHome(result[i])
		}
	}
	return result, nil
}

func validateCommand(command []string) error {
	if len(command) == 0 {
		return errors.New("command 不能为空")
	}
	for _, arg := range command {
		if strings.TrimSpace(arg) == "" || strings.ContainsRune(arg, '\x00') {
			return errors.New("command 参数不能是空值或包含 NUL")
		}
	}
	return nil
}

func finite(value float64) bool { return !math.IsNaN(value) && !math.IsInf(value, 0) }
