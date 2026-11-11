// Reading a page's search parameters. Anything unexpected falls back, so a
// mistyped or stale link still opens a working page.

import type { SearchSchemaInput } from "@tanstack/react-router";

export type Options<T extends string> = readonly (readonly [T, string])[];

/** What a link may pass: every parameter optional, since each has a fallback. */
export type SearchIn<T> = { [K in keyof T]?: unknown } & SearchSchemaInput;

export function oneOf<T extends string>(value: unknown, options: Options<T>, fallback: T): T {
  return options.some(([v]) => v === value) ? (value as T) : fallback;
}

export function optionalText(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" ? value.trim() : undefined;
}
