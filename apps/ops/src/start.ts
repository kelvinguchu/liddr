import { createMiddleware, createStart } from "@tanstack/react-start";
import { documentPolicy, newNonce, originOf } from "@/lib/csp";

// Every response the app renders gets a nonce of its own. The router reads it
// from the request context (router.tsx) and the framework puts it on each
// inline script it emits. Such a response is never cached: see
// server/document-cache.ts. LIDDR_DOCUMENT_ORIGIN is the storage origin the
// API's signed document links point at: the R2 account endpoint,
// https://<account id>.r2.cloudflarestorage.com. Unset, no document image loads.
const documentSecurity = createMiddleware().server(async ({ next }) => {
  const nonce = newNonce();
  const result = await next({ context: { nonce } });
  const documents = originOf(process.env.LIDDR_DOCUMENT_ORIGIN);
  result.response.headers.set("Content-Security-Policy", documentPolicy(nonce, documents));
  result.response.headers.set("Referrer-Policy", "no-referrer");
  result.response.headers.set("X-Content-Type-Options", "nosniff");
  result.response.headers.set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()");
  return result;
});

export const startInstance = createStart(() => ({
  requestMiddleware: [documentSecurity],
}));
