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
  const r2 = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com";
  assert.match(documentPolicy("n", r2), /img-src 'self' data: blob: https:\/\/0123456789abcdef0123456789abcdef\.r2\.cloudflarestorage\.com;/);
  assert.equal(originOf(r2 + "/bucket/key.jpg?X-Amz-Signature=x"), r2);
  assert.match(documentPolicy("n", originOf(undefined)), /img-src 'self' data: blob:;/);
  assert.equal(originOf("javascript:alert(1)"), "");
  assert.equal(originOf("0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"), "");
});

test("each nonce is fresh", () => {
  assert.notEqual(newNonce(), newNonce());
  assert.equal(Buffer.from(newNonce(), "base64").length, 16);
});
