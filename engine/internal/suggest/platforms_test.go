package suggest

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wyh0626/tact/engine/internal/adapter"
	"github.com/wyh0626/tact/engine/internal/config"
)

const testPluginManifest = `{
  "protocol_version": 1, "id":"example.chat", "name":"Example Chat", "version":"1.0.0",
  "transport":"command-v1", "entrypoint":["/usr/bin/python3","${plugin_dir}/adapter.py"],
  "capabilities":{"conversations.list":true,"messages.read":true,"composer.read":true},
  "desktop":{"strategy":"ax-ocr-v1","bundle_ids":["com.example.chat"],
    "header":{"top_offset":28,"height":64,"left_padding":0},
    "overlay":{"font_size":13,"offset_x":0,"offset_y":0},"send_shortcut":"return"}
}`

func writeTestManifest(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestPlatformStatusesDoNotRunPlugins(t *testing.T) {
	t.Parallel()
	svc, legacy, _, _ := newTestService(t, `{"suggestion":"好的"}`)
	marker := filepath.Join(t.TempDir(), "executed")
	manifest := writeTestManifest(t, testPluginManifest)
	unsupported := writeTestManifest(t, strings.Replace(testPluginManifest, `"protocol_version": 1`, `"protocol_version": 2`, 1))
	svc.configurePlatforms([]config.PlatformConfig{
		{ID: "example-work", Manifest: manifest, Enabled: true, Command: []string{"/usr/bin/touch", marker}},
		{ID: "off", Manifest: manifest, Enabled: false},
		{ID: "future", Manifest: unsupported, Enabled: true},
		{ID: "broken", Manifest: filepath.Join(t.TempDir(), "missing.json"), Enabled: true},
	})
	resp := svc.Handle(context.Background(), Request{Op: "platforms"})
	if !resp.OK || resp.Platforms == nil || len(*resp.Platforms) != 4 {
		t.Fatalf("platforms = %+v", resp)
	}
	wantStates := []string{"ready", "disabled", "unsupported", "invalid"}
	for i, status := range *resp.Platforms {
		if status.State != wantStates[i] || status.Available != (i == 0) {
			t.Errorf("status %d = %+v, want state %s", i, status, wantStates[i])
		}
	}
	if (*resp.Platforms)[0].PluginID != "example.chat" || !(*resp.Platforms)[0].Capabilities["messages.read"] {
		t.Fatalf("manifest metadata lost: %+v", (*resp.Platforms)[0])
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("metadata discovery invoked plugin: marker error %v", err)
	}
	if legacy.chatsHit != 0 {
		t.Fatalf("metadata discovery used legacy adapter %d times", legacy.chatsHit)
	}
}

func TestPlatformRoutingFailsClosed(t *testing.T) {
	t.Parallel()
	manifest := writeTestManifest(t, testPluginManifest)
	unsupported := writeTestManifest(t, strings.Replace(testPluginManifest, `"command-v1"`, `"unsupported"`, 1))
	cases := []struct {
		name              string
		instances         []config.PlatformConfig
		id                string
		wantCode          string
		allowExplicitTest bool
	}{
		{name: "explicit empty registry", instances: []config.PlatformConfig{}, wantCode: CodePlatformUnavailable},
		{name: "unknown id with one ready", instances: []config.PlatformConfig{{ID: "one", Manifest: manifest, Enabled: true}}, id: "unknown", wantCode: CodePlatformUnavailable},
		{name: "disabled", instances: []config.PlatformConfig{{ID: "off", Manifest: manifest}}, id: "off", wantCode: CodePlatformUnavailable, allowExplicitTest: true},
		{name: "unsupported", instances: []config.PlatformConfig{{ID: "future", Manifest: unsupported, Enabled: true}}, id: "future", wantCode: CodePlatformUnavailable},
		{name: "duplicate ids", instances: []config.PlatformConfig{{ID: "same", Manifest: manifest, Enabled: true}, {ID: "same", Manifest: manifest, Enabled: true}}, id: "same", wantCode: CodePlatformUnavailable},
		{name: "blank id", instances: []config.PlatformConfig{{Manifest: manifest, Enabled: true}}, wantCode: CodePlatformUnavailable},
		{name: "missing routing with multiple ready", instances: []config.PlatformConfig{{ID: "one", Manifest: manifest, Enabled: true}, {ID: "two", Manifest: manifest, Enabled: true}}, wantCode: CodePlatformRequired},
		{name: "empty override is invalid", instances: []config.PlatformConfig{{ID: "one", Manifest: manifest, Enabled: true, Command: []string{}}}, id: "one", wantCode: CodePlatformUnavailable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			svc, legacy, _, _ := newTestService(t, "")
			svc.configurePlatforms(tc.instances)
			for _, op := range []string{"chats", "platform_test", "resolve", "history", "prepare", "suggest", "check", "feedback"} {
				if op == "platform_test" && tc.allowExplicitTest {
					continue
				}
				resp := svc.Handle(context.Background(), Request{Op: op, PlatformID: tc.id, ChatID: "1001", Event: "accepted"})
				if resp.OK || resp.ErrorCode != tc.wantCode || resp.PlatformID != tc.id {
					t.Errorf("%s = %+v, want code %s, id %q", op, resp, tc.wantCode, tc.id)
				}
			}
			if legacy.chatsHit != 0 || legacy.historyCalls() != 0 {
				t.Fatalf("failed platform routing used legacy adapter: chats %d history %d", legacy.chatsHit, legacy.historyCalls())
			}
		})
	}
}

