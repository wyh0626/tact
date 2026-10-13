// Package server exposes the suggest service on a Unix domain socket. Each
// connection carries one newline-terminated JSON request and gets one
// newline-terminated JSON response. A client that closes its connection
// early cancels the request.
package server

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/wyh0626/tact/engine/internal/suggest"
)

type Handler interface {
	Handle(ctx context.Context, req suggest.Request) suggest.Response
}

const maxRequestBytes = 1 << 20

func Serve(ctx context.Context, socketPath string, h Handler, logf func(string, ...any)) error {
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		return err
	}
	if _, err := os.Stat(socketPath); err == nil {
		if c, err := net.DialTimeout("unix", socketPath, 300*time.Millisecond); err == nil {
			c.Close()
			return fmt.Errorf("已经有引擎在 %s 上运行", socketPath)
		}
		_ = os.Remove(socketPath) // stale socket from a crash
	}
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		ln.Close()
		return err
	}
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	logf("引擎 %s 已在 %s 上监听", suggest.Version, socketPath)
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				_ = os.Remove(socketPath)
				return nil
			}
			if errors.Is(err, net.ErrClosed) {
				return err
			}
			logf("accept 失败：%v", err)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go handleConn(ctx, conn, h, logf)
	}
}

func handleConn(parent context.Context, conn net.Conn, h Handler, logf func(string, ...any)) {
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	reader := bufio.NewReader(io.LimitReader(conn, maxRequestBytes))
	line, err := reader.ReadBytes('\n')
	if err != nil && !(errors.Is(err, io.EOF) && len(line) > 0) {
		return
	}
	_ = conn.SetReadDeadline(time.Time{})

	var req suggest.Request
	if err := json.Unmarshal(line, &req); err != nil {
		writeResponse(conn, suggest.Response{OK: false, Error: "请求不是合法的 JSON", ErrorCode: suggest.CodeBadRequest})
		return
	}

	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	go func() {
		// Any further read returning means the client hung up.
		buf := make([]byte, 1)
		if _, err := conn.Read(buf); err != nil {
			cancel()
		}
	}()

	started := time.Now()
	resp := h.Handle(ctx, req)
	if ctx.Err() != nil && parent.Err() == nil {
		logf("请求 %s（%s）被客户端取消，用时 %s", req.RequestID, req.Op, time.Since(started).Round(time.Millisecond))
		return
	}
	// Prefetches run every few seconds while a chat tool is open; only their
	// failures are worth a log line.
	if req.Op != "ping" && req.Op != "feedback" && (req.Op != "prepare" || !resp.OK) {
		status := "ok"
		if !resp.OK {
			status = resp.ErrorCode
		}
		logf("%s %s → %s，用时 %s", req.Op, short(req.RequestID), status, time.Since(started).Round(time.Millisecond))
	}
	writeResponse(conn, resp)
}

func writeResponse(conn net.Conn, resp suggest.Response) {
	data, err := json.Marshal(resp)
	if err != nil {
		data = []byte(`{"ok":false,"error":"内部错误：响应无法序列化","error_code":"bad_request"}`)
	}
	_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, _ = conn.Write(append(data, '\n'))
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
