package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"github.com/pressly/goose/v3/lock"

	"github.com/kelvinguchu/liddr/apps/api/migrations"
)

const pingTimeout = 2 * time.Second

// OpenPool creates the shared connection pool. Connections are made lazily, so
// an unreachable database shows up in readiness instead of stopping startup.
func OpenPool(ctx context.Context, databaseURL string, maxConns int32) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	cfg.MaxConns = maxConns
	cfg.PingTimeout = pingTimeout

	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("create connection pool: %w", err)
	}
	return pool, nil
}

// Migrate applies pending migrations and returns how many ran. A Postgres
// session lock serializes instances that deploy at the same time.
func Migrate(ctx context.Context, databaseURL string) (applied int, err error) {
	cfg, err := pgx.ParseConfig(databaseURL)
	if err != nil {
		return 0, fmt.Errorf("parse database url: %w", err)
	}
	db := stdlib.OpenDB(*cfg)
	defer func() { err = errors.Join(err, closeDB(db)) }()

	locker, err := lock.NewPostgresSessionLocker()
	if err != nil {
		return 0, fmt.Errorf("create migration lock: %w", err)
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, migrations.FS, goose.WithSessionLocker(locker))
	if err != nil {
		return 0, fmt.Errorf("load migrations: %w", err)
	}
	results, err := provider.Up(ctx)
	if err != nil {
		return 0, fmt.Errorf("apply migrations: %w", err)
	}
	return len(results), nil
}

func closeDB(db *sql.DB) error {
	if err := db.Close(); err != nil {
		return fmt.Errorf("close migration connection: %w", err)
	}
	return nil
}
