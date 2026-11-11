package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
)

// The staff console's session. Its credentials live in cookies the console's
// page cannot read, so the browser holds them and no script ever does; the
// contract's note above /v1/auth/web/session describes the rules. These
// routes exist only when Deps.ConsoleOrigin is set.

const (
	headerConsole      = "X-Liddr-Console"
	consoleRefreshPath = "/v1/auth/web/session"
	codeConsoleOrigin  = "CONSOLE_ORIGIN_REQUIRED"
	maxConsoleCookie   = 512
)

// consoleCookies names the console's cookies for its origin. Over https each
// carries the __Host- or __Secure- prefix, so no other host can set or shadow
// it; plain http is for local development and gets neither prefix nor Secure.
type consoleCookies struct {
	origin  string
	secure  bool
	session string
	refresh string
	stepUp  string
}

func newConsoleCookies(origin string) *consoleCookies {
	if origin == "" {
		return nil
	}
	c := &consoleCookies{origin: origin, session: "liddr_staff", refresh: "liddr_staff_refresh", stepUp: "liddr_step_up"}
	if strings.HasPrefix(origin, "https://") {
		c.secure = true
		c.session = "__Host-" + c.session
		c.refresh = "__Secure-" + c.refresh
		c.stepUp = "__Host-" + c.stepUp
	}
	return c
}

func (c *consoleCookies) set(w http.ResponseWriter, name, path, value string, lifetime time.Duration) {
	// Secure is off only for a plain-http origin, which is local development.
	http.SetCookie(w, &http.Cookie{ //nolint:gosec // HttpOnly and SameSite=Strict always; Secure follows the origin's scheme.
		Name: name, Value: value, Path: path, MaxAge: int(lifetime.Seconds()),
		HttpOnly: true, Secure: c.secure, SameSite: http.SameSiteStrictMode,
	})
}

func (c *consoleCookies) clear(w http.ResponseWriter, name, path string) {
	http.SetCookie(w, &http.Cookie{Name: name, Path: path, MaxAge: -1, HttpOnly: true, Secure: c.secure, SameSite: http.SameSiteStrictMode}) //nolint:gosec // As in set: Secure follows the origin's scheme.
}

func (c *consoleCookies) setSession(w http.ResponseWriter, t auth.Tokens) {
	c.set(w, c.session, "/", t.AccessToken, t.AccessTTL)
	c.set(w, c.refresh, consoleRefreshPath, t.RefreshToken, t.RefreshTTL)
}

func (c *consoleCookies) clearAll(w http.ResponseWriter) {
	c.clear(w, c.session, "/")
	c.clear(w, c.refresh, consoleRefreshPath)
	c.clear(w, c.stepUp, "/")
}

// read returns the one value of a cookie. A request carrying the name twice is
// treated as carrying none, since only one of them can be the server's.
func (c *consoleCookies) read(r *http.Request, name string) (string, bool) {
	found := r.CookiesNamed(name)
	if len(found) != 1 || found[0].Value == "" || len(found[0].Value) > maxConsoleCookie {
		return "", false
	}
	return found[0].Value, true
}

// fromConsole requires the console's header and browser evidence that the
// request comes from the console's own origin. A page on another site can
// set neither Sec-Fetch-Site nor Origin, and cannot send the header without
// a CORS permission this API never gives.
func (c *consoleCookies) fromConsole(r *http.Request) bool {
	if r.Header.Get(headerConsole) != "1" {
		return false
	}
	site, origin := r.Header.Get("Sec-Fetch-Site"), r.Header.Get("Origin")
	if site == "" && origin == "" {
		return false
	}
	if site != "" && site != "same-origin" {
		return false
	}
	return origin == "" || origin == c.origin
}

func writeConsoleOriginRequired(w http.ResponseWriter, r *http.Request) {
	writeError(w, r, http.StatusForbidden, codeConsoleOrigin, "Use the staff console for this.")
}

func (a *API) registerConsole(mux *http.ServeMux) {
	if a.console == nil {
		return
	}
	mux.HandleFunc("POST /v1/auth/web/session", a.startConsoleSession)
	mux.HandleFunc("DELETE /v1/auth/web/session", a.endConsoleSession)
	mux.HandleFunc("POST /v1/auth/web/session/refresh", a.refreshConsoleSession)
	mux.Handle("POST /v1/auth/web/step-up", a.guard([]string{string(auth.RoleOps), string(auth.RoleAdmin), scopeMFAExempt}, http.HandlerFunc(a.verifyConsoleStepUp)))
}

type consoleSessionBody struct {
	UserID    string `json:"user_id"`
	Roles     []Role `json:"roles"`
	ExpiresIn int32  `json:"expires_in"`
}

