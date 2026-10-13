package chatgpt

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeAuth stands in for auth.openai.com and api.openai.com.
type fakeAuth struct {
	t   *testing.T
	srv *httptest.Server

	mu             sync.Mutex
	nonce          string
	challenge      string
	tokenForms     []url.Values
	refreshStatus  int
	refreshBody    string
	refreshCount   atomic.Int32
	revoked        []url.Values
	idTokenNonce   string // overrides the nonce put in the ID token
	scope          string
	refreshLatency time.Duration
}

func newFakeAuth(t *testing.T) *fakeAuth {
	f := &fakeAuth{t: t, scope: Scopes}
	mux := http.NewServeMux()
	mux.HandleFunc("/api/accounts/oauth/token", f.token)
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"revocation_endpoint": %q}`, f.srv.URL+"/revoke")
	})
	mux.HandleFunc("/revoke", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		f.mu.Lock()
		f.revoked = append(f.revoked, r.PostForm)
		f.mu.Unlock()
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/models", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer access-1" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		fmt.Fprint(w, `{"models":[{"slug":"gpt-fast","display_name":"GPT Fast","visibility":"list",
			"description":"Quick","default_reasoning_level":"low",
			"supported_reasoning_levels":[{"effort":"low","description":"Fast"},{"effort":"high","description":"Deep"}],
			"service_tiers":[{"id":"priority","name":"Fast","description":"2x speed, increased usage"}]},
			{"slug":"internal","display_name":"Hidden","visibility":"hide"}]}`)
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAuth) idToken(clientID string) string {
	f.mu.Lock()
	nonce := f.nonce
	if f.idTokenNonce != "" {
		nonce = f.idTokenNonce
	}
	f.mu.Unlock()
	claims, _ := json.Marshal(map[string]any{
		"iss": f.srv.URL, "sub": "user-1", "email": "me@example.com", "nonce": nonce,
		"aud": []string{clientID}, "exp": time.Now().Add(time.Hour).Unix(),
	})
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"RS256"}`)) + "." + enc(claims) + ".sig"
}

func (f *fakeAuth) token(w http.ResponseWriter, r *http.Request) {
	_ = r.ParseForm()
	form := r.PostForm
	f.mu.Lock()
	f.tokenForms = append(f.tokenForms, form)
	challenge := f.challenge
	f.mu.Unlock()
	switch form.Get("grant_type") {
	case "authorization_code":
		if Challenge(form.Get("code_verifier")) != challenge || form.Get("resource") != Resource {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, `{"error":"invalid_grant"}`)
			return
		}
		fmt.Fprintf(w, `{"access_token":"access-1","refresh_token":"refresh-1","id_token":%q,"token_type":"Bearer","expires_in":3600,"scope":%q}`,
			f.idToken(form.Get("client_id")), f.scope)
	case "refresh_token":
		f.refreshCount.Add(1)
		time.Sleep(f.refreshLatency)
		if f.refreshStatus != 0 {
			w.WriteHeader(f.refreshStatus)
			fmt.Fprint(w, f.refreshBody)
			return
		}
		n := f.refreshCount.Load()
		fmt.Fprintf(w, `{"access_token":"access-r%d","refresh_token":"refresh-r%d","expires_in":3600,"scope":%q}`, n, n, Scopes)
	}
}

func newManager(t *testing.T, f *fakeAuth) *Manager {
	m := NewManager(filepath.Join(t.TempDir(), "chatgpt.json"))
	m.AuthBase, m.APIBase = f.srv.URL, f.srv.URL
	return m
}

// signIn runs the whole browser round trip and returns the authorize query.
func signIn(t *testing.T, m *Manager, f *fakeAuth, clientID string) url.Values {
	t.Helper()
	authURL, err := m.StartLogin()
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(authURL)
	q := u.Query()
	f.mu.Lock()
	f.nonce, f.challenge = q.Get("nonce"), q.Get("code_challenge")
	f.mu.Unlock()
	callback := q.Get("redirect_uri") + "?" + url.Values{"code": {"code-1"}, "state": {q.Get("state")}, "client_id": {clientID}}.Encode()
	resp, err := http.Get(callback)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return q
}

