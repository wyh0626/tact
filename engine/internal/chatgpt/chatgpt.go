// Package chatgpt implements "Sign in with ChatGPT" for an open-source,
// locally run app, so that model requests are billed to the user's ChatGPT
// plan instead of an API key: OAuth authorization code with PKCE and a
// loopback redirect, dynamic client registration on first sign-in, rotating
// refresh tokens, and revocation on sign-out.
//
// Protocol reference: https://developers.openai.com/siwc/token-sharing-open-source
package chatgpt

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	DefaultAuthBase = "https://auth.openai.com"
	// Resource is the audience the tokens are issued for; it is sent with
	// every authorization, exchange and refresh request.
	Resource = "https://api.openai.com/v1"
	// PlanScope is the scope that lets requests use the ChatGPT plan.
	PlanScope = "chatgpt.tokens.use.direct"
	Scopes    = "openid profile email offline_access resource.invoke " + PlanScope
	// The client ID to use until registration has issued one.
	dynamicClientID = "dynamic_agent_client"
	appName         = "Tact"
	callbackPath    = "/auth/callback"
	preferredPort   = 1455
	loginTimeout    = 5 * time.Minute
	// Refresh this long before the access token expires.
	refreshMargin = 2 * time.Minute
)

var (
	ErrNotSignedIn = errors.New("还没有用 ChatGPT 账号登录")
	ErrSignInAgain = errors.New("ChatGPT 登录已失效，请在设置里重新登录")
	ErrNoPlanScope = errors.New("登录时没有授权使用 ChatGPT 套餐，请重新登录并允许")
)

// Credentials is one registration on this host. Tokens are cleared on
// sign-out or when the session can no longer be refreshed; the issued client
// ID and host ID are kept so the next sign-in reuses the registration.
type Credentials struct {
	HostID       string    `json:"ext_agent_host_id"`
	ClientID     string    `json:"client_id,omitempty"`
	Issuer       string    `json:"issuer,omitempty"`
	Subject      string    `json:"subject,omitempty"`
	Email        string    `json:"email,omitempty"`
	IDToken      string    `json:"id_token,omitempty"`
	AccessToken  string    `json:"access_token,omitempty"`
	RefreshToken string    `json:"refresh_token,omitempty"`
	TokenType    string    `json:"token_type,omitempty"`
	ExpiresAt    time.Time `json:"expires_at,omitempty"`
	Scopes       []string  `json:"scopes,omitempty"`
	SavedAt      time.Time `json:"saved_at,omitempty"`
}

func (c *Credentials) signedIn() bool { return c != nil && c.AccessToken != "" && c.RefreshToken != "" }

func (c *Credentials) hasScope(scope string) bool {
	for _, s := range c.Scopes {
		if s == scope {
			return true
		}
	}
	return false
}

func (c *Credentials) clearTokens() {
	c.AccessToken, c.RefreshToken, c.TokenType = "", "", ""
	c.ExpiresAt = time.Time{}
	c.Scopes = nil
}

// Status is what the settings window shows.
type Status struct {
	SignedIn     bool   `json:"signed_in"`
	Email        string `json:"email,omitempty"`
	PlanUsage    bool   `json:"plan_usage"`
	LoginPending bool   `json:"login_pending"`
	LoginError   string `json:"login_error,omitempty"`
}

// Model is one model the signed-in account can use, with what it offers
// for speed: its reasoning levels and any faster service tiers.
type Model struct {
	Slug             string           `json:"slug"`
	DisplayName      string           `json:"display_name"`
	Description      string           `json:"description,omitempty"`
	ReasoningLevels  []ReasoningLevel `json:"reasoning_levels,omitempty"`
	DefaultReasoning string           `json:"default_reasoning,omitempty"`
	SpeedTiers       []SpeedTier      `json:"speed_tiers,omitempty"`
}

type ReasoningLevel struct {
	Effort      string `json:"effort"`
	Description string `json:"description,omitempty"`
}