func TestDisabledPlatformCanOnlyBeTestedExplicitly(t *testing.T) {
	t.Parallel()
	svc, _, _, _ := newTestService(t, "")
	manifest := writeTestManifest(t, testPluginManifest)
	svc.configurePlatforms([]config.PlatformConfig{{ID: "off", Manifest: manifest, Enabled: false}})
	fa := &fakeAdapter{chats: []adapter.Chat{{ID: "one", Title: "Chat"}}}
	svc.platforms.entries[0].testService.adapter = fa
	resp := svc.Handle(context.Background(), Request{Op: "platform_test"})
	if resp.OK || fa.chatsHit != 0 {
		t.Fatalf("disabled plugin inferred without id: %+v", resp)
	}
	resp = svc.Handle(context.Background(), Request{Op: "platform_test", PlatformID: "off"})
	if !resp.OK || resp.PlatformID != "off" || resp.Count == nil || *resp.Count != 1 || fa.chatsHit != 1 {
		t.Fatalf("explicit disabled test = %+v", resp)
	}
	for _, op := range []string{"chats", "resolve", "history", "prepare", "suggest", "check", "feedback"} {
		resp = svc.Handle(context.Background(), Request{Op: op, PlatformID: "off", ChatID: "one", Event: "accepted"})
		if resp.OK || resp.ErrorCode != CodePlatformUnavailable {
			t.Errorf("disabled normal %s = %+v", op, resp)
		}
	}
	statuses := svc.platformStatuses()
	if statuses[0].Enabled || statuses[0].Available || statuses[0].State != "disabled" || fa.chatsHit != 1 {
		t.Fatalf("test activated plugin: %+v, chats %d", statuses, fa.chatsHit)
	}
}

func TestPlatformCachesAndFeedbackAreIsolated(t *testing.T) {
	t.Parallel()
	svc, _, model, logPath := newTestService(t, `{"suggestion":"好的"}`)
	manifest := writeTestManifest(t, testPluginManifest)
	svc.configurePlatforms([]config.PlatformConfig{
		{ID: "work", Manifest: manifest, Enabled: true},
		{ID: "personal", Manifest: manifest, Enabled: true},
	})
	adapters := map[string]*fakeAdapter{}
	for _, entry := range svc.platforms.entries {
		id := entry.status.ID
		fa := &fakeAdapter{chats: []adapter.Chat{{ID: "same", Title: id}}, history: map[string][]adapter.Message{
			"same": {{ID: adapter.ID("message-" + id), Sender: id, Text: "内容 " + id}},
		}}
		entry.service.adapter = fa
		adapters[id] = fa
		prepared := svc.Handle(context.Background(), Request{Op: "prepare", PlatformID: id, ChatID: "same"})
		if !prepared.OK || prepared.LastMessageID != "message-"+id {
			t.Fatalf("prepare %s = %+v", id, prepared)
		}
	}
	for _, id := range []string{"work", "personal"} {
		resp := svc.Handle(context.Background(), Request{Op: "suggest", PlatformID: id, ChatID: "same"})
		if !resp.OK || resp.PlatformID != id || resp.LastMessageID != "message-"+id || resp.TimingMS["history_cached"] != 1 {
			t.Fatalf("suggest %s = %+v", id, resp)
		}
		if !strings.Contains(model.last[1].Content, "内容 "+id) {
			t.Fatalf("platform %s prompt = %q", id, model.last[1].Content)
		}
		if adapters[id].historyCalls() != 1 || adapters[id].chatsHit != 1 {
			t.Fatalf("platform %s cache misses: chats %d, history %d", id, adapters[id].chatsHit, adapters[id].historyCalls())
		}
		fb := svc.Handle(context.Background(), Request{Op: "feedback", PlatformID: id, ChatID: "same", Event: "accepted"})
		if !fb.OK || fb.PlatformID != id {
			t.Fatalf("feedback %s = %+v", id, fb)
		}
	}
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	chats := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		var event map[string]any
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatal(err)
		}
		id, ok := event["platform_id"].(string)
		if !ok {
			t.Fatalf("feedback missing platform binding: %s", line)
		}
		chats[id], ok = event["chat"].(string)
		if !ok {
			t.Fatalf("feedback missing chat hash: %s", line)
		}
	}
	if chats["work"] == "" || chats["personal"] == "" || chats["work"] == chats["personal"] {
		t.Fatalf("feedback chat hashes not isolated: %v", chats)
	}
}

