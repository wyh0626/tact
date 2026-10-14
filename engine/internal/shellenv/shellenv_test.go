package shellenv

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"
)

// fakeShell writes a stand-in for a login shell: it runs `before`, the way
// startup files would, then the command it was given after -i -l -c.
func fakeShell(t *testing.T, before string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "zsh")
	script := "#!/bin/sh\n" + before + "\nshift 3\neval \"$1\"\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func value(env []string, k string) string {
	for _, kv := range env {
		if strings.HasPrefix(kv, k+"=") {
			return strings.TrimPrefix(kv, k+"=")
		}
	}
	return ""
}

func TestTheShellsPathReachesPlugins(t *testing.T) {
	// A startup file that talks and extends PATH, as zsh setups do.
	shell := fakeShell(t, `echo "Welcome back"; export PATH="/usr/local/bin:/opt/tools/bin:$PATH"; export HTTP_PROXY=http://proxy:8080`)
	base := []string{"PATH=/usr/bin:/bin", "HOME=/Users/someone", "TACT_SOMETHING=kept"}
	env, err := Resolve(context.Background(), shell, base, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if got := value(env, "PATH"); !strings.HasPrefix(got, "/usr/local/bin:/opt/tools/bin:") {
		t.Errorf("PATH = %q", got)
	}
	if value(env, "HTTP_PROXY") != "http://proxy:8080" || value(env, "TACT_SOMETHING") != "kept" {
		t.Errorf("env = %v", env)
	}
	for _, k := range []string{"TACT_RESOLVING_ENVIRONMENT", "DISABLE_AUTO_UPDATE", "SHLVL", "PWD"} {
		if value(env, k) != "" {
			t.Errorf("%s leaked from the probe shell", k)
		}
	}
}

func TestValuesWithNewlinesStayWhole(t *testing.T) {
	shell := fakeShell(t, `export NOTE="line one
line two"`)
	env, err := Resolve(context.Background(), shell, []string{"PATH=/usr/bin:/bin"}, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if value(env, "NOTE") != "line one\nline two" {
		t.Errorf("NOTE = %q", value(env, "NOTE"))
	}
}

func TestStartupFilesSeeTheProbeSettings(t *testing.T) {
	shell := fakeShell(t, `[ "$TACT_RESOLVING_ENVIRONMENT" = 1 ] && [ "$DISABLE_AUTO_UPDATE" = true ] && export SAW_PROBE=yes`)
	env, err := Resolve(context.Background(), shell, []string{"PATH=/usr/bin:/bin"}, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if value(env, "SAW_PROBE") != "yes" {
		t.Error("startup files did not see TACT_RESOLVING_ENVIRONMENT and DISABLE_AUTO_UPDATE")
	}
}

func TestASlowShellTimesOut(t *testing.T) {
	shell := fakeShell(t, `sleep 30`)
	start := time.Now()
	if _, err := Resolve(context.Background(), shell, []string{"PATH=/usr/bin:/bin"}, 300*time.Millisecond); err == nil {
		t.Fatal("a shell that never answers must fail")
	}
	if time.Since(start) > 3*time.Second {
		t.Errorf("gave up after %v", time.Since(start))
	}
}

func TestAShellThatFailsGivesAnError(t *testing.T) {
	shell := fakeShell(t, `exit 1`)
	if _, err := Resolve(context.Background(), shell, []string{"PATH=/usr/bin:/bin"}, 5*time.Second); err == nil {
		t.Fatal("expected an error")
	}
}

func TestWithoutTheShellCommonFoldersAreAdded(t *testing.T) {
	env := withCommonPaths([]string{"PATH=/usr/bin:/bin:/usr/local/bin", "HOME=/Users/someone"})
	dirs := strings.Split(value(env, "PATH"), ":")
	for _, dir := range []string{"/opt/homebrew/bin", "/usr/local/bin"} {
		if !slices.Contains(dirs, dir) {
			t.Errorf("PATH %v lacks %s", dirs, dir)
		}
	}
	if strings.Count(value(env, "PATH"), "/usr/local/bin") != 1 {
		t.Errorf("PATH repeats a folder: %s", value(env, "PATH"))
	}
	if dirs[0] != "/usr/bin" {
		t.Errorf("the existing PATH must come first: %v", dirs)
	}
}

func TestOnlyShellsThatTakeCommandsAreAsked(t *testing.T) {
	for shell, want := range map[string]string{
		"/bin/zsh": "/bin/zsh", "/opt/homebrew/bin/fish": "/opt/homebrew/bin/fish", "/bin/bash": "/bin/bash",
		"/opt/homebrew/bin/nu": "/bin/zsh", "/bin/tcsh": "/bin/zsh", "": "/bin/zsh",
	} {
		if got := LoginShell(shell); got != want {
			t.Errorf("LoginShell(%q) = %q, want %q", shell, got, want)
		}
	}
}
