package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// InTx runs fn in a transaction, committing when fn returns nil and rolling
// back otherwise. fn must not make network calls to outside services.
func InTx(ctx context.Context, pool *pgxpool.Pool, fn func(*Queries) error) error {
	err := pgx.BeginTxFunc(ctx, pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		return fn(New(tx))
	})
	if err != nil {
		return fmt.Errorf("transaction: %w", err)
	}
	return nil
}