// SpeedTier is a service tier such as Fast ("priority"), which answers
// sooner and uses more of the plan.
type SpeedTier struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

// Manager owns the credentials file. All token reads and refreshes go through
// it under one lock, so a rotating refresh token is never used twice.
type Manager struct {
	Path     string
	AuthBase string
	APIBase  string
	HTTP     *http.Client
	Now      func() time.Time

	mu         sync.Mutex
	creds      *Credentials
	loaded     bool
	loadedMod  time.Time
	loadedSize int64
	login      *pendingLogin
	loginError string
}

func NewManager(path string) *Manager {
	return &Manager{
		Path:     path,
		AuthBase: DefaultAuthBase,
		APIBase:  Resource,
		HTTP: &http.Client{
			Timeout: 30 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return errors.New("登录服务返回了重定向，已拒绝跟随")
			},
		},
		Now: time.Now,
	}
}

// --- persistence ---------------------------------------------------------

// loadLocked returns the credentials, reading the file again whenever it
// changed on disk: another process (the CLI next to the app's engine) may
// have refreshed the tokens, and a rotated refresh token must not be reused.
func (m *Manager) loadLocked() (*Credentials, error) {
	info, statErr := os.Stat(m.Path)
	if m.loaded && statErr == nil && info.ModTime().Equal(m.loadedMod) && info.Size() == m.loadedSize {
		return m.creds, nil
	}
	if m.loaded && errors.Is(statErr, os.ErrNotExist) && m.creds == nil {
		return nil, nil
	}
	data, err := os.ReadFile(m.Path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		m.creds = nil
		m.loadedMod, m.loadedSize = time.Time{}, 0
	case err != nil:
		return nil, fmt.Errorf("读取 ChatGPT 登录信息失败：%w", err)
	default:
		var c Credentials
		if err := json.Unmarshal(data, &c); err != nil {
			return nil, fmt.Errorf("ChatGPT 登录信息文件已损坏：%w", err)
		}
		m.creds = &c
		if statErr == nil {
			m.loadedMod, m.loadedSize = info.ModTime(), info.Size()
		}
	}
	m.loaded = true
	return m.creds, nil
}

