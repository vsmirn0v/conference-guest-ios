package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestGuestJoinIssuesOnlyRoomScopedGrant(t *testing.T) {
	s := &server{config: configuration{key: "test-api-key-long", secret: strings.Repeat("s", 48), serverURL: "wss://rock.glowsoft.ru"}}
	r := httptest.NewRequest(http.MethodPost, "/api/jams/test/join", strings.NewReader(`{"name":"Maya"}`))
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("join status = %d: %s", w.Code, w.Body.String())
	}
	var response struct {
		ServerURL string `json:"server_url"`
		Token     string `json:"participant_token"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.ServerURL != "wss://rock.glowsoft.ru" {
		t.Fatalf("server = %q", response.ServerURL)
	}
	parts := strings.Split(response.Token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected JWT, got %d parts", len(parts))
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims struct {
		Iss   string         `json:"iss"`
		Sub   string         `json:"sub"`
		Name  string         `json:"name"`
		Exp   int64          `json:"exp"`
		Video map[string]any `json:"video"`
	}
	if err := json.Unmarshal(data, &claims); err != nil {
		t.Fatal(err)
	}
	if claims.Iss != s.config.key || len(claims.Sub) != 32 || claims.Name != "Maya" || claims.Video["room"] != "test" || claims.Video["roomJoin"] != true || claims.Video["roomAdmin"] != nil || claims.Video["roomCreate"] != nil || claims.Video["roomRecord"] != nil {
		t.Fatalf("unexpected join claims: %+v", claims)
	}
	if claims.Exp < time.Now().Add(14*time.Minute).Unix() || claims.Exp > time.Now().Add(16*time.Minute).Unix() {
		t.Fatalf("unexpected expiry: %d", claims.Exp)
	}
}

func TestUnknownJamAndClientSuppliedPrivilegeAreRejected(t *testing.T) {
	s := &server{config: configuration{key: "test-api-key-long", secret: strings.Repeat("s", 48), serverURL: "wss://rock.glowsoft.ru"}}
	for _, test := range []struct {
		path, body string
		want       int
	}{
		{"/api/jams/other/join", `{"name":"Maya"}`, http.StatusNotFound},
		{"/api/jams/test/join", `{"name":"Maya","roomAdmin":true}`, http.StatusBadRequest},
		{"/api/jams/test/join", `{"name":"\n"}`, http.StatusBadRequest},
	} {
		r := httptest.NewRequest(http.MethodPost, test.path, strings.NewReader(test.body))
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		s.routes().ServeHTTP(w, r)
		if w.Code != test.want {
			t.Fatalf("%s got %d, want %d", test.path, w.Code, test.want)
		}
	}
}

func TestStaticScriptCanBeCachedWithoutCachingGuestCredentials(t *testing.T) {
	s := &server{config: configuration{key: "test-api-key-long", secret: strings.Repeat("s", 48), serverURL: "wss://rock.glowsoft.ru"}}
	script := httptest.NewRequest(http.MethodGet, "/app.js?v=3", nil)
	script.Header.Set("Accept-Encoding", "gzip")
	staticResponse := httptest.NewRecorder()
	s.routes().ServeHTTP(staticResponse, script)
	if staticResponse.Code != http.StatusOK || staticResponse.Header().Get("Content-Encoding") != "gzip" ||
		!strings.HasPrefix(staticResponse.Header().Get("Cache-Control"), "public") {
		t.Fatalf("script headers = %#v", staticResponse.Header())
	}

	join := httptest.NewRequest(http.MethodPost, "/api/jams/test/join", strings.NewReader(`{"name":"Maya"}`))
	join.Header.Set("Content-Type", "application/json")
	tokenResponse := httptest.NewRecorder()
	s.routes().ServeHTTP(tokenResponse, join)
	if tokenResponse.Code != http.StatusOK || tokenResponse.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("credential headers = %#v", tokenResponse.Header())
	}
}
