package model

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

func completionContext(ctx context.Context, client *http.Client) (context.Context, context.CancelFunc) {
	timeout := 30 * time.Second
	if client != nil {
		timeout = client.Timeout
	}
	if timeout > 0 {
		return context.WithTimeout(ctx, timeout)
	}
	return context.WithCancel(ctx)
}

// completionHTTP preserves the engine's timeout, response-size and single
// attempt policy around the provider SDKs for one request. It never changes
// a shared client.
func completionHTTP(client *http.Client, cancel context.CancelFunc, headers map[string]string) (*http.Client, *completionTransport) {
	if client == nil {
		client = NewHTTPClient(30 * time.Second)
	}
	clone := *client
	// The deadline covers the entire completion, including SDK processing.
	// A single context timer also preserves DeadlineExceeded through SDKs
	// that turn http.Client timeout errors into context cancellation.
	clone.Timeout = 0
	base := clone.Transport
	if base == nil {
		base = http.DefaultTransport
	}
	transport := &completionTransport{base: base, cancel: cancel, headers: headers}
	clone.Transport = transport
	clone.CheckRedirect = NewHTTPClient(0).CheckRedirect
	return &clone, transport
}

type completionTransport struct {
	base    http.RoundTripper
	cancel  context.CancelFunc
	mu      sync.Mutex
	err     error
	status  int
	detail  string
	failure *APIError
	// retryAfter is the Retry-After header of a failure reply, if any.
	retryAfter string
	headers    map[string]string
}

func (t *completionTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(withHeaders(req, t.headers))
	if err != nil {
		t.mu.Lock()
		t.err = err
		t.mu.Unlock()
		// Claude's SDK retries network errors by default. Stop the call on its
		// first transport failure, retaining the original error for the caller.
		t.cancel()
		return resp, err
	}
	// This documented SDK header disables Anthropic's status-code retries.
	resp.Header = resp.Header.Clone()
	resp.Header.Set("X-Should-Retry", "false")
	resp.Body = http.MaxBytesReader(nil, resp.Body, 4<<20)
	body, readErr := io.ReadAll(resp.Body)
	resp.Body.Close()
	if readErr == nil && resp.StatusCode/100 == 2 && !json.Valid(body) {
		readErr = errors.New("模型响应不是合法的单个 JSON 文档")
	}
	if readErr != nil {
		t.mu.Lock()
		t.err = readErr
		t.mu.Unlock()
		t.cancel()
		return nil, readErr
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))
	if resp.StatusCode/100 != 2 {
		t.mu.Lock()
		t.status = resp.StatusCode
		t.detail = truncate(strings.TrimSpace(string(body)), 300)
		t.failure = parseAPIError(resp.StatusCode, body)
		t.retryAfter = resp.Header.Get("Retry-After")
		t.mu.Unlock()
	}
	return resp, nil
}

// apiError is the error reply the service sent, if any.
func (t *completionTransport) apiError() *APIError {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.failure
}

func (t *completionTransport) callError(err error) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	// http.Client decorates a transport cancellation with its timeout cause.
	// Keep that richer error instead of the raw "request canceled" error.
	if t.err != nil && !errors.Is(err, context.DeadlineExceeded) {
		err = t.err
	} else if t.status == http.StatusTooManyRequests {
		wait := "稍后再试"
		if seconds, ok := retryAfterSeconds(t.retryAfter, time.Now()); ok {
			wait = fmt.Sprintf("约 %d 秒后再试", seconds)
		}
		return fmt.Errorf("模型服务限流（HTTP 429）：请求太频繁，%s。服务说明：%s", wait, t.detail)
	} else if t.status != 0 {
		return fmt.Errorf("模型接口返回 HTTP %d：%s", t.status, t.detail)
	}
	return fmt.Errorf("调用模型失败：%w", err)
}

// retryAfterSeconds reads a Retry-After header, given in seconds or as an
// HTTP date, as whole seconds from now, at least 1.
func retryAfterSeconds(value string, now time.Time) (int, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return 0, false
	}
	if seconds, err := strconv.Atoi(value); err == nil && seconds >= 0 {
		return max(seconds, 1), true
	}
	at, err := http.ParseTime(value)
	if err != nil {
		return 0, false
	}
	return max(int(math.Ceil(at.Sub(now).Seconds())), 1), true
}
