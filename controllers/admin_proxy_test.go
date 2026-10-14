package controllers

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/PuerkitoBio/goquery"
	"github.com/gophish/gophish/auth"
	"github.com/gophish/gophish/config"
	"github.com/gophish/gophish/logger"
	"github.com/gophish/gophish/middleware"
	"github.com/gophish/gophish/models"
)

// Exercise the real admin handlers without sockets, SMTP, IMAP or campaign workers.
func TestAdminProxySecurity(t *testing.T) {
	t.Setenv(models.InitialAdminPassword, "proxy-test-only")
	t.Setenv(models.InitialAdminApiToken, strings.Repeat("a", 64))
	if err := models.Setup(&config.Config{DBName: "sqlite3", DBPath: ":memory:", MigrationsPath: "../db/db_sqlite3/migrations/"}); err != nil {
		t.Fatal(err)
	}
	u, err := models.GetUser(1)
	if err != nil {
		t.Fatal(err)
	}
	u.Hash, err = auth.GeneratePasswordHash("proxy-test-only")
	if err != nil {
		t.Fatal(err)
	}
	u.PasswordChangeRequired = false
	if err := models.PutUser(&u); err != nil {
		t.Fatal(err)
	}
	wd, _ := os.Getwd()
	if err := os.Chdir(".."); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	secure := middleware.Store.Options.Secure
	middleware.Store.Options.Secure = true
	defer func() { middleware.Store.Options.Secure = secure }()
	const host = "gophish-production-7157.up.railway.app"
	server := NewAdminServer(config.AdminServer{
		ListenURL: "127.0.0.1:3333", SecureCookies: true, DisableAccessLog: true,
		TrustedOrigins: []string{host},
	}, WithWorker(nil))
	var logs bytes.Buffer
	output := logger.Logger.Out
	logger.Logger.SetOutput(&logs)
	defer logger.Logger.SetOutput(output)
	request := func(method, path, body, referer string, cookies []*http.Cookie) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://"+host+path, strings.NewReader(body))
		r.Header.Set("X-Forwarded-Proto", "https")
		r.Header.Set("X-Forwarded-Host", host)
		r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		r.Header.Set("Referer", referer)
		for _, cookie := range cookies {
			r.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		server.server.Handler.ServeHTTP(w, r)
		return w
	}
	login := request("GET", "/login", "", "", nil)
	if login.Code != http.StatusOK {
		t.Fatalf("login GET: %d", login.Code)
	}
	doc, err := goquery.NewDocumentFromReader(login.Body)
	if err != nil {
		t.Fatal(err)
	}
	token, ok := doc.Find("input[name='csrf_token']").Attr("value")
	if !ok {
		t.Fatal("missing CSRF token")
	}
	cookies := login.Result().Cookies()
	if len(cookies) == 0 {
		t.Fatal("missing CSRF cookie")
	}
	for _, cookie := range cookies {
		if !cookie.Secure || !cookie.HttpOnly {
			t.Fatal("CSRF cookie must be Secure and HttpOnly")
		}
	}
	form := url.Values{"username": {"admin"}, "password": {"proxy-test-only"}, "csrf_token": {token}}.Encode()
	for _, referer := range []string{"", "https://untrusted.example/login"} {
		if got := request("POST", "/login", form, referer, cookies).Code; got != http.StatusForbidden {
			t.Fatalf("untrusted/missing referer returned %d", got)
		}
	}
	if got := request("POST", "/login", "username=admin", "https://"+host+"/login", cookies).Code; got != http.StatusForbidden {
		t.Fatalf("missing CSRF token returned %d", got)
	}
	loggedIn := request("POST", "/login", form, "https://"+host+"/login", cookies)
	if loggedIn.Code != http.StatusFound {
		t.Fatalf("valid login: %d %s", loggedIn.Code, loggedIn.Body.String())
	}
	var session *http.Cookie
	for _, cookie := range loggedIn.Result().Cookies() {
		if cookie.Name == "gophish" {
			session = cookie
			if !cookie.Secure || !cookie.HttpOnly {
				t.Fatal("session cookie must be Secure and HttpOnly")
			}
		}
	}
	if session == nil {
		t.Fatal("missing session cookie")
	}
	if got := request("GET", "/settings", "", "", []*http.Cookie{session}).Code; got != http.StatusOK {
		t.Fatalf("authenticated settings: %d", got)
	}
	if got := request("GET", "/api/campaigns/", "", "", nil).Code; got != http.StatusUnauthorized {
		t.Fatalf("API without key: %d", got)
	}
	// Synthetic in-memory key only. No campaign is created or launched.
	if got := request("GET", "/api/campaigns/?api_key="+url.QueryEscape(u.ApiKey), "", "", nil).Code; got != http.StatusOK {
		t.Fatalf("authenticated API: %d", got)
	}
	r := httptest.NewRequest("GET", "http://"+host+"/api/campaigns/", nil)
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("X-Forwarded-Host", host)
	r.Header.Set("Authorization", "Bearer "+u.ApiKey)
	w := httptest.NewRecorder()
	server.server.Handler.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("Bearer API: %d", w.Code)
	}
	for _, secret := range []string{u.ApiKey, "proxy-test-only", session.Value, token} {
		if strings.Contains(logs.String(), secret) {
			t.Fatal("administrative logs contain a synthetic secret")
		}
	}
}