func TestChallengeMatchesRFC7636(t *testing.T) {
	if got := Challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"); got != "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" {
		t.Fatalf("challenge = %s", got)
	}
}

func TestFirstSignInRegistersAndSaves(t *testing.T) {
	f := newFakeAuth(t)
	m := newManager(t, f)
	q := signIn(t, m, f, "oaiapp_123")

	for key, want := range map[string]string{
		"client_id": "dynamic_agent_client", "agent_name_hint": "Tact", "response_type": "code",
		"scope": Scopes, "resource": Resource, "code_challenge_method": "S256",
	} {
		if q.Get(key) != want {
			t.Errorf("%s = %q, want %q", key, q.Get(key), want)
		}
	}
	if !strings.HasPrefix(q.Get("ext_agent_host_id"), "urn:uuid:") {
		t.Errorf("host id = %q", q.Get("ext_agent_host_id"))
	}
	if r := q.Get("redirect_uri"); !strings.HasPrefix(r, "http://127.0.0.1:") || !strings.HasSuffix(r, "/auth/callback") {
		t.Errorf("redirect_uri = %q", r)
	}

	st, err := m.Status()
	if err != nil || !st.SignedIn || st.Email != "me@example.com" || !st.PlanUsage || st.LoginPending {
		t.Fatalf("status = %+v, %v", st, err)
	}
	f.mu.Lock()
	form := f.tokenForms[0]
	f.mu.Unlock()
	if form.Get("client_id") != "oaiapp_123" || form.Get("redirect_uri") != q.Get("redirect_uri") {
		t.Fatalf("exchange form = %v", form)
	}
	info, err := os.Stat(m.Path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("credentials file mode = %v, %v", info.Mode(), err)
	}
}

func TestLaterSignInReusesRegistration(t *testing.T) {
	f := newFakeAuth(t)
	m := newManager(t, f)
	first := signIn(t, m, f, "oaiapp_123")
	if _, err := m.Logout(context.Background()); err != nil {
		t.Fatal(err)
	}
	second := signIn(t, m, f, "oaiapp_123")
	if second.Get("client_id") != "oaiapp_123" || second.Get("agent_name_hint") != "" {
		t.Fatalf("second sign-in should use the issued client: %v", second)
	}
	if second.Get("ext_agent_host_id") != first.Get("ext_agent_host_id") || second.Get("id_token_hint") == "" {
		t.Fatalf("second sign-in should reuse host id and send id_token_hint: %v", second)
	}
}

func TestStrayCallbackKeepsWaitingAndDenialStops(t *testing.T) {
	f := newFakeAuth(t)
	m := newManager(t, f)
	authURL, err := m.StartLogin()
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(authURL)
	q := u.Query()
	resp, err := http.Get(q.Get("redirect_uri") + "?state=wrong&code=x&client_id=y")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if st, _ := m.Status(); resp.StatusCode != http.StatusBadRequest || !st.LoginPending {
		t.Fatalf("stray callback: status %d, %+v", resp.StatusCode, st)
	}
	resp, err = http.Get(q.Get("redirect_uri") + "?" + url.Values{"state": {q.Get("state")}, "error": {"access_denied"}}.Encode())
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	st, _ := m.Status()
	if st.LoginPending || st.SignedIn || st.LoginError != "你取消了授权" {
		t.Fatalf("after denial: %+v", st)
	}
}

func TestNonceMismatchIsRejected(t *testing.T) {
	f := newFakeAuth(t)
	f.idTokenNonce = "someone-else"
	m := newManager(t, f)
	signIn(t, m, f, "oaiapp_123")
	st, _ := m.Status()
	if st.SignedIn || !strings.Contains(st.LoginError, "nonce") {
		t.Fatalf("status = %+v", st)
	}
}

