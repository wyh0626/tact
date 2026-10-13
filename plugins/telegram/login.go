package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gotd/td/telegram/auth/qrlogin"
	"github.com/gotd/td/tg"
	"github.com/gotd/td/tgerr"
	"golang.org/x/term"
	"rsc.io/qr"
)

// Prompt reads answers in the terminal; secrets are not echoed.
type Prompt struct {
	in  *bufio.Reader
	fd  int
	tty bool
	out io.Writer
}

func newPrompt(in *os.File, out io.Writer) *Prompt {
	fd := int(in.Fd())
	return &Prompt{in: bufio.NewReader(in), fd: fd, tty: term.IsTerminal(fd), out: out}
}

func (p *Prompt) ask(question string) (string, error) {
	fmt.Fprint(p.out, question)
	line, err := p.in.ReadString('\n')
	if err != nil && line == "" {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

func (p *Prompt) secret(question string) (string, error) {
	if !p.tty {
		return p.ask(question)
	}
	fmt.Fprint(p.out, question)
	value, err := term.ReadPassword(p.fd)
	fmt.Fprintln(p.out)
	return strings.TrimSpace(string(value)), err
}

// appForLogin returns saved or built-in credentials, or asks for the
// developer's own (my.telegram.org → API development tools).
func appForLogin(store Store, prompt *Prompt) (App, error) {
	if app, err := store.App(); err == nil {
		return app, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		fmt.Fprintf(prompt.out, "保存的 API 凭据不能用（%v），请重新填写。\n", err)
	}
	fmt.Fprintln(prompt.out, "需要 Telegram API 凭据：在 https://my.telegram.org 登录，进入 API development tools 创建一个应用。")
	fmt.Fprintln(prompt.out, "它只保存在这台 Mac 的 "+store.path("app.json")+"（只有你能读）。")
	raw, err := prompt.ask("api_id：")
	if err != nil {
		return App{}, err
	}
	id, err := strconv.Atoi(raw)
	if err != nil {
		return App{}, errors.New("api_id 应该是一个正整数")
	}
	hash, err := prompt.secret("api_hash（输入时不显示）：")
	if err != nil {
		return App{}, err
	}
	app := App{ID: id, Hash: strings.ToLower(hash)}
	if err := store.SaveApp(app); err != nil {
		return App{}, err
	}
	return app, nil
}

// login signs in by QR code: the phone's Telegram scans it under
// Settings → Devices → Link Desktop Device, so no phone number or code is
// typed here. Accounts with two-step verification are asked for the
// password afterwards.
func login(ctx context.Context, store Store, prompt *Prompt) error {
	app, err := appForLogin(store, prompt)
	if err != nil {
		return err
	}
	if err := store.ensure(); err != nil {
		return err
	}
	dispatcher := tg.NewUpdateDispatcher()
	loggedIn := qrlogin.OnLoginToken(dispatcher)
	client := newClient(store, app, dispatcher)
	return client.Run(ctx, func(ctx context.Context) error {
		if status, err := client.Auth().Status(ctx); err == nil && status.Authorized {
			fmt.Fprintf(prompt.out, "已经登录：%s\n", userName(status.User))
			return nil
		}
		_, err := client.QR().Auth(ctx, loggedIn, func(ctx context.Context, token qrlogin.Token) error {
			code, err := qrText(token.URL())
			if err != nil {
				return err
			}
			fmt.Fprintln(prompt.out, "\n用手机 Telegram 扫描下面的二维码：设置 → 设备 → 关联桌面设备")
			fmt.Fprint(prompt.out, code)
			fmt.Fprintf(prompt.out, "二维码 %s 前有效，过期会自动换一个。\n", token.Expires().Local().Format("15:04:05"))
			return nil
		})
		if tgerr.Is(err, "SESSION_PASSWORD_NEEDED") {
			password, perr := prompt.secret("这个账号开了两步验证，请输入密码（输入时不显示）：")
			if perr != nil {
				return perr
			}
			_, err = client.Auth().Password(ctx, password)
		}
		if err != nil {
			return fmt.Errorf("登录没有完成：%w", err)
		}
		self, err := client.Self(ctx)
		if err != nil {
			return err
		}
		fmt.Fprintf(prompt.out, "登录成功：%s。Tact 只读取会话和消息，不会发送、修改或标记已读。\n", userName(self))
		fmt.Fprintln(prompt.out, "可以在手机 Telegram 的 设置 → 设备 里看到并随时结束这个名为 Tact 的会话。")
		return nil
	})
}

// logout ends the session on Telegram's side, then forgets it here. The
// local copy is removed even when Telegram cannot be reached.
func logout(ctx context.Context, store Store, out io.Writer) error {
	if !store.SignedIn() {
		fmt.Fprintln(out, "没有登录。")
		return store.Forget()
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	remote := signedIn(ctx, store, func(ctx context.Context, api *tg.Client) error {
		_, err := api.AuthLogOut(ctx)
		return err
	})
	if err := store.Forget(); err != nil {
		return err
	}
	if remote != nil && !errors.Is(remote, errSignedOut) {
		fmt.Fprintf(out, "已删除这台 Mac 上的登录信息，但没能通知 Telegram（%v）。请在手机 Telegram 的 设置 → 设备 里结束 Tact。\n", remote)
		return nil
	}
	fmt.Fprintln(out, "已退出登录。")
	return nil
}

// qrText draws a QR code with half-height blocks, black on white whatever
// the terminal's colours, with the quiet zone scanners need.
func qrText(content string) (string, error) {
	code, err := qr.Encode(content, qr.M)
	if err != nil {
		return "", err
	}
	const quiet = 2
	black := func(x, y int) bool {
		x, y = x-quiet, y-quiet
		return x >= 0 && y >= 0 && x < code.Size && y < code.Size && code.Black(x, y)
	}
	size := code.Size + 2*quiet
	var b strings.Builder
	for y := 0; y < size; y += 2 {
		b.WriteString("\x1b[30;107m")
		for x := 0; x < size; x++ {
			switch top, bottom := black(x, y), black(x, y+1); {
			case top && bottom:
				b.WriteString("█")
			case top:
				b.WriteString("▀")
			case bottom:
				b.WriteString("▄")
			default:
				b.WriteString(" ")
			}
		}
		b.WriteString("\x1b[0m\n")
	}
	return b.String(), nil
}