func TestSinglePlatformInferenceAndExplicitTest(t *testing.T) {
	t.Parallel()
	svc, _, _, _ := newTestService(t, "")
	manifest := writeTestManifest(t, testPluginManifest)
	svc.configurePlatforms([]config.PlatformConfig{{ID: "example", Manifest: manifest, Enabled: true}})
	fa := &fakeAdapter{chats: []adapter.Chat{{ID: "one", Title: "Chat"}}}
	svc.platforms.entries[0].service.adapter = fa
	resp := svc.Handle(context.Background(), Request{Op: "platform_test"})
	if !resp.OK || resp.PlatformID != "example" || resp.Count == nil || *resp.Count != 1 || fa.chatsHit != 1 || fa.historyCalls() != 0 {
		t.Fatalf("platform_test = %+v, calls chats %d history %d", resp, fa.chatsHit, fa.historyCalls())
	}
}

func TestGlobalOperationsWithoutPlatform(t *testing.T) {
	t.Parallel()
	svc, fa, _, _ := newTestService(t, "OK")
	svc.configurePlatforms([]config.PlatformConfig{})
	for _, op := range []string{"ping", "platforms", "stats", "model_test"} {
		resp := svc.Handle(context.Background(), Request{Op: op})
		if !resp.OK || resp.PlatformID != "" {
			t.Errorf("global %s = %+v", op, resp)
		}
		if op == "platforms" && (resp.Platforms == nil || len(*resp.Platforms) != 0) {
			t.Errorf("empty registry statuses = %+v", resp)
		}
	}
	if fa.chatsHit != 0 || fa.historyCalls() != 0 {
		t.Fatalf("global operation read legacy chats")
	}
}

func TestNewFromConfigPlatformRegistry(t *testing.T) {
	t.Parallel()
	manifest := writeTestManifest(t, testPluginManifest)
	cases := []struct {
		name      string
		instances []config.PlatformConfig
		wantIDs   []string
	}{
		{name: "no platforms"},
		{name: "explicit empty registry", instances: []config.PlatformConfig{}},
		{name: "a plugin", instances: []config.PlatformConfig{{ID: "example", Manifest: manifest, Enabled: true}}, wantIDs: []string{"example"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := config.Default()
			cfg.Platforms = tc.instances
			svc := NewFromConfig(cfg)
			resp := svc.Handle(context.Background(), Request{Op: "platforms"})
			if !resp.OK || resp.Platforms == nil || len(*resp.Platforms) != len(tc.wantIDs) {
				t.Fatalf("NewFromConfig platforms = %+v, want %v", resp, tc.wantIDs)
			}
			for i, id := range tc.wantIDs {
				if (*resp.Platforms)[i].ID != id {
					t.Errorf("platform %d = %q, want %q", i, (*resp.Platforms)[i].ID, id)
				}
			}
			if len(tc.wantIDs) == 0 {
				resp := svc.Handle(context.Background(), Request{Op: "chats"})
				if resp.OK || resp.ErrorCode != CodePlatformUnavailable {
					t.Fatalf("without a plugin no chat is read: %+v", resp)
				}
			}
		})
	}
}
