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
	"sync"
	"syscall"
	"time"

	"github.com/kelvinguchu/liddr/apps/api/internal/config"
	"github.com/kelvinguchu/liddr/apps/api/internal/dispatch"
	"github.com/kelvinguchu/liddr/apps/api/internal/httpapi"
	"github.com/kelvinguchu/liddr/apps/api/internal/maps"
	"github.com/kelvinguchu/liddr/apps/api/internal/realtime"
	"github.com/kelvinguchu/liddr/apps/api/internal/rides"
	"github.com/kelvinguchu/liddr/apps/api/internal/store"
)

const usage = "usage: api <serve|migrate|register-c2b-urls|grant-role PHONE ROLE>"

func main() {
	if err := run(context.Background(), os.Args, os.Getenv, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) error {
	ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if !validCommand(args) {
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
	if args[1] == "register-c2b-urls" {
		return registerC2BURLs(ctx, cfg, logger)
	}
	if len(args) == 4 {
		return grantRole(ctx, cfg, args[2], args[3], logger) //nolint:gosec // validCommand and the length check above guarantee four arguments.
	}
	return serve(ctx, cfg, logger)
}

func validCommand(args []string) bool {
	switch {
	case len(args) == 4:
		return args[1] == "grant-role"
	case len(args) == 2:
		return args[1] == "serve" || args[1] == "migrate" || args[1] == "register-c2b-urls"
	default:
		return false
	}
}

func serve(ctx context.Context, cfg config.Config, logger *slog.Logger) error {
	pool, err := store.OpenPool(ctx, cfg.DatabaseURL.Reveal(), cfg.DBMaxConns)
	if err != nil {
		return err
	}
	defer pool.Close()

	authService, err := newAuth(cfg, pool)
	if err != nil {
		return err
	}
	documents, err := newVerification(cfg, pool, logger)
	if err != nil {
		return err
	}
	dispatcher := dispatch.NewService(dispatch.Config{Pool: pool, Now: time.Now})
	billing := newSubscriptions(cfg, pool, logger)
	hub := realtime.NewHub(logger)
	api := httpapi.New(httpapi.Deps{
		Logger:     logger,
		Database:   pool,
		Categories: rides.NewCatalog(store.New(pool)),
		Auth:       authService,
		Rides: rides.NewService(rides.Config{
			Pool:   pool,
			Routes: maps.NewClient(cfg.GoogleRoutesURL, cfg.GoogleMapsKey.Reveal()),
			Now:    time.Now,
		}),
		Dispatch:         dispatcher,
		Subscriptions:    billing,
		Verification:     documents,
		Realtime:         hub,
		RealtimeBase:     ctx,
		RealtimeOrigins:  cfg.RealtimeOrigins,
		RealtimeJitter:   cfg.DrainDelay,
		MpesaAllowedIPs:  cfg.Mpesa.AllowedIPs,
		OpsAllowedNets:   cfg.OpsAllowedNets,
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

	// Background work stops when stopWorkers runs, and waiting on workers.Wait
	// before the deferred pool.Close guarantees nothing uses the pool after it.
	workerCtx, stopWorkers := context.WithCancel(context.WithoutCancel(ctx))
	var workers sync.WaitGroup
	workers.Go(func() { dispatcher.Run(workerCtx, logger) })
	workers.Go(func() { billing.Run(workerCtx, logger) })
	workers.Go(func() { hub.Listen(workerCtx, pool) })
	workers.Go(func() { documents.Run(workerCtx) })
	defer workers.Wait()
	defer stopWorkers()

	// Serve returns once Shutdown or Close is called below, and this function
	// waits for that result on every path after this point.
	served := make(chan error, 1)
	go func() { served <- server.Serve(listener) }()

	select {
	case err := <-served:
		return fmt.Errorf("serve http: %w", err)
	case <-ctx.Done():
	}
	err = shutdown(ctx, cfg, logger, api, server, served)
	hub.Wait()
	return err
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
