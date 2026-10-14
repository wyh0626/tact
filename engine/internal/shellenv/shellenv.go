// Package shellenv gives plugins the environment the user's terminal has.
//
// An app opened from Finder or the Dock gets the bare environment launchd
// hands out, with PATH set to the system folders alone, so a plugin's
// command-line tool that works in Terminal is not found from Tact. Like VS
// Code, JetBrains IDEs and Electron's shell-env, the engine asks the user's
// own login shell once, in the background, for the environment its startup
// files build, and runs plugins with that. A shell that is slow, waits for
// input or fails leaves the engine's own environment, with the folders where
// installers and Homebrew put tools added to PATH.
package shellenv

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Timeout bounds how long a login shell may take to start, as VS Code's
// default does.
const Timeout = 10 * time.Second

// Environ is the environment to run plugins with. The first call resolves
// it, which may take up to Timeout; the engine starts that call at launch so
// plugins seldom wait.
var Environ = sync.OnceValue(func() []string {
	start := time.Now()
	shell := LoginShell(os.Getenv("SHELL"))
	env, err := Resolve(context.Background(), shell, os.Environ(), Timeout)
	if err != nil {
		log.Printf("读取登录 shell（%s）的环境失败，插件用默认 PATH 加常见目录：%v", filepath.Base(shell), err)
		return withCommonPaths(os.Environ())
	}
	log.Printf("已读取登录 shell（%s）的环境，用时 %v", filepath.Base(shell), time.Since(start).Round(time.Millisecond))
	return env
})

// LoginShell is the shell to ask: the user's own when it takes POSIX-style
// -c commands, else zsh, macOS's default.
func LoginShell(shell string) string {
	switch filepath.Base(shell) {
	case "sh", "bash", "zsh", "ksh", "dash", "fish":
		return shell
	}
	return "/bin/zsh"
}

// probe is set while the shell starts: oh-my-zsh skips its update check and
// tmux autostart, and startup files can test TACT_RESOLVING_ENVIRONMENT to
// skip what only makes sense in a terminal.
var probe = []string{"TACT_RESOLVING_ENVIRONMENT=1", "DISABLE_AUTO_UPDATE=true",
	"ZSH_TMUX_AUTOSTART=false", "ZSH_TMUX_AUTOSTARTED=true"}

// Resolve runs shell as an interactive login shell, so it reads the same
// startup files as Terminal, and returns base overlaid with the environment
// it ends up with.
func Resolve(ctx context.Context, shell string, base []string, timeout time.Duration) ([]string, error) {
	mark, err := marker()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	// Startup files may print banners or prompts; the marks fence off env's
	// output, and -0 keeps values with newlines whole.
	script := fmt.Sprintf("printf '%%s' %s; /usr/bin/env -0; printf '%%s' %s", mark, mark)
	cmd := exec.CommandContext(ctx, shell, "-i", "-l", "-c", script)
	cmd.Env = append(append([]string{}, base...), probe...)
	// Its own process group, killed whole on timeout: a startup file may
	// have started something that keeps stdout open.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = 500 * time.Millisecond
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	runErr := cmd.Run()
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return nil, fmt.Errorf("超过 %v 没有返回", timeout)
	}
	parts := strings.Split(stdout.String(), mark)
	if len(parts) < 3 {
		if runErr != nil {
			return nil, runErr
		}
		return nil, errors.New("没有读到环境变量")
	}
	return merge(base, strings.Split(parts[1], "\x00")), nil
}

// merge lays the shell's variables over base. What only describes the probe
// shell itself is left out, and the probe's own settings keep base's value.
func merge(base, shell []string) []string {
	skip := map[string]bool{"PWD": true, "OLDPWD": true, "SHLVL": true, "_": true}
	for _, kv := range probe {
		skip[key(kv)] = true
	}
	values := map[string]string{}
	var order []string
	set := func(kv string) {
		k := key(kv)
		if k == "" {
			return
		}
		if _, seen := values[k]; !seen {
			order = append(order, k)
		}
		values[k] = kv
	}
	for _, kv := range base {
		set(kv)
	}
	for _, kv := range shell {
		if k := key(kv); k != "" && !skip[k] {
			set(kv)
		}
	}
	env := make([]string, 0, len(order))
	for _, k := range order {
		env = append(env, values[k])
	}
	return env
}

// withCommonPaths adds to PATH the folders installers and Homebrew use,
// which a login shell would usually have put there.
func withCommonPaths(base []string) []string {
	extra := []string{"/opt/homebrew/bin", "/usr/local/bin"}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		extra = append([]string{filepath.Join(home, ".local", "bin")}, extra...)
	}
	env := append([]string{}, base...)
	for i, kv := range env {
		if key(kv) != "PATH" {
			continue
		}
		dirs := strings.Split(strings.TrimPrefix(kv, "PATH="), ":")
		for _, dir := range extra {
			if !slices.Contains(dirs, dir) {
				dirs = append(dirs, dir)
			}
		}
		env[i] = "PATH=" + strings.Join(dirs, ":")
		return env
	}
	return append(env, "PATH="+strings.Join(append([]string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"}, extra...), ":"))
}

func key(kv string) string {
	k, _, ok := strings.Cut(kv, "=")
	if !ok {
		return ""
	}
	return k
}

func marker() (string, error) {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return "TACT_ENV_" + hex.EncodeToString(b), nil
}
