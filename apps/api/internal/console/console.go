// Package console serves the staff web console. It holds no data and no
// secrets: the browser signs in and calls the same /v1 API as the apps, where
// staff roles, an authenticator and step-up codes are enforced.
package console

import (
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"net/url"
	"strings"
)

//go:embed static
var files embed.FS

// Prefix is where the console is served.
const Prefix = "/ops/"

// Config configures the console.
type Config struct {
	// DocumentOrigin is the storage origin signed document links point at, so
	// reviewers can see photos inline. Nothing else may load from elsewhere.
	DocumentOrigin string
}

// Handler serves the console's files under [Prefix].
func Handler(cfg Config) (http.Handler, error) {
	root, err := fs.Sub(files, "static")
	if err != nil {
		return nil, fmt.Errorf("console files: %w", err)
	}
	images := "'self'"
	if cfg.DocumentOrigin != "" {
		origin, err := originOf(cfg.DocumentOrigin)
		if err != nil {
			return nil, err
		}
		images += " " + origin
	}
	policy := strings.Join([]string{
		"default-src 'none'",
		"script-src 'self'",
		"style-src 'self'",
		"font-src 'self'",
		"img-src " + images,
		"connect-src 'self'",
		"frame-ancestors 'none'",
		"base-uri 'none'",
		"form-action 'none'",
	}, "; ")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, Prefix)
		if name == "" {
			name = "index.html"
		}
		if !fs.ValidPath(name) {
			http.NotFound(w, r)
			return
		}
		info, err := fs.Stat(root, name)
		if err != nil || info.IsDir() {
			http.NotFound(w, r)
			return
		}
		h := w.Header()
		h.Set("Content-Security-Policy", policy)
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()")
		http.ServeFileFS(w, r, root, name) //nolint:gosec // name passed fs.ValidPath and root is the embedded FS, which holds only the console's own files.
	}), nil
}

// originOf reduces a URL to scheme://host[:port], refusing anything that is not one.
func originOf(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return "", errors.New("console document origin is not an http(s) URL")
	}
	return u.Scheme + "://" + u.Host, nil
}
