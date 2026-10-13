// Package local runs llama-server, the llama.cpp runtime that ships inside
// the app, for the built-in local models. One server serves the engine: it
// starts on first use, listens on loopback only, takes a key made for this
// run, and stops with the engine.
package local

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type Server struct {
	Binary      string
	Model       string
	ContextSize int
	// PIDFile records the running server, so one left behind by an engine
	// that was killed is stopped the next time a server starts.
	PIDFile string
	// StartTimeout bounds loading the model; the first start also compiles
	// the Metal shaders.
	StartTimeout time.Duration
	Log          io.Writer

	mu      sync.Mutex
	current *attempt
}

type attempt struct {
	done    chan struct{}
	exited  chan struct{}
	cmd     *exec.Cmd
	baseURL string
	key     string
	err     error
}

func (a *attempt) usable() bool {
	select {
	case <-a.done:
		if a.err != nil {
			return false
		}
	default:
		return true // still starting
	}
	select {
	case <-a.exited:
		return false
	default:
		return true
	}
}

// Endpoint returns the server's base URL and key once the model has loaded,
// starting the server if it is not running. Concurrent callers share one
// start; a caller that gives up does not stop it for the others.
func (s *Server) Endpoint(ctx context.Context) (string, string, error) {
	s.mu.Lock()
	if s.current == nil || !s.current.usable() {
		s.current = s.start()
	}
	a := s.current
	s.mu.Unlock()
	select {
	case <-a.done:
		return a.baseURL, a.key, a.err
	case <-ctx.Done():
		return "", "", ctx.Err()
	}
}

// Stop ends the server and waits briefly for it to go.
func (s *Server) Stop() {
	s.mu.Lock()
	a := s.current
	s.current = nil
	s.mu.Unlock()
	if a == nil || a.cmd == nil || a.cmd.Process == nil {
		return
	}
	terminate(a.cmd.Process.Pid, a.exited)
	if s.PIDFile != "" {
		_ = os.Remove(s.PIDFile)
	}
}

func (s *Server) start() *attempt {
	a := &attempt{done: make(chan struct{}), exited: make(chan struct{})}
	finish := func(err error) {
		a.err = err
		close(a.done)
	}
	s.stopOrphan()
	if _, err := os.Stat(s.Model); err != nil {
		finish(fmt.Errorf("找不到模型文件 %s，请在设置里重新下载", s.Model))
		close(a.exited)
		return a
	}
	if _, err := os.Stat(s.Binary); err != nil {
		finish(fmt.Errorf("找不到本机模型运行时 %s", s.Binary))
		close(a.exited)
		return a
	}
	port, err := freePort()
	if err != nil {
		finish(fmt.Errorf("找不到可用端口：%w", err))
		close(a.exited)
		return a
	}
	key, err := randomKey()
	if err != nil {
		finish(err)
		close(a.exited)
		return a
	}
	a.baseURL = "http://127.0.0.1:" + strconv.Itoa(port)
	a.key = key
	contextSize := s.ContextSize
	if contextSize <= 0 {
		contextSize = 8192
	}
	a.cmd = exec.Command(s.Binary,
		"--model", s.Model, "--host", "127.0.0.1", "--port", strconv.Itoa(port),
		"--ctx-size", strconv.Itoa(contextSize), "--n-gpu-layers", "999",
		"--parallel", "1", "--jinja", "--no-webui",
		// Reuse what was read even after the history window slides by a
		// message; measured on an M2, 834 tokens to read became 57.
		"--cache-reuse", "256")
	// The key goes through the environment, where other users' processes
	// cannot read it, rather than the command line.
	a.cmd.Env = append(os.Environ(), "LLAMA_API_KEY="+key)
	a.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	tail := &tailBuffer{limit: 2048}
	var output io.Writer = tail
	if s.Log != nil {
		output = io.MultiWriter(s.Log, tail)
	}
	a.cmd.Stdout = output
	a.cmd.Stderr = output
	if err := a.cmd.Start(); err != nil {
		finish(fmt.Errorf("本机模型运行时没能启动：%w", err))
		close(a.exited)
		return a
	}
	if s.PIDFile != "" {
		_ = os.WriteFile(s.PIDFile, []byte(strconv.Itoa(a.cmd.Process.Pid)), 0o600)
	}
	go func() {
		_ = a.cmd.Wait()
		close(a.exited)
	}()
	timeout := s.StartTimeout
	if timeout <= 0 {
		timeout = 2 * time.Minute
	}
	go func() {
		err := waitHealthy(a.baseURL, timeout, a.exited)
		if err != nil {
			terminate(a.cmd.Process.Pid, a.exited)
			if last := strings.TrimSpace(tail.String()); last != "" {
				err = fmt.Errorf("%w：%s", err, lastLine(last))
			}
		}
		finish(err)
	}()
	return a
}

// stopOrphan ends a server recorded in the PID file whose engine is gone.
// Only a process that is still llama-server is touched.
func (s *Server) stopOrphan() {
	if s.PIDFile == "" {
		return
	}
	data, err := os.ReadFile(s.PIDFile)
	if err != nil {
		return
	}
	_ = os.Remove(s.PIDFile)
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 1 {
		return
	}
	out, err := exec.Command("/bin/ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
	if err != nil || !strings.HasSuffix(strings.TrimSpace(string(out)), "llama-server") {
		return
	}
	terminate(pid, nil)
}

func waitHealthy(baseURL string, timeout time.Duration, exited <-chan struct{}) error {
	client := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		select {
		case <-exited:
			return errors.New("本机模型运行时启动后退出了")
		default:
		}
		resp, err := client.Get(baseURL + "/health")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("本机模型 %s 内没有加载好", timeout)
}

// terminate stops the process group pid leads, politely first.
func terminate(pid int, exited <-chan struct{}) {
	_ = syscall.Kill(-pid, syscall.SIGTERM)
	deadline := time.After(3 * time.Second)
	for {
		if exited != nil {
			select {
			case <-exited:
				return
			default:
			}
		} else if syscall.Kill(pid, 0) != nil {
			return
		}
		select {
		case <-deadline:
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			return
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func randomKey() (string, error) {
	b := make([]byte, 24)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func lastLine(s string) string {
	lines := strings.Split(s, "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// tailBuffer keeps the last few kilobytes the server printed, for errors.
type tailBuffer struct {
	mu    sync.Mutex
	limit int
	buf   []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > t.limit {
		t.buf = t.buf[len(t.buf)-t.limit:]
	}
	return len(p), nil
}

func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.buf)
}
