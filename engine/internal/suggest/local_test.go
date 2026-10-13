package suggest

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/wyh0626/tact/engine/internal/config"
	"github.com/wyh0626/tact/engine/internal/local/localtest"
	"github.com/wyh0626/tact/engine/internal/model"
)

func TestMain(m *testing.M) {
	localtest.MaybeServe()
	os.Exit(m.Run())
}

// The local provider starts the bundled server, talks to it with this run's
// key, passes extra_body through, and stops it on Close.
func TestLocalProviderRunsTheBundledServer(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv(localtest.Env, "serve")
	model := filepath.Join(t.TempDir(), "qwen.gguf")
	if err := os.WriteFile(model, []byte("gguf"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Default()
	cfg.Adapter.Command = []string{"/usr/bin/true"}
	cfg.Model.Provider = "local"
	cfg.Model.Model = "qwen3-4b"
	cfg.Model.Local = config.LocalModel{Path: model, Server: os.Args[0]}
	cfg.Model.ExtraBody = map[string]any{"chat_template_kwargs": map[string]any{"enable_thinking": false}}
	svc := NewFromConfig(cfg)
	defer svc.Close()

	resp := svc.Handle(context.Background(), Request{Op: "model_test"})
	if !resp.OK || !strings.Contains(resp.Note, "本机好的") {
		t.Fatalf("model_test: %+v", resp)
	}
	if !strings.Contains(resp.Note, `"enable_thinking":false`) {
		t.Fatalf("extra_body did not reach the server: %q", resp.Note)
	}
	_, key, err := svc.local.Endpoint(context.Background())
	if err != nil || key == "" {
		t.Fatalf("key %q, %v", key, err)
	}
	svc.Close()
	svc.local.Stop() // a second Stop is harmless
}

// The same prompt is read once; a changed one is read again.
func TestPrewarmReadsEachPromptOnce(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv(localtest.Env, "serve")
	requests := filepath.Join(t.TempDir(), "requests")
	t.Setenv(localtest.RequestsFile, requests)
	modelFile := filepath.Join(t.TempDir(), "qwen.gguf")
	if err := os.WriteFile(modelFile, []byte("gguf"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Default()
	cfg.Adapter.Command = []string{"/usr/bin/true"}
	cfg.Model.Provider = "local"
	cfg.Model.Model = "qwen3-4b-instruct"
	cfg.Model.Local = config.LocalModel{Path: modelFile, Server: os.Args[0]}
	svc := NewFromConfig(cfg)
	defer svc.Close()
	warm, ok := svc.model.(prewarmer)
	if !ok {
		t.Fatal("the local model must be able to read ahead")
	}
	first := []model.Message{{Role: "user", Content: "最近消息：在吗"}}
	warm.Prewarm(context.Background(), first)
	warm.Prewarm(context.Background(), first)
	warm.Prewarm(context.Background(), []model.Message{{Role: "user", Content: "最近消息：在吗\n明天见"}})
	data, _ := os.ReadFile(requests)
	if got := strings.Count(string(data), "max_tokens=1"); got != 2 {
		t.Fatalf("want 2 warm-ups of one token each, got %q", data)
	}
}
