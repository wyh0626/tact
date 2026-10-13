package suggest

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/wyh0626/tact/engine/internal/config"
	"github.com/wyh0626/tact/engine/internal/local"
	"github.com/wyh0626/tact/engine/internal/model"
)

// localModel serves the "local" provider: it asks the bundled llama-server
// for its address, starting it when needed, then talks to it like any
// OpenAI-compatible endpoint.
type localModel struct {
	server *local.Server
	client model.Client

	mu     sync.Mutex
	warmed string
}

func (m *localModel) Complete(ctx context.Context, msgs []model.Message) (string, error) {
	baseURL, key, err := m.server.Endpoint(ctx)
	if err != nil {
		return "", fmt.Errorf("本机模型没能启动：%w", err)
	}
	c := m.client
	c.BaseURL = baseURL + "/v1"
	c.APIKey = key
	return c.Complete(ctx, msgs)
}

// Prewarm has the server read a prompt ahead of the request that will
// need it: the next request for the same chat reuses what was read and
// only reads what changed. The same prompt twice is read once.
func (m *localModel) Prewarm(ctx context.Context, msgs []model.Message) {
	key := promptKey(msgs)
	m.mu.Lock()
	if key == m.warmed {
		m.mu.Unlock()
		return
	}
	m.warmed = key
	m.mu.Unlock()
	c := m.client
	c.MaxTokens = 1
	baseURL, apiKey, err := m.server.Endpoint(ctx)
	if err == nil {
		c.BaseURL, c.APIKey = baseURL+"/v1", apiKey
		_, err = c.Complete(ctx, msgs)
	}
	if err != nil && ctx.Err() == nil {
		m.mu.Lock()
		m.warmed = ""
		m.mu.Unlock()
		fmt.Fprintf(os.Stderr, "本机模型预读失败：%v\n", err)
	}
}

func promptKey(msgs []model.Message) string {
	h := sha256.New()
	for _, m := range msgs {
		h.Write([]byte(m.Role))
		h.Write([]byte{0})
		h.Write([]byte(m.Content))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

func newLocalServer(cfg config.ModelConfig) *local.Server {
	binary := cfg.Local.Server
	if binary == "" {
		// Beside the engine: Contents/MacOS in the app, engine/bin in a checkout.
		if exe, err := os.Executable(); err == nil {
			binary = filepath.Join(filepath.Dir(exe), "llama-server")
		}
	}
	return &local.Server{
		Binary:      binary,
		Model:       cfg.Local.Path,
		ContextSize: cfg.Local.ContextSize,
		PIDFile:     filepath.Join(config.Dir(), "llama-server.pid"),
		Log:         os.Stderr,
	}
}
