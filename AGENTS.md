# Liddr

Ride-hailing and delivery platform for Kenya: Go API, Postgres, Redis, WebSockets, background jobs, M-Pesa, and an Android app.

Layout: `go.work` at the root, the Go API in `apps/api`, the Android app in `apps/android`, and the old Elixir backend in `legacy/api`.
Product rules: `docs/aboutapp.md` and the policy docs in `docs/`. Status: the API domains in `legacy/api` are ported to Go. Android still needs updating to the new contract. Treat `legacy/api` as a business-rule reference, not as design or proof of correctness.

## Priorities

In order: intentional product experience, low latency, security and privacy by default. Where rules conflict, take the stricter security rule.

- Ship no placeholder UI or dead ends. Android uses theme tokens, Manrope, and clear loading, error and empty states.
- API and realtime p95 stay under 300ms in-region. Do not merge a known hot-path regression without approval.
- Every protected route has authentication and role checks, deny by default. Ops and admin need MFA, and high-risk actions need step-up.
- Critical data: ID documents, verification media, payment identifiers. Sensitive data: phones, exact pickup and dropoff, live location, report text.
- Critical files stay in private storage with short-lived signed URLs, and critical columns are encrypted. Audit auth, verification, moderation and payments.
- Never commit secrets. Align clients and docs to implemented routes, and never invent contracts.

## How to work

- If requirements are unclear or a change spans packages, write a short plan before coding.
- Start every bug fix with a test that fails for the reported reason.
- Report which commands ran and their results. Say plainly what you could not verify.
- Add to this file only after a real failure or correction, and prefer a linter, test or CI check over a sentence.
- Do not add a dependency, migration or public route that the task did not call for.

## Commands

Run from `apps/api`. Toolchain: Go 1.27.3 or newer, pinned in `go.mod` with `go get go@1.27.3`.

```sh
make db-up                                # local Postgres on 127.0.0.1:55432
make check                                # formatting, lint, vet, tests with -race
make generate                             # after editing the contract, queries or migrations
make install-lint                         # pinned golangci-lint
make seed-test-prices                     # KES 10-30 subscriptions for real-money tests; test databases only
go run ./cmd/api grant-role 07XXXXXXXX ops  # the only way to create ops or admin accounts
go test ./internal/rides -run 'TestComplete/final_fare'
go test -fuzz=FuzzParseSTKCallback -fuzztime=30s ./internal/payments
govulncheck ./...                         # gate CI on text mode; -json always exits 0
go fix -diff ./...                        # from a clean tree, after each toolchain bump
```

Use `golangci-lint` config `version: "2"`, installed by binary, with `default: none` plus: govet, staticcheck, errcheck, ineffassign, unused, bodyclose, sqlclosecheck, errorlint, exhaustive, sloglint, modernize, gosec, depguard, forbidigo. Keep `fieldalignment` and `shadow` off.

- `forbidigo` bans `log.Fatal`, `panic`, `fmt.Print`, `DefaultServeMux`, and in tests `time.Sleep` and `context.Background`.
- `depguard` enforces the package direction described below.
- Integration tests read `TEST_DATABASE_URL`. When unset they fail in CI and skip locally.
- Every PR runs lint, tests and `-race` on all packages. `govulncheck` also runs nightly.

## Layout

```text
cmd/api/main.go    calls run(ctx, args, getenv, stdout, stderr) error and exits
internal/config    environment parsing and redacting secret type
internal/httpapi   OpenAPI-generated types, handlers, middleware on net/http
internal/realtime  WebSocket hub and per-connection writers
internal/auth      sessions, OTP, TOTP, step-up
internal/sms       HostPinnacle client
internal/testdb    private migrated database per test
internal/rides     quotes, booking, trip state machine, completion
internal/dispatch  driver availability and location, offers, the dispatch worker
internal/events    realtime events, published through Postgres notifications
internal/geo, maps coordinates and Google Routes
internal/payments  M-Pesa client and callback parsers
internal/subscriptions, send, disputes, verification, moderation, ratings, messages
internal/notifications, push, email   inbox, Firebase, Resend
internal/storage, malware, sealing    signed URLs, ClamAV, column encryption
internal/retention                    deletes data when its retention period ends
internal/store     sqlc output and transaction helper
migrations/  queries/  testdata/
```

