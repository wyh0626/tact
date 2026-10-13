// Package localtest stands in for llama-server in tests: a test binary that
// calls MaybeServe from TestMain becomes the server when started with
// TACT_FAKE_LLAMA set, answering like the real one on the port it is given.
package localtest

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

// Env switches a test binary into the fake server. Its value is the mode:
// "serve", or "crash" to exit at once with a message on stderr.
const Env = "TACT_FAKE_LLAMA"

// ArgsFile, when set, receives the arguments the fake was started with.
const ArgsFile = "TACT_FAKE_LLAMA_ARGS"

// RequestsFile, when set, gets a line per chat request: its max_tokens.
const RequestsFile = "TACT_FAKE_LLAMA_REQUESTS"

// MaybeServe returns at once in a normal test run.
func MaybeServe() {
	mode := os.Getenv(Env)
	if mode == "" {
		return
	}
	if path := os.Getenv(ArgsFile); path != "" {
		_ = os.WriteFile(path, []byte(strings.Join(os.Args[1:], "\n")), 0o600)
	}
	if mode == "crash" {
		fmt.Fprintln(os.Stderr, "error: failed to load model")
		os.Exit(1)
	}
	fs := flag.NewFlagSet("llama-server", flag.ContinueOnError)
	port := fs.String("port", "", "")
	fs.String("model", "", "")
	fs.String("host", "", "")
	fs.String("ctx-size", "", "")
	fs.String("n-gpu-layers", "", "")
	fs.String("parallel", "", "")
	fs.Bool("jinja", false, "")
	fs.Bool("no-webui", false, "")
	fs.String("cache-reuse", "", "")
	_ = fs.Parse(os.Args[1:])
	key := os.Getenv("LLAMA_API_KEY")
	loadedAt := time.Now().Add(150 * time.Millisecond)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if time.Now().Before(loadedAt) {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	mux.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		if key == "" || r.Header.Get("Authorization") != "Bearer "+key {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":{"message":"Invalid API Key"}}`))
			return
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if path := os.Getenv(RequestsFile); path != "" {
			if f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
				fmt.Fprintf(f, "max_tokens=%v\n", body["max_tokens"])
				f.Close()
			}
		}
		kwargs, _ := json.Marshal(body["chat_template_kwargs"])
		_ = json.NewEncoder(w).Encode(map[string]any{
			"choices": []any{map[string]any{
				"message":       map[string]any{"role": "assistant", "content": "本机好的 " + string(kwargs)},
				"finish_reason": "stop",
			}},
		})
	})
	if err := http.ListenAndServe("127.0.0.1:"+*port, mux); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
