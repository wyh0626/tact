package local

import (
	"context"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/wyh0626/tact/engine/internal/local/localtest"
)

func TestMain(m *testing.M) {
	localtest.MaybeServe()
	os.Exit(m.Run())
}

func newServer(t *testing.T, mode string) (*Server, string) {
	t.Helper()
	dir := t.TempDir()
	model := filepath.Join(dir, "model.gguf")
	if err := os.WriteFile(model, []byte("gguf"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv(localtest.Env, mode)
	args := filepath.Join(dir, "args")
	t.Setenv(localtest.ArgsFile, args)
	s := &Server{Binary: os.Args[0], Model: model, PIDFile: filepath.Join(dir, "llama-server.pid"),
		StartTimeout: 10 * time.Second}
	t.Cleanup(s.Stop)
	return s, args
}

func alive(pid int) bool { return syscall.Kill(pid, 0) == nil }

func TestConcurrentCallersShareOneServerThatNeedsItsKey(t *testing.T) {
	s, argsFile := newServer(t, "serve")
	var wg sync.WaitGroup
	urls := make([]string, 4)
	keys := make([]string, 4)
	for i := range urls {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			url, key, err := s.Endpoint(context.Background())
			if err != nil {
				t.Error(err)
			}
			urls[i], keys[i] = url, key
		}(i)
	}
	wg.Wait()
	for i := range urls {
		if urls[i] != urls[0] || keys[i] != keys[0] {
			t.Fatalf("callers got different servers: %v %v", urls, keys)
		}
	}
	if !strings.HasPrefix(urls[0], "http://127.0.0.1:") || len(keys[0]) < 32 {
		t.Fatalf("url %q key %q", urls[0], keys[0])
	}
	args, _ := os.ReadFile(argsFile)
	if !strings.Contains(string(args), "--host\n127.0.0.1") || !strings.Contains(string(args), s.Model) {
		t.Fatalf("args = %q", args)
	}
	if !strings.Contains(string(args), "--cache-reuse\n256") {
		t.Fatalf("the server must reuse what it read across a sliding history: %q", args)
	}
	if strings.Contains(string(args), keys[0]) {
		t.Fatal("the key must not appear on the command line")
	}
	resp, err := http.Post(urls[0]+"/v1/chat/completions", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("a request without the key got %d", resp.StatusCode)
	}
}

func TestStopEndsTheServer(t *testing.T) {
	s, _ := newServer(t, "serve")
	if _, _, err := s.Endpoint(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(s.PIDFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(string(data))
	s.Stop()
	if alive(pid) {
		t.Fatal("server still running after Stop")
	}
	if _, err := os.Stat(s.PIDFile); !os.IsNotExist(err) {
		t.Fatal("pid file left behind")
	}
}

func TestAServerThatExitedStartsAgain(t *testing.T) {
	s, _ := newServer(t, "serve")
	first, _, err := s.Endpoint(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	pid := s.current.cmd.Process.Pid
	exited := s.current.exited
	s.mu.Unlock()
	_ = syscall.Kill(pid, syscall.SIGKILL)
	<-exited
	second, _, err := s.Endpoint(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if second == first {
		t.Fatal("expected a new server after the first one exited")
	}
}

func TestStartupFailureSaysWhyAndIsRetried(t *testing.T) {
	s, _ := newServer(t, "crash")
	_, _, err := s.Endpoint(context.Background())
	if err == nil || !strings.Contains(err.Error(), "failed to load model") {
		t.Fatalf("err = %v", err)
	}
	t.Setenv(localtest.Env, "serve")
	if _, _, err := s.Endpoint(context.Background()); err != nil {
		t.Fatalf("a later call starts again: %v", err)
	}
}

func TestMissingModelOrRuntimeIsReported(t *testing.T) {
	s, _ := newServer(t, "serve")
	s.Model = filepath.Join(t.TempDir(), "gone.gguf")
	if _, _, err := s.Endpoint(context.Background()); err == nil || !strings.Contains(err.Error(), "模型文件") {
		t.Fatalf("err = %v", err)
	}
	s2, _ := newServer(t, "serve")
	s2.Binary = filepath.Join(t.TempDir(), "llama-server")
	if _, _, err := s2.Endpoint(context.Background()); err == nil || !strings.Contains(err.Error(), "运行时") {
		t.Fatalf("err = %v", err)
	}
}

func TestCallerGivingUpDoesNotStopTheStart(t *testing.T) {
	s, _ := newServer(t, "serve")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := s.Endpoint(ctx); err != context.Canceled {
		t.Fatalf("err = %v", err)
	}
	if _, _, err := s.Endpoint(context.Background()); err != nil {
		t.Fatal(err)
	}
}

// A server left by an engine that was killed is stopped; a recorded pid that
// is not llama-server is never touched.
func TestOrphanIsStoppedButOtherProcessesAreNot(t *testing.T) {
	dir := t.TempDir()
	runtime := filepath.Join(dir, "llama-server")
	copyFile(t, os.Args[0], runtime)
	s, _ := newServer(t, "serve")
	s.Binary = runtime

	orphan := exec.Command(runtime, "--port", "0")
	orphan.Env = append(os.Environ(), localtest.Env+"=serve")
	orphan.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := orphan.Start(); err != nil {
		t.Fatal(err)
	}
	go func() { _ = orphan.Wait() }()
	if err := os.WriteFile(s.PIDFile, []byte(strconv.Itoa(orphan.Process.Pid)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Endpoint(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for alive(orphan.Process.Pid) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if alive(orphan.Process.Pid) {
		t.Fatal("the orphaned server is still running")
	}

	bystander := exec.Command("/bin/sleep", "30")
	if err := bystander.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bystander.Process.Kill(); _ = bystander.Wait() }()
	s.Stop()
	if err := os.WriteFile(s.PIDFile, []byte(strconv.Itoa(bystander.Process.Pid)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Endpoint(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !alive(bystander.Process.Pid) {
		t.Fatal("a process that is not llama-server was stopped")
	}
}

func copyFile(t *testing.T, from, to string) {
	t.Helper()
	in, err := os.Open(from)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_WRONLY, 0o755)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.Copy(out, in); err != nil {
		t.Fatal(err)
	}
	if err := out.Close(); err != nil {
		t.Fatal(err)
	}
}