- Keep business rules and transactions in domain services. Handlers parse, authorize, call one service and render.
- Dependencies point inward: `httpapi` and `realtime` call domain packages, and domain packages call `store`.
- Domain packages push to sockets through an interface they define, and `run` wires in `realtime`.
- Prefer a few substantial packages. Ban catch-all names like `util`, `common`, `helpers`, `shared` and `pkg/`; purpose-named leaves such as `internal/money` are fine.
- Keep handwritten files at 250 lines or fewer unless the file documents why, with no one-type-per-file rule. Generated files are exempt, and sqlc output is never edited by hand.
- Use no package-level mutable state and no `func init`; sentinels and read-only lookup tables are fine. `run` builds every dependency and passes it in.
- Use plain `net/http` with `http.ServeMux`, never a web framework or `DefaultServeMux`. Register routes in one place.
- `packages/contract/openapi.yaml` is the API source of truth. Change it first, regenerate, and never edit generated code.

## Design

- Prefer clear code to clever code. Avoid reflection and `any` in application code.
- Define small interfaces where they are consumed, and return concrete types. Do not add an interface only to mock.
- Add generics only for two or more real uses.
- Pass a struct when a function takes several same-typed arguments or optional settings. Do not use functional options.
- Pick value or pointer semantics when declaring a type, and keep to it.
- Prefer synchronous functions and let callers add concurrency.
- Before adding a dependency, check source, tests, maintenance, vulnerability history, licence and transitive dependencies.
- Approved so far: `pgx/v5`, `sqlc`, `oapi-codegen` and its runtime, `google/uuid`, `goose`, River, `coder/websocket`, `go-cmp`, `goleak`, `x/sync/errgroup`. Choose and record a Redis client before first use.
- Migrations are forward-only goose files, applied by `api migrate` as a deploy step and never at server start.
- Copy a few lines instead of adding a tiny dependency.
- Do not optimize a path without a benchmark or profile. API p95 budget: under 300ms.

## Use current Go

Your training data may predate these. `go fix` applies many of them.

- `wg.Go(f)`, not `Add`, `go` and `Done`. No `tt := tt` loop copies.
- `errors.AsType[T]` over `errors.As`. Pointer helpers become `new(expr)`.
- `t.Context()` and `for b.Loop()` in tests. `testing/synctest` for timers and heartbeats.
- `sync/atomic` types, `math/rand/v2` for non-security randomness, `crypto/rand` for tokens.
- `omitzero` where it fits, and the `go.mod` `tool` directive rather than `tools.go`.
- Do not set `GOMAXPROCS`; the runtime reads container CPU limits.

## Errors

- Check every error. A discarded error needs a comment saying why that is safe.
- Handle an error once: log it or return it, never both.
- Add only new context, without "failed to", and put `%w` last.
- Translate store and provider errors into domain sentinels at package boundaries. Never expose `pgx.ErrNoRows` to callers or database text to clients.
- Compare with `errors.Is` or `errors.AsType`, never by string.
- Error strings never carry phone numbers, tokens or coordinates.
- Only `main` exits. Library code does not call `log.Fatal` or panic for expected failures.

## Concurrency

- Start a goroutine only when you can state what stops it and what waits for it.
- Start server-lifetime goroutines through one supervisor that refuses work once shutdown begins and is waited on.
- Packages that start goroutines call `goleak.VerifyTestMain`, and each ignore says why.
- Take `ctx` as the first parameter. Never store it in a struct or pass nil, and always call cancel.
- Every blocking send or receive selects on `ctx.Done()`.
- Do not tie post-response work to the request. Use `context.WithoutCancel` plus its own timeout, or enqueue a job.
- Use channels to coordinate and mutexes to guard state. Name the field `mu`; never embed a mutex, and default to `Mutex`.
- Do no I/O or channel sends while holding `mu`. Document the order wherever two locks nest.
- Buffer channels at 0 or 1 unless a measurement justifies more. Per-connection WebSocket queues are the bounded exception.
- Keep durable deadlines, such as ride offers, in Postgres and process them from a worker, not an in-memory timer.
- Do not swallow a helper's timeout or crash. Return an error so the caller can use its fallback.

## HTTP and WebSockets

- Set `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout` and `IdleTimeout`. Keep handler context timeouts below `WriteTimeout`.
- Cap request bodies with `http.MaxBytesReader`. Every `http.Client` sets `Timeout`.
- On shutdown, fail readiness, stop accepting, treat `http.ErrServerClosed` as normal, and wait for `Shutdown`. Close WebSockets yourself, shuffled across a configured window so clients do not reconnect at once.
- Keep exact WebSocket origins, never `*` or `InsecureSkipVerify`, and set read limits per message type.
- Give each connection one writer draining a queue bounded in bytes. Never block a publisher on one client.
- When the queue fills, drop the oldest location frames and count the drops. For offers and status, disconnect so the client resyncs.
- Keep a reader running on each socket. Ping idle sockets and drop dead ones. Treat any write timeout as closing the connection.
- Cap connections per user and channels per socket, and close unauthenticated sockets on a deadline.
- Check the session on connect, on each channel join and periodically, so revoked or restricted users are dropped.
- Filter location per recipient. Riders dropped off, cancelled or marked no-show stop receiving a driver's position.

