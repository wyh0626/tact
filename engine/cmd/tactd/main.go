// Command tactd is the Tact engine. "serve" runs the socket
// service used by the macOS app; the other subcommands call the same code
// directly so the adapter and model can be tested from a terminal.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/wyh0626/tact/engine/internal/config"
	"github.com/wyh0626/tact/engine/internal/server"
	"github.com/wyh0626/tact/engine/internal/suggest"
)

const usage = `tactd — Tact 引擎

用法：
  tactd serve [--exit-with-stdin]     启动引擎，供 macOS 应用调用
                                            （--exit-with-stdin：标准输入关闭时退出）
  tactd check                         检查配置、适配脚本和模型是否都能用
  tactd chats                         列出适配脚本返回的会话
  tactd platforms                     列出已配置的平台（不执行插件）
  tactd platform-test --platform-id ID  显式测试平台读取会话能力
  tactd resolve --title "会话名"       测试顶部栏文字能否匹配到会话
  tactd history --title "会话名"       查看某个会话最近的消息
  tactd suggest --title "会话名" [--input "婉拒"]
                                            按会话名生成一条建议（--input 是意图）
  tactd stats                         查看反馈统计
  tactd version

通用参数：
  --config <路径>   配置文件，默认 ~/.tact/config.json（或 $TACT_CONFIG）
  --chat-id <ID>    直接指定会话 ID，代替 --title
  --platform-id <ID>  平台实例 ID；多个平台启用时必须指定
  --json            输出原始 JSON
`

func main() {
	if len(os.Args) < 2 || os.Args[1] == "-h" || os.Args[1] == "--help" || os.Args[1] == "help" {
		fmt.Print(usage)
		return
	}
	sub := os.Args[1]
	if sub == "version" {
		fmt.Println(suggest.Version)
		return
	}

	fs := flag.NewFlagSet(sub, flag.ExitOnError)
	cfgPath := fs.String("config", config.DefaultPath(), "配置文件路径")
	title := fs.String("title", "", "会话名（模拟顶部栏识别出的文字）")
	chatID := fs.String("chat-id", "", "会话 ID")
	platformID := fs.String("platform-id", "", "平台实例 ID")
	input := fs.String("input", "", "输入框里的内容，也就是意图")
	limit := fs.Int("limit", 0, "消息条数")
	asJSON := fs.Bool("json", false, "输出原始 JSON")
	exitWithStdin := fs.Bool("exit-with-stdin", false, "serve：标准输入关闭时退出")
	_ = fs.Parse(os.Args[2:])

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "配置有问题：", err)
		os.Exit(1)
	}
	svc := suggest.NewFromConfig(cfg)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := run(ctx, sub, cfg, svc, *platformID, *title, *chatID, *input, *limit, *asJSON, *exitWithStdin)
	stop()
	// Stops the local model's server too; os.Exit would skip deferred calls.
	svc.Close()
	os.Exit(code)
}

func run(ctx context.Context, sub string, cfg config.Config, svc *suggest.Service, platformID, title, chatID, input string,
	limit int, asJSON, exitWithStdin bool) int {
	switch sub {
	case "serve":
		logger := log.New(os.Stderr, "", log.LstdFlags)
		if exitWithStdin {
			var cancel context.CancelFunc
			ctx, cancel = context.WithCancel(ctx)
			defer cancel()
			go cancelOnEOF(os.Stdin, cancel)
		}
		go svc.Warm(ctx)
		if err := server.Serve(ctx, cfg.Socket, svc, logger.Printf); err != nil {
			logger.Print(err)
			return 1
		}
		return 0
	case "check":
		return runCheck(ctx, cfg, svc, platformID)
	case "chats", "resolve", "history", "suggest", "stats", "platforms", "platform-test":
		op := sub
		if op == "platform-test" {
			op = "platform_test"
		}
		req := suggest.Request{Op: op, PlatformID: platformID, Title: title, ChatID: chatID, Input: input, Limit: limit, RequestID: fmt.Sprintf("cli-%d", time.Now().UnixNano())}
		resp := svc.Handle(ctx, req)
		if asJSON {
			enc := json.NewEncoder(os.Stdout)
			enc.SetEscapeHTML(false)
			enc.SetIndent("", "  ")
			_ = enc.Encode(resp)
		} else {
			printHuman(sub, resp)
		}
		if !resp.OK {
			return 1
		}
		return 0
	default:
		fmt.Fprintf(os.Stderr, "未知子命令 %q\n\n%s", sub, usage)
		return 2
	}
}

// cancelOnEOF lets the app hold the write end of our stdin: however the app
// ends (quit, Ctrl+C, crash), the pipe closes and the engine shuts down
// instead of lingering as an orphan.
func cancelOnEOF(r io.Reader, cancel context.CancelFunc) {
	_, _ = io.Copy(io.Discard, r)
	cancel()
}