// lockFile serializes token refreshes across processes sharing the file.
func (m *Manager) lockFile() (func(), error) {
	if err := os.MkdirAll(filepath.Dir(m.Path), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(m.Path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

// saveLocked writes atomically with owner-only permissions; the file holds
// tokens and is never logged.
func (m *Manager) saveLocked(c *Credentials) error {
	c.SavedAt = m.Now()
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(m.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".chatgpt-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), m.Path); err != nil {
		return err
	}
	m.creds = c
	m.loaded = true
	if info, err := os.Stat(m.Path); err == nil {
		m.loadedMod, m.loadedSize = info.ModTime(), info.Size()
	}
	return nil
}

// hostIDLocked returns the persistent host identifier, creating it before the
// host's first sign-in. It is an opaque urn:uuid, never user-identifying.
func (m *Manager) hostIDLocked() (*Credentials, error) {
	c, err := m.loadLocked()
	if err != nil {
		return nil, err
	}
	if c != nil && c.HostID != "" {
		return c, nil
	}
	id, err := uuidV4()
	if err != nil {
		return nil, err
	}
	next := &Credentials{HostID: "urn:uuid:" + id}
	if c != nil {
		copied := *c
		copied.HostID = next.HostID
		next = &copied
	}
	if err := m.saveLocked(next); err != nil {
		return nil, err
	}
	return next, nil
}

// --- status ----------------------------------------------------------------

func (m *Manager) Status() (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, err := m.loadLocked()
	if err != nil {
		return Status{}, err
	}
	s := Status{LoginPending: m.login != nil, LoginError: m.loginError}
	if c.signedIn() {
		s.SignedIn = true
		s.Email = c.Email
		s.PlanUsage = c.hasScope(PlanScope)
	}
	return s, nil
}

// --- sign-in -----------------------------------------------------------------

type pendingLogin struct {
	server      *http.Server
	state       string
	nonce       string
	verifier    string
	redirectURI string
	once        sync.Once
	cancelTimer *time.Timer
}

// StartLogin opens a loopback listener and returns the authorization URL for
// the app to open in the browser. A login already in progress is replaced.
func (m *Manager) StartLogin() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.login != nil {
		m.finishLoginLocked(m.login, "")
	}
	c, err := m.hostIDLocked()
	if err != nil {
		return "", err
	}

	listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", preferredPort))
	if err != nil {
		// Later sign-ins may use another port; scheme, host and path stay fixed.
		if listener, err = net.Listen("tcp", "127.0.0.1:0"); err != nil {
			return "", fmt.Errorf("打开本机登录回调端口失败：%w", err)
		}
	}
	port := listener.Addr().(*net.TCPAddr).Port

	verifier, err := randomToken(32)
	if err != nil {
		listener.Close()
		return "", err
	}
	state, err := randomToken(16)
	if err != nil {
		listener.Close()
		return "", err
	}
	nonce, err := randomToken(16)
	if err != nil {
		listener.Close()
		return "", err
	}
	p := &pendingLogin{
		state: state, nonce: nonce, verifier: verifier,
		redirectURI: fmt.Sprintf("http://127.0.0.1:%d%s", port, callbackPath),
	}
	mux := http.NewServeMux()
	mux.HandleFunc(callbackPath, func(w http.ResponseWriter, r *http.Request) { m.handleCallback(p, w, r) })
	p.server = &http.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = p.server.Serve(listener) }()
	p.cancelTimer = time.AfterFunc(loginTimeout, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if m.login == p {
			m.finishLoginLocked(p, "登录超时，请重新点一次登录")
		}
	})
	m.login = p
	m.loginError = ""

	q := url.Values{}
	clientID := dynamicClientID
	if c.ClientID != "" {
		clientID = c.ClientID
	} else {
		q.Set("agent_name_hint", appName)
	}
	q.Set("client_id", clientID)
	q.Set("ext_agent_host_id", c.HostID)
	if c.IDToken != "" {
		q.Set("id_token_hint", c.IDToken)
	}
	q.Set("response_type", "code")
	q.Set("redirect_uri", p.redirectURI)
	q.Set("scope", Scopes)
	q.Set("resource", Resource)
	q.Set("state", state)
	q.Set("nonce", nonce)
	q.Set("code_challenge_method", "S256")
	q.Set("code_challenge", Challenge(verifier))
	return strings.TrimSuffix(m.AuthBase, "/") + "/api/accounts/authorize?" + q.Encode(), nil
}

// finishLoginLocked stops the callback server without waiting on it (the
// caller may be its own handler).
func (m *Manager) finishLoginLocked(p *pendingLogin, loginError string) {
	p.once.Do(func() {
		if p.cancelTimer != nil {
			p.cancelTimer.Stop()
		}
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_ = p.server.Shutdown(ctx)
		}()
	})
	if m.login == p {
		m.login = nil
		m.loginError = loginError
	}
}

