package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// rejection carries a domain error out of a transaction that must still commit.
type rejection struct {
	err error
}

func (r rejection) Error() string { return r.err.Error() }

// Reject makes InTx commit the writes made so far and then return err. It exists
// for failed attempts and revocations, which a rollback would silently erase.
func Reject(err error) error {
	return rejection{err: err}
}

// InTx runs fn in a transaction. It commits when fn returns nil or a Reject,
// and rolls back on any other error. fn must not call outside services.
func InTx(ctx context.Context, pool *pgxpool.Pool, fn func(*Queries) error) error {
	var rejected error
	err := pgx.BeginTxFunc(ctx, pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		err := fn(New(tx))
		if r, ok := errors.AsType[rejection](err); ok {
			rejected = r.err
			return nil
		}
		return err
	})
	if err != nil {
		return err
	}
	return rejected
}
