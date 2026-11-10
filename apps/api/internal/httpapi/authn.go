package httpapi

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"strings"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/realtime"
)

type principalKey struct{}

func principal(ctx context.Context) (auth.Principal, bool) {
	p, ok := ctx.Value(principalKey{}).(auth.Principal)
	return p, ok
}

// authenticate enforces the contract's security rules. The generated router
// sets BearerAuthScopes for every operation that does not opt out, so a route
// is protected unless the contract explicitly marks it `security: []`.
func (a *API) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		allowedRoles, protected := r.Context().Value(BearerAuthScopes).([]string)
		if !protected {
			next.ServeHTTP(w, r)
			return
		}

		token := bearerToken(r)
		viaCookie := false
		if token == "" && a.console != nil {
			token, viaCookie = a.console.read(r, a.console.session)
		}
		if token == "" {
			writeUnauthorized(w, r)
			return
		}
		// A cookie is sent by the browser whoever asked, so a write made with
		// one must show it came from the console's own page.
		if viaCookie && r.Method != http.MethodGet && r.Method != http.MethodHead && !a.console.fromConsole(r) {
			writeConsoleOriginRequired(w, r)
			return
		}
		p, err := a.deps.Auth.Authenticate(r.Context(), token)
		switch {
		case err == nil:
		case errors.Is(err, auth.ErrInvalidToken):
			writeUnauthorized(w, r)
			return
		case isAccountBlocked(err):
			code, message := accountBlocked(err)
			writeError(w, r, http.StatusForbidden, code, message)
			return
		default:
			a.responseError(w, r, err)
			return
		}

		roles, requirement := splitScopes(allowedRoles)
		if !hasAllowedRole(p.Roles, roles) {
			a.deps.Logger.LogAttrs(r.Context(), slog.LevelWarn, "role check denied request",
				slog.String("request_id", requestID(r.Context())),
				slog.String("route", r.Pattern),
				slog.String("user_id", p.UserID.String()),
			)
			writeError(w, r, http.StatusForbidden, "FORBIDDEN", "You do not have permission to do this.")
			return
		}
		stepUp := r.Header.Get(headerStepUp)
		if stepUp == "" && viaCookie {
			stepUp, _ = a.console.read(r, a.console.stepUp)
		}
		if err := a.checkStaffAccess(r, p, roles, requirement, stepUp); err != nil {
			a.responseError(w, r, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey{}, p)))
	})
}

// protect applies the same rules as generated routes to a hand-registered one
// open to any signed-in account.
func (a *API) protect(next http.Handler) http.Handler {
	return a.guard([]string{}, next)
}

// guard applies the generated routes' rules with the given contract scopes.
func (a *API) guard(scopes []string, next http.Handler) http.Handler {
	guarded := a.authenticate(next)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		guarded.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), BearerAuthScopes, scopes)))
	})
}

func (a *API) openRealtime(w http.ResponseWriter, r *http.Request) {
	p, ok := principal(r.Context())
	if !ok {
		a.responseError(w, r, errNoPrincipal)
		return
	}
	token := bearerToken(r)
	if token == "" && a.console != nil {
		token, _ = a.console.read(r, a.console.session)
	}
	a.deps.Realtime.Serve(a.deps.RealtimeBase, w, r, realtime.Options{
		UserID:         p.UserID,
		OriginPatterns: a.deps.RealtimeOrigins,
		ShutdownJitter: a.deps.RealtimeJitter,
		StillValid: func(ctx context.Context) bool {
			_, err := a.deps.Auth.Authenticate(ctx, token)
			return err == nil
		},
	})
}

// hasAllowedRole reports whether held satisfies allowed. An empty allowed list
// means any signed-in account.
func hasAllowedRole(held []auth.Role, allowed []string) bool {
	if len(allowed) == 0 {
		return true
	}
	return slices.ContainsFunc(held, func(role auth.Role) bool {
		return slices.Contains(allowed, string(role))
	})
}

func bearerToken(r *http.Request) string {
	scheme, token, found := strings.Cut(r.Header.Get("Authorization"), " ")
	if !found || !strings.EqualFold(scheme, "Bearer") {
		return ""
	}
	return strings.TrimSpace(token)
}

func writeUnauthorized(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	writeError(w, r, http.StatusUnauthorized, "UNAUTHORIZED", "Please sign in again.")
}

func accountBlocked(err error) (code, message string) {
	switch {
	case errors.Is(err, auth.ErrAccountBanned):
		return "ACCOUNT_BANNED", "This account has been banned."
	case errors.Is(err, auth.ErrAccountDeactivated):
		return "ACCOUNT_DEACTIVATED", "This account has been deactivated."
	default:
		return "ACCOUNT_SUSPENDED", "This account is suspended."
	}
}

// clientAddress returns the caller's address. hops is how many trusted proxies
// append to X-Forwarded-For. Entries further left are supplied by the client
// and can be forged, so only the entry the outermost trusted proxy added counts.
func clientAddress(r *http.Request, hops int) netip.Addr {
	remote := remoteAddress(r)
	if hops <= 0 {
		return remote
	}
	var entries []string
	for _, value := range r.Header.Values("X-Forwarded-For") {
		entries = append(entries, strings.Split(value, ",")...)
	}
	if len(entries) < hops {
		return remote
	}
	addr, err := netip.ParseAddr(strings.TrimSpace(entries[len(entries)-hops]))
	if err != nil {
		return remote
	}
	return addr.Unmap()
}

func remoteAddress(r *http.Request) netip.Addr {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return netip.IPv4Unspecified()
	}
	return addr.Unmap()
}