func (m *Manager) handleCallback(p *pendingLogin, w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if q.Get("state") != p.state {
		// Not our redirect (or a stale tab); keep waiting for the real one.
		writePage(w, http.StatusBadRequest, "这个登录链接已经失效，请回到 Tact 重新登录。")
		return
	}
	if e := q.Get("error"); e != "" {
		msg := "登录没有完成：" + e
		if e == "access_denied" {
			msg = "你取消了授权"
		}
		m.mu.Lock()
		m.finishLoginLocked(p, msg)
		m.mu.Unlock()
		writePage(w, http.StatusOK, msg+"。可以关掉这个页面了。")
		return
	}
	code, clientID := q.Get("code"), q.Get("client_id")
	if code == "" || clientID == "" {
		m.mu.Lock()
		m.finishLoginLocked(p, "登录回调缺少必要参数")
		m.mu.Unlock()
		writePage(w, http.StatusBadRequest, "登录回调缺少必要参数，请回到 Tact 重新登录。")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	err := m.exchange(ctx, p, code, clientID)
	m.mu.Lock()
	if err != nil {
		m.finishLoginLocked(p, err.Error())
	} else {
		m.finishLoginLocked(p, "")
	}
	m.mu.Unlock()
	if err != nil {
		writePage(w, http.StatusOK, "登录失败："+err.Error())
		return
	}
	writePage(w, http.StatusOK, "已登录。可以关掉这个页面，回到 Tact 了。")
}

type tokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int64  `json:"expires_in"`
	Scope        string `json:"scope"`
}

type oauthError struct {
	Status      int
	Code        string `json:"error"`
	Description string `json:"error_description"`
}

func (e *oauthError) Error() string {
	if e.Description != "" {
		return fmt.Sprintf("%s（%s）", e.Description, e.Code)
	}
	if e.Code != "" {
		return e.Code
	}
	return fmt.Sprintf("HTTP %d", e.Status)
}

func (m *Manager) postToken(ctx context.Context, form url.Values) (*tokenResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimSuffix(m.AuthBase, "/")+"/api/accounts/oauth/token", strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := m.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		e := &oauthError{Status: resp.StatusCode}
		_ = json.Unmarshal(data, e)
		return nil, e
	}
	var t tokenResponse
	if err := json.Unmarshal(data, &t); err != nil {
		return nil, fmt.Errorf("登录服务返回的内容无法解析：%w", err)
	}
	return &t, nil
}

func (m *Manager) exchange(ctx context.Context, p *pendingLogin, code, clientID string) error {
	t, err := m.postToken(ctx, url.Values{
		"grant_type":    {"authorization_code"},
		"client_id":     {clientID},
		"code":          {code},
		"code_verifier": {p.verifier},
		"redirect_uri":  {p.redirectURI},
		"resource":      {Resource},
	})
	if err != nil {
		var oe *oauthError
		if errors.As(err, &oe) && oe.Code == "invalid_grant" {
			return errors.New("授权码已失效，请重新登录")
		}
		return fmt.Errorf("换取令牌失败：%w", err)
	}
	if t.AccessToken == "" || t.RefreshToken == "" {
		return errors.New("登录服务没有返回令牌")
	}
	claims, err := m.checkIDToken(t.IDToken, clientID, p.nonce)
	if err != nil {
		return err
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	c, err := m.hostIDLocked()
	if err != nil {
		return err
	}
	next := *c
	next.ClientID = clientID
	next.Issuer, next.Subject, next.Email = claims.Issuer, claims.Subject, claims.Email
	next.IDToken = t.IDToken
	next.AccessToken, next.RefreshToken, next.TokenType = t.AccessToken, t.RefreshToken, t.TokenType
	next.ExpiresAt = m.Now().Add(time.Duration(t.ExpiresIn) * time.Second)
	next.Scopes = strings.Fields(t.Scope)
	return m.saveLocked(&next)
}

type idClaims struct {
	Issuer   string `json:"iss"`
	Subject  string `json:"sub"`
	Email    string `json:"email"`
	Nonce    string `json:"nonce"`
	Expires  int64  `json:"exp"`
	Audience any    `json:"aud"`
}

// checkIDToken validates the claims that tie the ID token to this sign-in.
// The token arrives straight from the token endpoint over TLS, which OpenID
// Connect Core §3.1.3.7 (6) accepts in place of checking the signature; it
// is only used for the account email and as id_token_hint.
func (m *Manager) checkIDToken(token, clientID, nonce string) (idClaims, error) {
	var c idClaims
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return c, errors.New("登录服务返回的身份令牌格式不对")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return c, errors.New("登录服务返回的身份令牌无法解码")
	}
	if err := json.Unmarshal(payload, &c); err != nil {
		return c, errors.New("登录服务返回的身份令牌无法解析")
	}
	if c.Issuer != strings.TrimSuffix(m.AuthBase, "/") {
		return c, fmt.Errorf("身份令牌的签发方不对：%s", c.Issuer)
	}
	if c.Nonce != nonce {
		return c, errors.New("身份令牌和这次登录对不上（nonce 不一致）")
	}
	if c.Expires != 0 && m.Now().After(time.Unix(c.Expires, 0).Add(5*time.Minute)) {
		return c, errors.New("身份令牌已过期")
	}
	if !audienceContains(c.Audience, clientID) {
		return c, errors.New("身份令牌不是发给这个应用的")
	}
	return c, nil
}

