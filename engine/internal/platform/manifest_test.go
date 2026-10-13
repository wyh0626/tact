package platform

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const validManifest = `{
  "protocol_version": 1,
  "id": "example.chat", "name": "Example Chat", "version": "1.0.0",
  "transport": "command-v1", "entrypoint": ["python3", "${plugin_dir}/adapter.py"],
  "capabilities": {"conversations.list": true, "messages.read": true},
  "desktop": {"strategy": "ax-ocr-v1", "bundle_ids": ["com.example.chat"],
    "header":{"top_offset":28,"height":64,"left_padding":0},
    "overlay":{"font_size":13,"offset_x":0,"offset_y":0},"send_shortcut":"return"}
}`

func TestLoad(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name        string
		body        string
		wantError   bool
		unsupported bool
	}{
		{name: "minimal data reader", body: validManifest},
		{name: "version zero", body: strings.Replace(validManifest, `"protocol_version": 1`, `"protocol_version": 0`, 1), wantError: true, unsupported: true},
		{name: "unknown version", body: strings.Replace(validManifest, `"protocol_version": 1`, `"protocol_version": 2`, 1), wantError: true, unsupported: true},
		{name: "missing name", body: strings.Replace(validManifest, `"name": "Example Chat"`, `"name": ""`, 1), wantError: true},
		{name: "missing id", body: strings.Replace(validManifest, `"id": "example.chat"`, `"id": ""`, 1), wantError: true},
		{name: "invalid id", body: strings.Replace(validManifest, `"id": "example.chat"`, `"id": "example/chat"`, 1), wantError: true},
		{name: "missing plugin version", body: strings.Replace(validManifest, `"version": "1.0.0"`, `"version": ""`, 1), wantError: true},
		{name: "unknown transport", body: strings.Replace(validManifest, `"command-v1"`, `"json-rpc"`, 1), wantError: true, unsupported: true},
		{name: "screen desktop", body: strings.Replace(validManifest, `"ax-ocr-v1"`, `"screen-ocr-v1"`, 1)},
		{name: "unknown desktop", body: strings.Replace(validManifest, `"ax-ocr-v1"`, `"browser-v1"`, 1), wantError: true, unsupported: true},
		{name: "missing bundles", body: strings.Replace(validManifest, `["com.example.chat"]`, `[]`, 1), wantError: true},
		{name: "bundles with whitespace", body: strings.Replace(validManifest, `com.example.chat`, `com.example chat`, 1), wantError: true},
		{name: "negative header top", body: strings.Replace(validManifest, `"top_offset":28`, `"top_offset":-1`, 1), wantError: true},
		{name: "zero header height", body: strings.Replace(validManifest, `"height":64`, `"height":0`, 1), wantError: true},
		{name: "oversized header height", body: strings.Replace(validManifest, `"height":64`, `"height":501`, 1), wantError: true},
		{name: "zero font size", body: strings.Replace(validManifest, `"font_size":13`, `"font_size":0`, 1), wantError: true},
		{name: "unknown shortcut", body: strings.Replace(validManifest, `"send_shortcut":"return"`, `"send_shortcut":"space"`, 1), wantError: true},
		{name: "events unsupported", body: strings.Replace(validManifest, `"messages.read": true`, `"messages.read": true,"events.subscribe":true`, 1), wantError: true, unsupported: true},
		{name: "boolean capabilities only", body: strings.Replace(validManifest, `"messages.read": true`, `"messages.read": "true"`, 1), wantError: true},
		{name: "optional capabilities cannot be null", body: strings.Replace(validManifest, `"messages.read": true`, `"messages.read": true,"composer.read":null`, 1), wantError: true},
		{name: "required messages capability", body: strings.Replace(validManifest, `"messages.read": true`, `"messages.read": false`, 1), wantError: true, unsupported: true},
		{name: "required conversations capability", body: strings.Replace(validManifest, `"conversations.list": true`, `"conversations.list": false`, 1), wantError: true, unsupported: true},
		{name: "entrypoint array only", body: strings.Replace(validManifest, `["python3", "${plugin_dir}/adapter.py"]`, `"python3 adapter.py"`, 1), wantError: true},
		{name: "empty entrypoint", body: strings.Replace(validManifest, `["python3", "${plugin_dir}/adapter.py"]`, `[]`, 1), wantError: true},
		{name: "empty command", body: strings.Replace(validManifest, `"python3"`, `" "`, 1), wantError: true},
		{name: "nul command", body: strings.Replace(validManifest, `"python3"`, `"python3\u0000"`, 1), wantError: true},
		{name: "invalid limits", body: strings.TrimSuffix(validManifest, "}") + `,"limits":{"timeout_ms":0}}`, wantError: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "manifest.json")
			if err := os.WriteFile(path, []byte(tc.body), 0o600); err != nil {
				t.Fatal(err)
			}
			manifest, err := Load(path)
			if (err != nil) != tc.wantError {
				t.Fatalf("Load error = %v, wantError %v", err, tc.wantError)
			}
			if errors.Is(err, ErrUnsupported) != tc.unsupported {
				t.Fatalf("Load unsupported = %v, want %v (error %v)", errors.Is(err, ErrUnsupported), tc.unsupported, err)
			}
			if err == nil && (manifest.Limits.TimeoutMS != 15000 || manifest.Limits.ChatsCacheSeconds != 300) {
				t.Fatalf("limits defaults = %+v", manifest.Limits)
			}
		})
	}
}

