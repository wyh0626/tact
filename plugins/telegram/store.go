package main

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Set at release build time (-ldflags "-X main.builtinAppID=… -X
// main.builtinAppHash=…") so that people only scan a QR code. Source
// builds leave them empty and ask for the developer's own credentials.
var (
	builtinAppID   string
	builtinAppHash string
)

// App is the Telegram API application this plugin connects as.
type App struct {
	ID   int    `json:"api_id"`
	Hash string `json:"api_hash"`
}

func (a App) validate() error {
	if a.ID <= 0 {
		return errors.New("api_id 应该是一个正整数")
	}
	if b, err := hex.DecodeString(a.Hash); err != nil || len(b) != 16 {
		return errors.New("api_hash 应该是 32 位十六进制字符")
	}
	return nil
}

// Store keeps the plugin's state in one folder only its owner can read:
// the API credentials, the signed-in session and the access hashes of
// known chats. Access hashes stay out of chat IDs and process arguments.
type Store struct {
	Dir string
}

// DefaultStore is ~/.tact/telegram, or TACT_TELEGRAM_DIR.
func DefaultStore() (Store, error) {
	if dir := os.Getenv("TACT_TELEGRAM_DIR"); dir != "" {
		return Store{Dir: dir}, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return Store{}, err
	}
	return Store{Dir: filepath.Join(home, ".tact", "telegram")}, nil
}

func (s Store) path(name string) string { return filepath.Join(s.Dir, name) }

func (s Store) SessionPath() string { return s.path("session.json") }

func (s Store) ensure() error {
	if err := os.MkdirAll(s.Dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(s.Dir, 0o700)
}

// writeJSON replaces a file atomically with owner-only permissions.
func (s Store) writeJSON(name string, value any) error {
	if err := s.ensure(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(s.Dir, "."+name+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.path(name))
}

func (s Store) readJSON(name string, value any) error {
	data, err := os.ReadFile(s.path(name))
	if err != nil {
		return err
	}
	return json.Unmarshal(data, value)
}

// App returns the built-in credentials, or the ones saved at login.
func (s Store) App() (App, error) {
	if builtinAppID != "" && builtinAppHash != "" {
		id, err := strconv.Atoi(builtinAppID)
		if err != nil {
			return App{}, fmt.Errorf("内置的 api_id 不是数字：%w", err)
		}
		app := App{ID: id, Hash: builtinAppHash}
		return app, app.validate()
	}
	var app App
	if err := s.readJSON("app.json", &app); err != nil {
		return App{}, err
	}
	return app, app.validate()
}

func (s Store) SaveApp(app App) error {
	if err := app.validate(); err != nil {
		return err
	}
	return s.writeJSON("app.json", app)
}

func (s Store) SignedIn() bool {
	info, err := os.Stat(s.SessionPath())
	return err == nil && info.Size() > 0
}

// Peer is a chat as the API addresses it.
type Peer struct {
	Kind       string `json:"kind"` // user, chat or channel
	ID         int64  `json:"id"`
	AccessHash int64  `json:"access_hash,omitempty"`
}

// ChatID is the chat's ID in the plugin protocol: its kind and number.
func (p Peer) ChatID() string { return p.Kind + ":" + strconv.FormatInt(p.ID, 10) }

func parseChatID(id string) (kind string, number int64, err error) {
	kind, rest, ok := strings.Cut(id, ":")
	if ok {
		number, err = strconv.ParseInt(rest, 10, 64)
	}
	if !ok || err != nil || number <= 0 || (kind != "user" && kind != "chat" && kind != "channel") {
		return "", 0, fmt.Errorf("不是 Telegram 会话 ID：%q", id)
	}
	return kind, number, nil
}

// Peers maps chat IDs to how the API reaches them.
type Peers map[string]Peer

func (s Store) Peers() (Peers, error) {
	peers := Peers{}
	err := s.readJSON("peers.json", &peers)
	if errors.Is(err, os.ErrNotExist) {
		return Peers{}, nil
	}
	return peers, err
}

func (s Store) SavePeers(peers Peers) error { return s.writeJSON("peers.json", peers) }

// Forget removes the session and what was learnt with it; the API
// credentials stay for the next sign-in.
func (s Store) Forget() error {
	var errs []error
	for _, name := range []string{"session.json", "peers.json"} {
		if err := os.Remove(s.path(name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
