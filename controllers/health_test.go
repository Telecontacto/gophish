package controllers

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gophish/gophish/config"
)

func TestPublicHealth(t *testing.T) {
	server := NewPhishingServer(config.PhishServer{})
	response := httptest.NewRecorder()
	server.server.Handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/health", nil))
	if response.Code != http.StatusOK || response.Body.String() != `{"status":"ok"}` {
		t.Fatalf("unexpected health response: %d %s", response.Code, response.Body.String())
	}
	if response.Header().Get("Content-Type") != "application/json" {
		t.Fatal("health response must be JSON")
	}
}

func TestPublicDoesNotExposeAdmin(t *testing.T) {
	server := NewPhishingServer(config.PhishServer{})
	for _, path := range []string{"/login", "/api/users/", "/"} {
		response := httptest.NewRecorder()
		server.server.Handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, path, nil))
		if response.Code != http.StatusNotFound {
			t.Fatalf("public route %s returned %d, expected 404", path, response.Code)
		}
	}
}