func (a *API) startConsoleSession(w http.ResponseWriter, r *http.Request) {
	if !a.console.fromConsole(r) {
		writeConsoleOriginRequired(w, r)
		return
	}
	body, ok := decodeBody[OtpVerification](w, r)
	if !ok {
		return
	}
	tokens, err := a.deps.Auth.VerifyOTP(r.Context(), body.ChallengeId, body.Code, requestMeta(r.Context()))
	if err != nil {
		if status, code, message, ok := otpProblem(err); ok {
			writeError(w, r, status, code, message)
			return
		}
		a.responseError(w, r, err)
		return
	}
	a.admitStaff(w, r, tokens)
}

func (a *API) refreshConsoleSession(w http.ResponseWriter, r *http.Request) {
	if !a.console.fromConsole(r) {
		writeConsoleOriginRequired(w, r)
		return
	}
	token, ok := a.console.read(r, a.console.refresh)
	if !ok {
		a.console.clearAll(w)
		writeUnauthorized(w, r)
		return
	}
	tokens, err := a.deps.Auth.Refresh(r.Context(), token, requestMeta(r.Context()))
	switch {
	case err == nil:
	case errors.Is(err, auth.ErrInvalidToken):
		a.console.clearAll(w)
		writeUnauthorized(w, r)
		return
	case isAccountBlocked(err):
		a.console.clearAll(w)
		code, message := accountBlocked(err)
		writeError(w, r, http.StatusForbidden, code, message)
		return
	default:
		a.responseError(w, r, err)
		return
	}
	// A step-up proof names the session it was given to, which is now spent.
	a.console.clear(w, a.console.stepUp, "/")
	a.admitStaff(w, r, tokens)
}

// admitStaff sets the session cookies for a staff account. Any other account
// has its new session ended at once: the console is for staff only.
func (a *API) admitStaff(w http.ResponseWriter, r *http.Request, tokens auth.Tokens) {
	if !slices.ContainsFunc(tokens.Roles, func(role auth.Role) bool { return role == auth.RoleOps || role == auth.RoleAdmin }) {
		if err := a.deps.Auth.Logout(r.Context(), tokens.RefreshToken, requestMeta(r.Context())); err != nil {
			a.responseError(w, r, err)
			return
		}
		a.console.clearAll(w)
		writeError(w, r, http.StatusForbidden, "NOT_STAFF", "This number does not have staff access.")
		return
	}
	a.console.setSession(w, tokens)
	writeJSON(w, http.StatusOK, consoleSessionBody{
		UserID:    tokens.UserID.String(),
		Roles:     toRoles(tokens.Roles),
		ExpiresIn: int32(tokens.AccessTTL.Seconds()),
	})
}

func (a *API) endConsoleSession(w http.ResponseWriter, r *http.Request) {
	if !a.console.fromConsole(r) {
		writeConsoleOriginRequired(w, r)
		return
	}
	if token, ok := a.console.read(r, a.console.refresh); ok {
		if err := a.deps.Auth.Logout(r.Context(), token, requestMeta(r.Context())); err != nil {
			a.responseError(w, r, err)
			return
		}
	}
	a.console.clearAll(w)
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) verifyConsoleStepUp(w http.ResponseWriter, r *http.Request) {
	if !a.console.fromConsole(r) {
		writeConsoleOriginRequired(w, r)
		return
	}
	p, found := principal(r.Context())
	if !found {
		a.responseError(w, r, errNoPrincipal)
		return
	}
	body, ok := decodeBody[TotpCode](w, r)
	if !ok {
		return
	}
	grant, err := a.deps.Auth.VerifyStepUp(r.Context(), p, body.Code, requestMeta(r.Context()))
	if err != nil {
		a.responseError(w, r, err)
		return
	}
	a.console.set(w, a.console.stepUp, "/", grant.Token, grant.ExpiresIn)
	writeJSON(w, http.StatusOK, struct {
		ExpiresIn int32 `json:"expires_in"`
	}{int32(grant.ExpiresIn.Seconds())})
}

// decodeBody reads one JSON object with no unknown fields. On failure it has
// already answered the request.
func decodeBody[T any](w http.ResponseWriter, r *http.Request) (T, bool) {
	var body T
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&body); err != nil {
		writeError(w, r, http.StatusBadRequest, "INVALID_REQUEST", "The request could not be read.")
		return body, false
	}
	return body, true
}

func writeJSON[T any](w http.ResponseWriter, status int, body T) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	// A failed write means the client has gone, and the status is already sent.
	_ = json.NewEncoder(w).Encode(body)
}