func printHuman(sub string, r suggest.Response) {
	if !r.OK {
		fmt.Printf("❌ %s（%s）\n", r.Error, r.ErrorCode)
		for _, c := range r.Candidates {
			fmt.Printf("   候选：%s\n", c)
		}
		return
	}
	switch sub {
	case "platforms":
		if r.Platforms != nil {
			for _, p := range *r.Platforms {
				fmt.Printf("  %-16s %-12s %s\n", p.ID, p.State, p.Name)
				if p.Error != "" {
					fmt.Printf("    %s\n", p.Error)
				}
			}
		}
	case "platform-test":
		if r.Count != nil {
			fmt.Printf("✅ 平台 %s 返回 %d 个会话\n", r.PlatformID, *r.Count)
		}
	case "chats":
		fmt.Printf("共 %d 个会话：\n", len(r.Chats))
		for _, c := range r.Chats {
			fmt.Printf("  %-12s %-8s %s\n", c.ID, c.Type, c.Title)
		}
	case "resolve":
		fmt.Printf("✅ 匹配到「%s」（ID %s，方式 %s）\n", r.Chat.Title, r.Chat.ID, r.Method)
	case "history":
		fmt.Printf("「%s」最近 %d 条：\n", r.Chat.Title, len(r.Messages))
		for _, m := range r.Messages {
			who := m.Sender
			if m.FromMe {
				who = "我"
			}
			ts := ""
			if !m.Time.IsZero() {
				ts = m.Time.Local().Format("01-02 15:04") + " "
			}
			fmt.Printf("  %s%s：%s\n", ts, who, strings.ReplaceAll(m.Text, "\n", " ⏎ "))
		}
	case "suggest":
		fmt.Printf("会话：%s（%s，匹配方式 %s）\n", r.Chat.Title, r.Chat.Type, r.Method)
		fmt.Printf("模式：%s\n", map[string]string{"complete": "整句建议", "rewrite": "按意图改写"}[r.Mode])
		if r.Suggestion == nil {
			note := r.Note
			if note == "" {
				note = "模型认为这次不需要建议"
			}
			fmt.Printf("建议：（无）%s\n", note)
		} else {
			fmt.Printf("建议：%s\n", *r.Suggestion)
			var flags []string
			if r.Commits {
				flags = append(flags, "含承诺")
			}
			if r.NeedsCheck {
				flags = append(flags, "用到了聊天里没有的信息")
			}
			if r.Sensitive {
				flags = append(flags, "含链接、邮箱或长数字")
			}
			if len(flags) > 0 {
				fmt.Printf("标记：%s\n", strings.Join(flags, "，"))
			}
		}
		fmt.Printf("耗时：识别 %d ms · 拉消息 %d ms · 模型 %d ms · 合计 %d ms\n",
			r.TimingMS["resolve"], r.TimingMS["history"], r.TimingMS["model"], r.TimingMS["total"])
	case "stats":
		fmt.Println(r.Stats)
	}
}

func runCheck(ctx context.Context, cfg config.Config, svc *suggest.Service, platformID string) int {
	failed := false
	fmt.Printf("配置：socket %s\n", cfg.Socket)
	printHuman("platforms", svc.Handle(ctx, suggest.Request{Op: "platforms"}))

	chats := svc.Handle(ctx, suggest.Request{Op: "chats", PlatformID: platformID})
	if !chats.OK {
		fmt.Printf("  ❌ chats 失败：%s\n", chats.Error)
		failed = true
	} else {
		fmt.Printf("  ✅ chats 返回 %d 个会话\n", len(chats.Chats))
		if len(chats.Chats) > 0 {
			h := svc.Handle(ctx, suggest.Request{Op: "history", PlatformID: chats.PlatformID, ChatID: chats.Chats[0].ID, Limit: 5})
			if h.OK {
				fmt.Printf("  ✅ history 返回「%s」的 %d 条消息\n", chats.Chats[0].Title, len(h.Messages))
			} else {
				fmt.Printf("  ❌ history 失败：%s\n", h.Error)
				failed = true
			}
		}
	}

	provider := cfg.Model.Provider
	if provider == "" {
		provider = "openai"
	}
	fmt.Printf("模型：%s · %s · %s\n", provider, cfg.Model.BaseURL, cfg.Model.Model)
	start := time.Now()
	test := svc.Handle(ctx, suggest.Request{Op: "model_test"})
	if !test.OK {
		fmt.Printf("  ❌ 调用失败：%s\n", test.Error)
		failed = true
	} else {
		fmt.Printf("  ✅ 模型可用，%d ms，回复：%s\n", time.Since(start).Milliseconds(), firstLine(test.Note))
	}
	if failed {
		return 1
	}
	fmt.Println("全部通过。")
	return 0
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len([]rune(s)) > 60 {
		s = string([]rune(s)[:60]) + "…"
	}
	return s
}
