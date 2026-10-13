package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testStore(t *testing.T) Store {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "telegram")
	t.Setenv("TACT_TELEGRAM_DIR", dir)
	return Store{Dir: dir}
}

func runOp(t *testing.T, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errOut bytes.Buffer
	code = run(context.Background(), args, os.Stdin, &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestReadsNeedASignInAndNeverConnectWithoutOne(t *testing.T) {
	testStore(t)
	for _, args := range [][]string{{"chats"}, {"history", "user:7", "20"}} {
		code, stdout, stderr := runOp(t, args...)
		if code != exitFailed || stdout != "" || !strings.Contains(stderr, "扫码登录") {
			t.Errorf("%v: code %d, stdout %q, stderr %q", args, code, stdout, stderr)
		}
	}
}

func TestProtocolExitCodes(t *testing.T) {
	testStore(t)
	cases := []struct {
		args []string
		code int
	}{
		{nil, exitUsage},
		{[]string{"send", "user:7", "hi"}, exitUsage},
		{[]string{"history", "user:7"}, exitUsage},
		{[]string{"history", "user:7", "0"}, exitUsage},
		{[]string{"history", "user:7", "x"}, exitUsage},
		{[]string{"drafts"}, exitUnsupported},
	}
	for _, c := range cases {
		if code, stdout, _ := runOp(t, c.args...); code != c.code || stdout != "" {
			t.Errorf("%v: code %d, stdout %q", c.args, code, stdout)
		}
	}
}

func TestHealthSaysWhatIsSetUpWithoutConnecting(t *testing.T) {
	store := testStore(t)
	read := func() map[string]any {
		code, stdout, stderr := runOp(t, "health")
		var got map[string]any
		if code != exitOK || json.Unmarshal([]byte(stdout), &got) != nil {
			t.Fatalf("health: code %d, %q, %q", code, stdout, stderr)
		}
		return got
	}
	if got := read(); got["authentication"] != "signed_out" || got["available"] != true {
		t.Errorf("fresh: %v", got)
	}
	if err := store.SaveApp(App{ID: 12345, Hash: strings.Repeat("ab", 16)}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store.SessionPath(), []byte(`{"Version":1}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := read(); got["authentication"] != "unknown" || got["available"] != true {
		t.Errorf("with a session: %v", got)
	}
}

func TestStateIsOwnerOnly(t *testing.T) {
	store := testStore(t)
	if err := store.SaveApp(App{ID: 12345, Hash: strings.Repeat("0f", 16)}); err != nil {
		t.Fatal(err)
	}
	if err := store.SavePeers(Peers{"user:7": {Kind: "user", ID: 7, AccessHash: 99}}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{store.Dir, store.path("app.json"), store.path("peers.json")} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s is %v", path, info.Mode().Perm())
		}
	}
	peers, err := store.Peers()
	if err != nil || peers["user:7"].AccessHash != 99 {
		t.Errorf("peers %v %v", peers, err)
	}
	app, err := store.App()
	if err != nil || app.ID != 12345 {
		t.Errorf("app %+v %v", app, err)
	}
	if err := os.WriteFile(store.SessionPath(), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := store.Forget(); err != nil {
		t.Fatal(err)
	}
	if store.SignedIn() {
		t.Error("forgetting keeps no session")
	}
	if _, err := os.Stat(store.path("peers.json")); !errors.Is(err, os.ErrNotExist) {
		t.Error("forgetting keeps no access hashes")
	}
	if _, err := store.App(); err != nil {
		t.Error("the API credentials stay for the next sign-in")
	}
}

func TestCredentialsAreChecked(t *testing.T) {
	store := testStore(t)
	for _, app := range []App{{ID: 0, Hash: strings.Repeat("ab", 16)}, {ID: 1, Hash: "short"}, {ID: 1, Hash: strings.Repeat("zz", 16)}} {
		if store.SaveApp(app) == nil {
			t.Errorf("%+v saved", app)
		}
	}
	if _, err := store.App(); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("nothing saved, got %v", err)
	}
	builtinAppID, builtinAppHash = "54321", strings.Repeat("cd", 16)
	defer func() { builtinAppID, builtinAppHash = "", "" }()
	if app, err := store.App(); err != nil || app.ID != 54321 {
		t.Errorf("built-in credentials: %+v %v", app, err)
	}
}

func TestQRCodeIsSquareWithAQuietZone(t *testing.T) {
	text, err := qrText("tg://login?token=AQIDBAUGBwgJCgsMDQ4PEA")
	if err != nil {
		t.Fatal(err)
	}
	rows := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	width := len([]rune(strings.TrimSuffix(strings.TrimPrefix(rows[0], "\x1b[30;107m"), "\x1b[0m")))
	if width < 25 || len(rows) != (width+1)/2 {
		t.Fatalf("%d rows of %d", len(rows), width)
	}
	if strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(rows[0], "\x1b[30;107m"), "\x1b[0m")) != "" {
		t.Error("the first row is quiet zone")
	}
}