func TestLoadRejectsRelativePath(t *testing.T) {
	t.Parallel()
	if _, err := Load("manifest.json"); err == nil {
		t.Fatal("relative manifest path must fail")
	}
}

func TestLoadRejectsOversizedManifest(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, []byte(validManifest+strings.Repeat(" ", 256*1024)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path); err == nil || !strings.Contains(err.Error(), "256 KiB") {
		t.Fatalf("oversized manifest error = %v", err)
	}
}

func TestValidID(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		id   string
		want bool
	}{
		{name: "short", id: "a", want: true},
		{name: "common separators", id: "company.chat-1_work", want: true},
		{name: "max length", id: strings.Repeat("a", 128), want: true},
		{name: "over max length", id: strings.Repeat("a", 129)},
		{name: "empty"},
		{name: "leading separator", id: ".chat"},
		{name: "unicode", id: "聊天"},
		{name: "slash", id: "company/chat"},
		{name: "newline", id: "chat\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ValidID(tc.id); got != tc.want {
				t.Fatalf("ValidID(%q) = %v, want %v", tc.id, got, tc.want)
			}
		})
	}
}

func TestManifestCommand(t *testing.T) {
	t.Parallel()
	var manifest Manifest
	if err := json.Unmarshal([]byte(validManifest), &manifest); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "plugin with spaces", "manifest.json")
	cases := []struct {
		name     string
		override []string
		want     []string
		wantErr  bool
	}{
		{name: "default entrypoint", want: []string{"python3", filepath.Join(filepath.Dir(path), "adapter.py")}},
		{name: "literal substitution only", override: []string{"python3", "${plugin_dir}/adapter.py", "$(touch NO); ${other}"},
			want: []string{"python3", filepath.Join(filepath.Dir(path), "adapter.py"), "$(touch NO); ${other}"}},
		{name: "empty override does not fall back", override: []string{}, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := manifest.Command(path, tc.override)
			if (err != nil) != tc.wantErr {
				t.Fatalf("Command error = %v, wantErr %v", err, tc.wantErr)
			}
			if len(got) != len(tc.want) {
				t.Fatalf("Command = %q, want %q", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("Command = %q, want %q", got, tc.want)
				}
			}
		})
	}
}

func TestShippedTelegramManifestLoads(t *testing.T) {
	path, err := filepath.Abs("../../../plugins/telegram/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Desktop.Strategy != "screen-ocr-v1" || manifest.Capabilities["events.subscribe"] {
		t.Fatalf("unexpected manifest: %+v", manifest)
	}
}