func TestMissingPlanScope(t *testing.T) {
	f := newFakeAuth(t)
	f.scope = "openid profile email offline_access resource.invoke"
	m := newManager(t, f)
	signIn(t, m, f, "oaiapp_123")
	if st, _ := m.Status(); !st.SignedIn || st.PlanUsage {
		t.Fatalf("status = %+v", st)
	}
	if _, err := m.AccessToken(context.Background()); !errors.Is(err, ErrNoPlanScope) {
		t.Fatalf("want ErrNoPlanScope, got %v", err)
	}
}

func expire(t *testing.T, m *Manager) {
	t.Helper()
	m.mu.Lock()
	defer m.mu.Unlock()
	c, _ := m.loadLocked()
	next := *c
	next.ExpiresAt = m.Now().Add(-time.Minute)
	if err := m.saveLocked(&next); err != nil {
		t.Fatal(err)
	}
}

func TestRefreshRotatesOnceUnderConcurrency(t *testing.T) {
	f := newFakeAuth(t)
	f.refreshLatency = 30 * time.Millisecond
	m := newManager(t, f)
	signIn(t, m, f, "oaiapp_123")
	expire(t, m)

	var wg sync.WaitGroup
	tokens := make([]string, 8)
	for i := range tokens {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			tokens[i], _ = m.AccessToken(context.Background())
		}(i)
	}
	wg.Wait()
	if f.refreshCount.Load() != 1 {
		t.Fatalf("want one refresh, got %d", f.refreshCount.Load())
	}
	for _, tok := range tokens {
		if tok != "access-r1" {
			t.Fatalf("tokens = %v", tokens)
		}
	}
	data, _ := os.ReadFile(m.Path)
	if !strings.Contains(string(data), "refresh-r1") {
		t.Fatal("rotated refresh token was not saved")
	}
	f.mu.Lock()
	last := f.tokenForms[len(f.tokenForms)-1]
	f.mu.Unlock()
	if last.Get("client_id") != "oaiapp_123" || last.Get("refresh_token") != "refresh-1" || last.Has("scope") {
		t.Fatalf("refresh form = %v", last)
	}
}

func TestTerminalRefreshErrorClearsTokens(t *testing.T) {
	f := newFakeAuth(t)
	f.refreshStatus, f.refreshBody = http.StatusBadRequest, `{"error":"invalid_grant"}`
	m := newManager(t, f)
	signIn(t, m, f, "oaiapp_123")
	expire(t, m)
	if _, err := m.AccessToken(context.Background()); !errors.Is(err, ErrSignInAgain) {
		t.Fatalf("want ErrSignInAgain, got %v", err)
	}
	if st, _ := m.Status(); st.SignedIn {
		t.Fatalf("still signed in: %+v", st)
	}
	data, _ := os.ReadFile(m.Path)
	if !strings.Contains(string(data), "oaiapp_123") || strings.Contains(string(data), "refresh-1") {
		t.Fatalf("want the client id kept and tokens gone: %s", data)
	}
}

func TestServerErrorOnRefreshKeepsCredentials(t *testing.T) {
	f := newFakeAuth(t)
	f.refreshStatus, f.refreshBody = http.StatusServiceUnavailable, `{"error":"temporarily_unavailable"}`
	m := newManager(t, f)
	signIn(t, m, f, "oaiapp_123")
	expire(t, m)
	if _, err := m.AccessToken(context.Background()); err == nil || errors.Is(err, ErrSignInAgain) {
		t.Fatalf("want a temporary error, got %v", err)
	}
	if st, _ := m.Status(); !st.SignedIn {
		t.Fatal("a server error must not sign the user out")
	}
}

