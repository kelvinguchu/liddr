import { test } from "node:test";
import assert from "node:assert/strict";
import { documentPolicy, newNonce, originOf } from "./csp.ts";

test("scripts run only from this origin or with the response's nonce", () => {
  const policy = documentPolicy("abc");
  assert.match(policy, /script-src 'self' 'nonce-abc'(;|$)/);
  assert.doesNotMatch(policy, /script-src[^;]*unsafe/);
  assert.match(policy, /frame-ancestors 'none'/);
  assert.match(policy, /connect-src 'self'(;|$)/);
});

test("images may also come from the document storage origin only", () => {
  assert.match(documentPolicy("n", "https://storage.googleapis.com"), /img-src 'self' data: blob: https:\/\/storage\.googleapis\.com;/);
  assert.equal(originOf("https://storage.googleapis.com/bucket/path"), "https://storage.googleapis.com");
  assert.equal(originOf("javascript:alert(1)"), "");
  assert.equal(originOf("storage.googleapis.com"), "");
});

test("each nonce is fresh", () => {
  assert.notEqual(newNonce(), newNonce());
  assert.equal(Buffer.from(newNonce(), "base64").length, 16);
});
