// Command api runs the Liddr API server and its database migrations.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/auth"
	"github.com/kelvinguchu/liddr/apps/api/internal/config"
	"github.com/kelvinguchu/liddr/apps/api/internal/httpapi"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/sms"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const usage = "usage: api <serve|migrate>"

func main() {
	if err := run(context.Background(), os.Args, os.Getenv, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) error {
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if len(args) != 2 || (args[1] != "serve" && args[1] != "migrate") {
		// The returned error reports the failure even if stderr is closed.
		_, _ = fmt.Fprintln(stderr, usage)
		return errors.New("invalid command")
	}
	logger := slog.New(slog.NewJSONHandler(stdout, nil))

	if args[1] == "migrate" {
		databaseURL, err := config.LoadDatabaseURL(getenv)
		if err != nil {
			return fmt.Errorf("load config: %w", err)
		}
		applied, err := store.Migrate(ctx, databaseURL.Reveal())
		if err != nil {
			return err
		}
		logger.LogAttrs(ctx, slog.LevelInfo, "migrations applied", slog.Int("count", applied))
		return nil
	}

	cfg, err := config.Load(getenv)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	return serve(ctx, cfg, logger)
}

func serve(ctx context.Context, cfg config.Config, logger *slog.Logger) error {
	pool, err := store.OpenPool(ctx, cfg.DatabaseURL.Reveal(), cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close()

	api := httpapi.New(httpapi.Deps{
		Logger:     logger,
		Database:   pool,
		Categories: rides.NewCatalog(store.New(pool)),
		Auth: auth.NewService(auth.Config{
			Pool: pool,
			SMS: sms.NewClient(sms.Config{
				URL:      cfg.SMS.URL,
				APIKey:   cfg.SMS.APIKey.Reveal(),
				UserID:   cfg.SMS.UserID,
				Password: cfg.SMS.Password.Reveal(),
				SenderID: cfg.SMS.SenderID,
			}),
			HMACKey: []byte(cfg.AuthHMACKey.Reveal()),
			Now:     time.Now,
		}),
		TrustedProxyHops: cfg.TrustedProxyHops,
	})
	server := &http.Server{
		Handler:           api,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      httpapi.RequestTimeout + 10*time.Second,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelWarn),
	}

	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(ctx, "tcp", cfg.Addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	logger.LogAttrs(ctx, slog.LevelInfo, "http server listening", slog.String("addr", listener.Addr().String()))

	// Serve returns once Shutdown or Close is called below, and this function
	// waits for that result on every path after this point.
	served := make(chan error, 1)
	go func() { served <- server.Serve(listener) }()

	select {
	case err := <-served:
		return fmt.Errorf("serve http: %w", err)
	case <-ctx.Done():
	}
	return shutdown(ctx, cfg, logger, api, server, served)
}

func shutdown(ctx context.Context, cfg config.Config, logger *slog.Logger, api *httpapi.API, server *http.Server, served <-chan error) error {
	logger.LogAttrs(ctx, slog.LevelInfo, "http server draining")
	api.BeginDrain()
	<-time.After(cfg.DrainDelay)

	stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cfg.ShutdownTimeout)
	defer cancel()
	stopErr := server.Shutdown(stopCtx)
	if stopErr != nil {
		stopErr = errors.Join(fmt.Errorf("shutdown http: %w", stopErr), server.Close())
	}
	if err := <-served; !errors.Is(err, http.ErrServerClosed) {
		stopErr = errors.Join(stopErr, fmt.Errorf("serve http: %w", err))
	}
	logger.LogAttrs(ctx, slog.LevelInfo, "http server stopped")
	return stopErr
}
