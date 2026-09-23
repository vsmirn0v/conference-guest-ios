package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

//go:embed site/*
var site embed.FS

type configuration struct {
	key       string
	secret    string
	serverURL string
	listen    string
}

type server struct {
	config configuration
	mu     sync.Mutex
	joins  []time.Time
}

type jamDetails struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	Community   string `json:"community"`
	Description string `json:"description"`
}

var testJam = jamDetails{
	ID:          "test",
	Title:       "Open rehearsal",
	Community:   "Rock’n’Roll · Yerevan",
	Description: "A small jam room for trying live audio and video. Share the link with another musician to play together.",
}

func main() {
	config := configuration{
		key:       os.Getenv("ROOM_API_KEY"),
		secret:    os.Getenv("ROOM_API_SECRET"),
		serverURL: os.Getenv("PUBLIC_ROOM_URL"),
		listen:    os.Getenv("LISTEN_ADDR"),
	}
	if len(config.key) < 12 || len(config.secret) < 32 || !strings.HasPrefix(config.serverURL, "wss://") {
		log.Fatal("Missing or invalid room credentials or public room URL")
	}
	if config.listen == "" {
		config.listen = "127.0.0.1:7878"
	}
	s := &server{config: config}
	httpServer := &http.Server{
		Addr:              config.listen,
		Handler:           s.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
	}
	log.Printf("Rock service listening on %s", config.listen)
	log.Fatal(httpServer.ListenAndServe())
}

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("GET /api/jams/test", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, testJam)
	})
	mux.HandleFunc("POST /api/jams/test/join", s.join)
	mux.HandleFunc("GET /jams/test", serveAsset("site/jam.html", "text/html; charset=utf-8"))
	mux.HandleFunc("GET /privacy", serveAsset("site/privacy.html", "text/html; charset=utf-8"))
	mux.HandleFunc("GET /support", serveAsset("site/support.html", "text/html; charset=utf-8"))
	mux.HandleFunc("GET /community", serveAsset("site/community.html", "text/html; charset=utf-8"))
	mux.HandleFunc("GET /notices", serveAsset("site/notices.txt", "text/plain; charset=utf-8"))
	mux.HandleFunc("GET /style.css", serveAsset("site/style.css", "text/css; charset=utf-8"))
	mux.HandleFunc("GET /app.js", serveScript)
	mux.HandleFunc("GET /favicon.svg", serveAsset("site/favicon.svg", "image/svg+xml"))
	mux.HandleFunc("GET /favicon.ico", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	mux.HandleFunc("GET /{$}", serveAsset("site/index.html", "text/html; charset=utf-8"))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self' https://rock.glowsoft.ru wss://rock.glowsoft.ru; media-src 'self' blob:; base-uri 'none'; frame-ancestors 'none'")
		mux.ServeHTTP(w, r)
	})
}

func serveAsset(path, contentType string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		data, err := site.ReadFile(path)
		if err != nil {
			http.Error(w, "Unavailable", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", contentType)
		if path == "site/style.css" {
			w.Header().Set("Cache-Control", "public, max-age=3600")
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		_, _ = w.Write(data)
	}
}

func serveScript(w http.ResponseWriter, r *http.Request) {
	path := "site/app.js"
	if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") {
		path = "site/app.js.gz"
		w.Header().Set("Content-Encoding", "gzip")
	}
	w.Header().Set("Vary", "Accept-Encoding")
	w.Header().Set("Cache-Control", "public, max-age=3600")
	serveAsset(path, "text/javascript; charset=utf-8")(w, r)
}

func (s *server) join(w http.ResponseWriter, r *http.Request) {
	if !s.takeJoinSlot(time.Now()) {
		http.Error(w, "The jam is busy. Try again shortly.", http.StatusTooManyRequests)
		return
	}
	if r.Header.Get("Content-Type") != "application/json" {
		http.Error(w, "Send JSON", http.StatusUnsupportedMediaType)
		return
	}
	var request struct {
		Name string `json:"name"`
	}
	decoder := json.NewDecoder(io.LimitReader(r.Body, 1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		http.Error(w, "Invalid name", http.StatusBadRequest)
		return
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}
	request.Name = strings.TrimSpace(request.Name)
	if request.Name == "" || utf8.RuneCountInString(request.Name) > 60 ||
		strings.IndexFunc(request.Name, unicode.IsControl) >= 0 {
		http.Error(w, "Enter a name of up to 60 characters", http.StatusBadRequest)
		return
	}
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		http.Error(w, "Unavailable", http.StatusServiceUnavailable)
		return
	}
	identity := hex.EncodeToString(random[:])
	token, err := s.makeToken(identity, request.Name, time.Now())
	if err != nil {
		http.Error(w, "Unavailable", http.StatusServiceUnavailable)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		ServerURL string     `json:"server_url"`
		Token     string     `json:"participant_token"`
		Jam       jamDetails `json:"jam"`
	}{s.config.serverURL, token, testJam})
}

// A small global rate limit protects the unauthenticated demo token endpoint.
// The room itself has a separate maximum participant limit.
func (s *server) takeJoinSlot(now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	kept := s.joins[:0]
	for _, joined := range s.joins {
		if now.Sub(joined) < time.Minute {
			kept = append(kept, joined)
		}
	}
	s.joins = kept
	if len(s.joins) >= 30 {
		return false
	}
	s.joins = append(s.joins, now)
	return true
}

func (s *server) makeToken(identity, name string, now time.Time) (string, error) {
	header := map[string]string{"alg": "HS256", "typ": "JWT"}
	claims := map[string]any{
		"iss":  s.config.key,
		"sub":  identity,
		"name": name,
		"nbf":  now.Unix() - 5,
		"exp":  now.Add(15 * time.Minute).Unix(),
		"video": map[string]any{
			"room":              testJam.ID,
			"roomJoin":          true,
			"canPublish":        true,
			"canSubscribe":      true,
			"canPublishData":    true,
			"canPublishSources": []string{"microphone", "camera", "screen_share"},
		},
	}
	h, err := json.Marshal(header)
	if err != nil {
		return "", err
	}
	c, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	input := fmt.Sprintf("%s.%s", base64.RawURLEncoding.EncodeToString(h), base64.RawURLEncoding.EncodeToString(c))
	mac := hmac.New(sha256.New, []byte(s.config.secret))
	_, _ = mac.Write([]byte(input))
	return input + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