func audienceContains(aud any, clientID string) bool {
	switch v := aud.(type) {
	case string:
		return v == clientID
	case []any:
		for _, a := range v {
			if s, ok := a.(string); ok && s == clientID {
				return true
			}
		}
	}
	return false
}

// --- tokens for requests -----------------------------------------------------

// refreshTerminal are refresh errors after which the session cannot be
// renewed and the user must sign in again.
var refreshTerminal = map[string]bool{
	"invalid_grant": true, "invalid_refresh_token": true, "token_expired": true,
	"refresh_token_expired": true, "refresh_token_invalidated": true, "refresh_token_reused": true,
}

// AccessToken returns a token valid for at least refreshMargin, refreshing
// first if needed. Refreshes are serialized by the manager's lock.
func (m *Manager) AccessToken(ctx context.Context) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, err := m.loadLocked()
	if err != nil {
		return "", err
	}
	if !c.signedIn() {
		return "", ErrNotSignedIn
	}
	if !c.hasScope(PlanScope) {
		return "", ErrNoPlanScope
	}
	if m.Now().Add(refreshMargin).Before(c.ExpiresAt) {
		return c.AccessToken, nil
	}
	unlock, err := m.lockFile()
	if err != nil {
		return "", fmt.Errorf("锁定 ChatGPT 登录信息失败：%w", err)
	}
	defer unlock()
	// Another process may have refreshed while this one waited for the lock.
	m.loaded = false
	if c, err = m.loadLocked(); err != nil {
		return "", err
	}
	if !c.signedIn() {
		return "", ErrSignInAgain
	}
	if m.Now().Add(refreshMargin).Before(c.ExpiresAt) {
		return c.AccessToken, nil
	}
	t, err := m.postToken(ctx, url.Values{
		"grant_type":    {"refresh_token"},
		"client_id":     {c.ClientID},
		"refresh_token": {c.RefreshToken},
		"resource":      {Resource},
	})
	if err != nil {
		var oe *oauthError
		if errors.As(err, &oe) && refreshTerminal[oe.Code] {
			next := *c
			next.clearTokens()
			if saveErr := m.saveLocked(&next); saveErr != nil {
				return "", saveErr
			}
			return "", ErrSignInAgain
		}
		// Network trouble or a server error: keep the credentials.
		return "", fmt.Errorf("刷新 ChatGPT 登录失败：%w", err)
	}
	next := *c
	next.AccessToken = t.AccessToken
	if t.RefreshToken != "" {
		next.RefreshToken = t.RefreshToken
	}
	if t.IDToken != "" {
		next.IDToken = t.IDToken
	}
	if t.TokenType != "" {
		next.TokenType = t.TokenType
	}
	if t.Scope != "" {
		next.Scopes = strings.Fields(t.Scope)
	}
	next.ExpiresAt = m.Now().Add(time.Duration(t.ExpiresIn) * time.Second)
	if err := m.saveLocked(&next); err != nil {
		return "", err
	}
	return next.AccessToken, nil
}

// --- sign-out ----------------------------------------------------------------

