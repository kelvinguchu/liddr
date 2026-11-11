// Package migrations embeds the forward-only Postgres schema migrations.
package migrations

import "embed"

// FS holds every migration, applied in filename order.
//
//go:embed *.sql
var FS embed.FS
