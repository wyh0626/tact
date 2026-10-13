package server

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/wyh0626/tact/engine/internal/suggest"
)

type slowHandler struct{ cancelled atomic.Bool }

func (h *slowHandler) Handle(ctx context.Context, req suggest.Request) suggest.Response {
	if req.Op == "slow" {
		select {
		case <-ctx.Done():
			h.cancelled.Store(true)
			return suggest.Response{OK: false}
		case <-time.After(5 * time.Second):
		}
	}
	return suggest.Response{OK: true, Version: req.Op}
}

func startServer(t *testing.T, h Handler) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "gr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "e.sock")
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() { _ = Serve(ctx, sock, h, t.Logf) }()
	for i := 0; i < 100; i++ {
		if _, err := os.Stat(sock); err == nil {
			return sock
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("server did not start")
	return ""
}

func call(t *testing.T, sock string, req map[string]any) suggest.Response {
	t.Helper()
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	data, _ := json.Marshal(req)
	if _, err := conn.Write(append(data, '\n')); err != nil {
		t.Fatal(err)
	}
	line, err := bufio.NewReader(conn).ReadBytes('\n')
	if err != nil {
		t.Fatal(err)
	}
	var resp suggest.Response
	if err := json.Unmarshal(line, &resp); err != nil {
		t.Fatal(err)
	}
	return resp
}

func TestRoundTrip(t *testing.T) {
	sock := startServer(t, &slowHandler{})
	if resp := call(t, sock, map[string]any{"op": "ping"}); !resp.OK || resp.Version != "ping" {
		t.Fatalf("unexpected: %+v", resp)
	}
	info, err := os.Stat(sock)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("socket must be 0600, got %v %v", info.Mode().Perm(), err)
	}
}

func TestClientHangupCancels(t *testing.T) {
	h := &slowHandler{}
	sock := startServer(t, h)
	conn, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = conn.Write([]byte(`{"op":"slow"}` + "\n"))
	time.Sleep(100 * time.Millisecond)
	conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for !h.cancelled.Load() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !h.cancelled.Load() {
		t.Fatal("closing the connection must cancel the request")
	}
}

func TestSecondEngineRefused(t *testing.T) {
	sock := startServer(t, &slowHandler{})
	err := Serve(context.Background(), sock, &slowHandler{}, t.Logf)
	if err == nil {
		t.Fatal("a second engine on the same socket must be refused")
	}
}
