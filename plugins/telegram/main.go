// Command tact-telegram is Tact's Telegram plugin (docs/ADAPTER.md). It
// reads the chat list and recent messages of the user's own account
// through Telegram's API. It never sends, edits or deletes anything and
// never marks messages read.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"time"
)

var version = "0.1.0"

// Exit codes of the plugin protocol.
const (
	exitOK          = 0
	exitFailed      = 1
	exitUsage       = 2
	exitUnsupported = 3
)

// Reads finish within the manifest's 15 s limit; signing in waits for
// someone to find their phone.
const (
	readTimeout  = 12 * time.Second
	loginTimeout = 5 * time.Minute
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	os.Exit(run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

const usage = `用法：tact-telegram <操作>
  login              扫码登录（在终端里运行）
  logout             退出登录并删除这台 Mac 上的会话
  chats              会话列表（JSON）
  history <id> <n>   某个会话最近 n 条消息（JSON）
  health             是否已登录，不联网（JSON）`

func run(ctx context.Context, args []string, stdin *os.File, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return exitUsage
	}
	store, err := DefaultStore()
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitFailed
	}
	fail := func(err error) int {
		fmt.Fprintln(stderr, err)
		return exitFailed
	}
	switch op := args[0]; op {
	case "chats":
		ctx, cancel := context.WithTimeout(ctx, readTimeout)
		defer cancel()
		chats, err := listChats(ctx, store)
		if err != nil {
			return fail(err)
		}
		return output(stdout, stderr, map[string]any{"chats": chats})
	case "history":
		if len(args) != 3 {
			fmt.Fprintln(stderr, usage)
			return exitUsage
		}
		limit, err := strconv.Atoi(args[2])
		if err != nil || limit <= 0 {
			fmt.Fprintln(stderr, "条数应该是正整数")
			return exitUsage
		}
		ctx, cancel := context.WithTimeout(ctx, readTimeout)
		defer cancel()
		messages, err := history(ctx, store, args[1], min(limit, 100))
		if err != nil {
			return fail(err)
		}
		return output(stdout, stderr, map[string]any{"messages": messages})
	case "drafts":
		fmt.Fprintln(stderr, "不读取草稿")
		return exitUnsupported
	case "health":
		return output(stdout, stderr, health(store))
	case "login":
		ctx, cancel := context.WithTimeout(ctx, loginTimeout)
		defer cancel()
		if err := login(ctx, store, newPrompt(stdin, stdout)); err != nil {
			return fail(err)
		}
		return exitOK
	case "logout":
		if err := logout(ctx, store, stdout); err != nil {
			return fail(err)
		}
		return exitOK
	default:
		fmt.Fprintf(stderr, "未知操作 %q\n%s\n", op, usage)
		return exitUsage
	}
}

// health reports what is set up without connecting.
func health(store Store) map[string]any {
	_, appErr := store.App()
	switch {
	case appErr != nil && !errors.Is(appErr, os.ErrNotExist):
		return map[string]any{"available": false, "authentication": "unknown", "message": "API 凭据不能用：" + appErr.Error()}
	case appErr != nil || !store.SignedIn():
		return map[string]any{"available": true, "authentication": "signed_out", "message": "还没登录，运行「扫码登录」"}
	default:
		return map[string]any{"available": true, "authentication": "unknown", "message": "已保存登录信息；是否仍有效要在读取时才知道"}
	}
}

func output(stdout, stderr io.Writer, value any) int {
	if err := json.NewEncoder(stdout).Encode(value); err != nil {
		fmt.Fprintln(stderr, err)
		return exitFailed
	}
	return exitOK
}