func TestLogoutRevokesRefreshToken(t *testing.T) {
	f := newFakeAuth(t)
	m := newManager(t, f)
	signIn(t, m, f, "oaiapp_123")
	revoked, err := m.Logout(context.Background())
	if err != nil || !revoked {
		t.Fatalf("logout: %v, %v", revoked, err)
	}
	f.mu.Lock()
	form := f.revoked[0]
	f.mu.Unlock()
	if form.Get("token") != "refresh-1" || form.Get("token_type_hint") != "refresh_token" || form.Get("client_id") != "oaiapp_123" {
		t.Fatalf("revocation form = %v", form)
	}
	if st, _ := m.Status(); st.SignedIn {
		t.Fatal("still signed in after logout")
	}
}

func TestModelsListsVisibleOnlyWithSpeedOptions(t *testing.T) {
	f := newFakeAuth(t)
	m := newManager(t, f)
	signIn(t, m, f, "oaiapp_123")
	models, err := m.Models(context.Background())
	if err != nil || len(models) != 1 || models[0].Slug != "gpt-fast" || models[0].DisplayName != "GPT Fast" {
		t.Fatalf("models = %v, %v", models, err)
	}
	got := models[0]
	if got.DefaultReasoning != "low" || len(got.ReasoningLevels) != 2 || got.ReasoningLevels[1].Effort != "high" {
		t.Fatalf("reasoning = %+v", got)
	}
	if len(got.SpeedTiers) != 1 || got.SpeedTiers[0].ID != "priority" || got.SpeedTiers[0].Name != "Fast" {
		t.Fatalf("speed tiers = %+v", got.SpeedTiers)
	}
}

// The app's engine and a CLI run share the credentials file: a refresh by
// one must be picked up by the other instead of reusing the rotated token.
func TestSecondProcessUsesRefreshedTokens(t *testing.T) {
	f := newFakeAuth(t)
	first := newManager(t, f)
	signIn(t, first, f, "oaiapp_123")
	second := NewManager(first.Path)
	second.AuthBase, second.APIBase = first.AuthBase, first.APIBase
	if _, err := second.AccessToken(context.Background()); err != nil {
		t.Fatal(err)
	}
	expire(t, first)
	tok, err := first.AccessToken(context.Background())
	if err != nil || tok != "access-r1" {
		t.Fatalf("first refresh: %q, %v", tok, err)
	}
	time.Sleep(10 * time.Millisecond) // let the file's modification time move on
	tok, err = second.AccessToken(context.Background())
	if err != nil || tok != "access-r1" || f.refreshCount.Load() != 1 {
		t.Fatalf("second process: %q, %v, %d refreshes", tok, err, f.refreshCount.Load())
	}
}

func TestTwoProcessesRefreshOnce(t *testing.T) {
	f := newFakeAuth(t)
	f.refreshLatency = 50 * time.Millisecond
	first := newManager(t, f)
	signIn(t, first, f, "oaiapp_123")
	expire(t, first)
	second := NewManager(first.Path)
	second.AuthBase, second.APIBase = first.AuthBase, first.APIBase

	var wg sync.WaitGroup
	tokens := make([]string, 2)
	for i, m := range []*Manager{first, second} {
		wg.Add(1)
		go func(i int, m *Manager) {
			defer wg.Done()
			tokens[i], _ = m.AccessToken(context.Background())
		}(i, m)
	}
	wg.Wait()
	if f.refreshCount.Load() != 1 || tokens[0] != "access-r1" || tokens[1] != "access-r1" {
		t.Fatalf("want one refresh shared by both, got %d refreshes, tokens %v", f.refreshCount.Load(), tokens)
	}
}

func TestNotSignedIn(t *testing.T) {
	m := NewManager(filepath.Join(t.TempDir(), "chatgpt.json"))
	if _, err := m.AccessToken(context.Background()); !errors.Is(err, ErrNotSignedIn) {
		t.Fatalf("want ErrNotSignedIn, got %v", err)
	}
	if st, err := m.Status(); err != nil || st.SignedIn {
		t.Fatalf("status = %+v, %v", st, err)
	}
}
