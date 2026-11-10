import { test } from "node:test";
import assert from "node:assert/strict";
import { initials, isUUID, kes, label, nairobiFuture, shortID, when } from "./format.ts";

test("label turns snake_case into a sentence", () => {
  assert.equal(label("pending_review"), "Pending review");
  assert.equal(label(""), "—");
});

test("when shows Nairobi time whatever the device's zone", () => {
  assert.match(when("2026-11-10T08:48:00Z"), /11:48/);
  assert.equal(when(undefined), "—");
  assert.equal(when("not a date"), "—");
});

test("kes groups thousands", () => {
  assert.equal(kes(1000), "KES 1,000");
  assert.equal(kes(null), "—");
});

test("nairobiFuture reads a local time as UTC+3 and refuses the past", () => {
  const now = Date.parse("2026-11-10T00:00:00Z");
  assert.equal(nairobiFuture("2026-11-12T09:30", now), "2026-11-12T06:30:00.000Z");
  assert.throws(() => nairobiFuture("2026-11-09T09:30", now), /future/);
  assert.throws(() => nairobiFuture("", now), /valid/);
});

test("ids", () => {
  assert.equal(shortID("733d3040-efc5-4c72-8b18-f02e715ac2ae"), "733d3040");
  assert.ok(isUUID(" 733d3040-efc5-4c72-8b18-f02e715ac2ae "));
  assert.ok(!isUUID("733d3040"));
  assert.equal(initials("Wanjiru  Kamau"), "WK");
  assert.equal(initials(""), "ST");
});