## Postgres, Redis and jobs

- Share one `pgxpool` and set `MaxConns` and `PingTimeout` explicitly. Load-test before changing pool size.
- Every query takes a deadline. Run every step of a transaction on the transaction's context.
- Use `pgx.BeginTxFunc`, or `defer tx.Rollback(ctx)`, and call sqlc through `queries.WithTx(tx)`.
- Never hold a transaction across a network call to Daraja, Google, FCM, SMS or email.
- A write that must survive an error, such as a revocation, commits before the error returns. Rollback undoes it.
- Do unique-violation recovery with `ON CONFLICT`. A failed statement aborts the surrounding transaction.
- List columns explicitly, and do not use `SELECT *`.
- Live location and dispatch run on Postgres. Publish realtime events inside the transaction they describe, with `events.Publish`.
- Treat Redis as rebuildable. Postgres stays the source of truth, and every key has an owner and a TTL or a removal path.
- Update caches only after commit, and never extend a cache entry's TTL from a stale read.
- Enqueue River jobs with `InsertTx` in the same transaction as the business change.
- Workers are idempotent because delivery is at-least-once. On cancellation return `ctx.Err()`, not nil.

## Trust and money

These come from bugs found in the Elixir backend.

- Never take price, ownership, role, status or actor identity from a client. Final fare comes from the agreed quote or accepted change.
- Booking requires a valid server-issued quote. Refunds are capped at what that beneficiary was charged.
- Keep provider IDs exact in memory and storage so callbacks match. Mask only in logs, audit views and client responses.
- A later confirmed provider success overrides timeout, failure or cancellation. A later failure never overrides success.
- Verify callback amount and phone, dedupe by provider reference, and return quickly. Assume callbacks repeat and arrive late.
- Payments for a past week are credited to the current week, never used to reactivate an expired one.
- A function returns success only after the effect happened. An unconfigured email or SMS provider is an error, not a no-op.
- Compare secrets and tokens with constant-time functions. Rate-limit every code check, and reject replayed TOTP codes.
- Refresh-token reuse revokes the whole session family. Authentication must not take a row lock on each request.
- Uploaded evidence must exist in storage and match the ride, actor and kind before its key is accepted.
- Hide reporter identity and text from the accused, and hide safety reports from them entirely.
- Idempotency claims are released on panic or error and can be retaken when stale.
- Every state machine transition is checked under a row lock and audited with actor, before and after.

## Logging

- Use `slog` JSON handlers and the `...Context` calls, with `LogAttrs` on hot paths.
- Never log tokens, OTP codes, passwords, full phone numbers, live coordinates or ID documents. Secret types implement redacting `LogValue`.
- Keep log messages static and put variable data in attributes.
- Log events someone can act on. Measure endpoint rate, errors and duration, and resource saturation.
- Keep pprof off public ports.

## Testing

- Test behaviour through public APIs. Prefer end-to-end tests through `run`, using real Postgres and Redis.
- Never weaken an assertion to get a pass. Read the code under test first.
- Reset Postgres and Redis between runs, or give each test its own schema and key prefix. Leftover state is a test bug.
- Fake only third-party networks, using an `httptest` server. Test each provider's real client against it. A fake client once hid a bug that stopped paid drivers being activated.
- Use named table cases so a reported bug is one new row. Compare with `cmp.Diff` and print `got` before `want`.
- Keep large expected output in `testdata` golden files regenerated by `-update`, and review them before committing.
- Wait through a readiness route, synchronization, or one deadline-bound polling helper; never sleep and then assert. Never call `t.Fatal` from another goroutine.
- A flaky test gets an issue, then a skip citing its URL. Never retry a race failure.
- Use `t.Parallel()` only when a test owns all its state.
- Fuzz callback, webhook and message parsers, and commit `testdata/fuzz` failures.
- Coverage shows gaps and does not prove correctness. `-race` only sees code that actually runs.
- Keep your own tests for dependency behaviour you rely on, and rerun them on upgrades.

## Before calling work done

- Formatting, lint, vet, tests and `-race` pass, with `govulncheck` for dependency changes.
- Protected routes have authentication, role checks and an audit trail, with deny-by-default tests.
- New sensitive fields have a classification and a retention decision.
- API contract matches the code, and migrations have been run against a real database.
- Any path that could not be tested against a real service is named in the handoff.
