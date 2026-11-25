import { test } from "node:test";
import assert from "node:assert/strict";
import { turnsLeft } from "./orientation.ts";

test("turnsLeft turns portrait IDs and licences, and nothing else", () => {
  const cases: [string, string, number, number, boolean][] = [
    ["ID front taken upright", "national_id_front", 1200, 1900, true],
    ["ID back taken upright", "national_id_back", 1200, 1900, true],
    ["licence taken upright", "drivers_licence", 900, 1400, true],
    ["ID already landscape", "national_id_front", 1900, 1200, false],
    ["square", "drivers_licence", 1000, 1000, false],
    ["logbook page", "vehicle_logbook", 1200, 1900, false],
    ["selfie", "driver_selfie_liveness", 1200, 1600, false],
  ];
  for (const [name, type, width, height, want] of cases) assert.equal(turnsLeft(type, width, height), want, name);
});
