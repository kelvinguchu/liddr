// The Content-Security-Policy of every document the app renders (start.ts).
//
// The framework emits inline scripts (its bootstrap and hydration state), so
// each response allows them by a nonce of its own, as in rootcat: an injected
// script does not know the value and does not run. 'unsafe-inline' must never
// return to script-src.
//
// Styles keep 'unsafe-inline' with no nonce: Radix sets them at run time, and
// a nonce in style-src would make the browser drop 'unsafe-inline' there.
//
// Driver documents are shown from short-lived signed links on the storage
// origin, the only place besides this one an image may come from.

/** A fresh nonce for one response: 128 random bits in base64. */
export function newNonce(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return btoa(String.fromCharCode(...bytes));
}

/** The storage origin from a configured URL, or nothing when it is not an http(s) URL. */
export function originOf(raw: string | undefined): string {
  if (!raw) return "";
  try {
    const url = new URL(raw);
    return url.protocol === "https:" || url.protocol === "http:" ? url.origin : "";
  } catch {
    return "";
  }
}

export function documentPolicy(nonce: string, documentOrigin = ""): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}'`,
    "style-src 'self' 'unsafe-inline'",
    `img-src 'self' data: blob:${documentOrigin ? " " + documentOrigin : ""}`,
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join("; ");
}