// Logout revokes the refresh token and clears the local tokens either way.
// It reports whether the revocation was confirmed; if not, the user can
// disconnect the app in ChatGPT settings.
func (m *Manager) Logout(ctx context.Context) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, err := m.loadLocked()
	if err != nil {
		return false, err
	}
	if c == nil || c.RefreshToken == "" {
		return true, nil
	}
	revoked := m.revoke(ctx, c)
	next := *c
	next.clearTokens()
	return revoked, m.saveLocked(&next)
}

func (m *Manager) revoke(ctx context.Context, c *Credentials) bool {
	endpoint, err := m.revocationEndpoint(ctx)
	if err != nil {
		return false
	}
	form := url.Values{"token": {c.RefreshToken}, "token_type_hint": {"refresh_token"}, "client_id": {c.ClientID}}
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			select {
			case <-time.After(time.Duration(1<<attempt) * 250 * time.Millisecond):
			case <-ctx.Done():
				return false
			}
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
		if err != nil {
			return false
		}
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		resp, err := m.HTTP.Do(req)
		if err != nil {
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			return true
		}
		if resp.StatusCode < 500 {
			return false
		}
	}
	return false
}

func (m *Manager) revocationEndpoint(ctx context.Context) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		strings.TrimSuffix(m.AuthBase, "/")+"/.well-known/openid-configuration", nil)
	if err != nil {
		return "", err
	}
	resp, err := m.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var doc struct {
		RevocationEndpoint string `json:"revocation_endpoint"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&doc); err != nil {
		return "", err
	}
	if doc.RevocationEndpoint == "" {
		return "", errors.New("登录服务没有提供吊销地址")
	}
	return doc.RevocationEndpoint, nil
}

// --- models ------------------------------------------------------------------

// Models lists the models this account can use, as the provider names them.
func (m *Manager) Models(ctx context.Context) ([]Model, error) {
	token, err := m.AccessToken(ctx)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(m.APIBase, "/")+"/models", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := m.HTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("读取模型列表失败：%w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("读取模型列表失败：HTTP %d %s", resp.StatusCode, string(bytes.TrimSpace(data)))
	}
	var body struct {
		Models []struct {
			Slug             string           `json:"slug"`
			DisplayName      string           `json:"display_name"`
			Description      string           `json:"description"`
			Visibility       string           `json:"visibility"`
			ReasoningLevels  []ReasoningLevel `json:"supported_reasoning_levels"`
			DefaultReasoning string           `json:"default_reasoning_level"`
			ServiceTiers     []SpeedTier      `json:"service_tiers"`
		} `json:"models"`
	}
	if err := json.Unmarshal(data, &body); err != nil {
		return nil, fmt.Errorf("模型列表无法解析：%w", err)
	}
	var out []Model
	for _, mdl := range body.Models {
		if mdl.Visibility != "list" || mdl.Slug == "" {
			continue
		}
		name := mdl.DisplayName
		if name == "" {
			name = mdl.Slug
		}
		out = append(out, Model{Slug: mdl.Slug, DisplayName: name, Description: mdl.Description,
			ReasoningLevels: mdl.ReasoningLevels, DefaultReasoning: mdl.DefaultReasoning, SpeedTiers: mdl.ServiceTiers})
	}
	return out, nil
}

// --- helpers -------------------------------------------------------------------

// Challenge is the S256 PKCE code challenge for a verifier.
func Challenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func randomToken(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func uuidV4() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

func writePage(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	fmt.Fprintf(w, `<!doctype html><html lang="zh"><head><meta charset="utf-8"><title>Tact</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f6f4ef;color:#171717;
font:15px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}main{max-width:420px;padding:32px}
h1{font:400 28px "New York",Georgia,serif;margin:0 0 12px}p{color:#555;line-height:1.6;margin:0}</style></head>
<body><main><h1>Tact</h1><p>%s</p></main></body></html>`, htmlEscape(message))
}

func htmlEscape(s string) string {
	r := strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;", "'", "&#39;")
	return r.Replace(s)
}
