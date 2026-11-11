# Liddr Ops

The staff console: driver document review, reports and penalties, disputes and
payouts, and M-Pesa payment lookup. A TanStack Start app (React, TanStack
Router and Query, Tailwind v4, shadcn conventions on Radix, Plus Jakarta Sans)
that runs as its own Node service next to the Go API, the way rootcat's `ui/`
runs next to its receiver.

The app holds no credential. Staff sign in with a code sent to the phone an
admin granted (`go run ./cmd/api grant-role 07XXXXXXXX ops`), and the API sets
the session in cookies the page cannot read (`/v1/auth/web/*`, described in
`packages/contract/openapi.yaml`). Every call goes to `/v1/...` on the same
origin. A 401 refreshes the session once, then sends the browser to
`/signin?next=<path>`; a `STEP_UP_REQUIRED` asks for an authenticator code and
retries. The API enforces roles, the authenticator, the office network allowlist
and step-up on every route; `src/lib/access.ts` only decides what to show.

## Layout

```
src/
  routes/          documents, reports, disputes, penalties, payouts, payments, signin
  components/      app shell, session gate, page header, filters, record list,
                   detail sheet, action and step-up dialogs; one folder per area
  components/ui/   shadcn-style primitives, copied from rootcat's ui
  lib/             api (typed client), contract.gen.ts (generated), step-up,
                   session, format, csp, search, lists, access
  fonts/           Plus Jakarta Sans (OFL)
public/            logos and icon
```

Phones get the same pages reworked, not squeezed: lists become cards below
768px, filters sit behind a button at the bottom right that opens a sheet,
page actions sit behind ⋯, and records open full screen.

## Develop

Needs Node 24 and a local API started with
`OPS_CONSOLE_ORIGIN=http://127.0.0.1:5173`. The dev server forwards `/v1` to
`LIDDR_DEV_API` (default `http://127.0.0.1:8080`).

```
npm ci
npm run dev            # http://127.0.0.1:5173
npm run generate       # after changing packages/contract/openapi.yaml
npm run typecheck && npm test
```

`LIDDR_DOCUMENT_ORIGIN` is the storage origin signed document links point at:
the R2 account endpoint, `https://<account id>.r2.cloudflarestorage.com`. The
page's policy lets images load from there and nowhere else; unset, document
images do not load.

## Build and run

```
npm run build          # tsc --noEmit && vite build -> .output/
PORT=3000 HOST=0.0.0.0 node .output/server/index.mjs
docker build -t liddr-ops .
```

## Production routing

One origin for the console. The proxy sends the API's paths to the Go API and
everything else here, so the session cookie applies to both. The API must run
with `OPS_CONSOLE_ORIGIN` set to that origin, and with `TRUSTED_PROXY_HOPS`
counting this proxy so the office allowlist sees the real client address.

```
ops.example.com {
	encode zstd gzip
	@api path /v1 /v1/*
	handle @api {
		reverse_proxy 127.0.0.1:8080
	}
	handle {
		reverse_proxy 127.0.0.1:3000
	}
}
```
