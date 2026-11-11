// The API's /v1 routes, typed from the contract (contract.gen.ts, made by
// `npm run generate`). Every call is same-origin: the browser sends the
// session cookie the API set at sign-in, and this file never sees a token.
//
// A 401 refreshes the session once (shared by every call waiting on it) and
// retries; if the refresh fails the browser goes to sign-in. A 403
// STEP_UP_REQUIRED asks for an authenticator code (lib/step-up) and retries
// once it is confirmed.

import type { components, paths } from "./contract.gen";
import { requestStepUp, stepUpEnded } from "./step-up";

export type Schemas = components["schemas"];

type Method = "get" | "post" | "delete";
type Operation<P extends keyof paths, M extends Method> = NonNullable<paths[P][M]>;
type PathsWith<M extends Method> = { [P in keyof paths]: paths[P][M] extends { responses: unknown } ? P : never }[keyof paths];

type Json<T> = T extends { content: { "application/json": infer J } } ? J : null;
type Success<Op> = Op extends { responses: infer R } ? (R extends { 200: infer A } ? Json<A> : R extends { 201: infer B } ? Json<B> : null) : never;
type Body<Op> = Op extends { requestBody: { content: { "application/json": infer B } } } ? B : Op extends { requestBody?: { content: { "application/json": infer B } } } ? B : never;
type PathParams<Op> = Op extends { parameters: { path: infer P } } ? P : never;
type Query<Op> = Op extends { parameters: { query: infer Q } } ? Q : Op extends { parameters: { query?: infer Q } } ? Q : never;

type Options<Op> = {
  path?: PathParams<Op>;
  query?: Query<Op>;
  body?: Body<Op>;
};

/** A refusal from the API, with its stable code and the request's reference. */
export class ApiError extends Error {
  status: number;
  code: string;
  requestId: string;
  constructor(status: number, code: string, message: string, requestId = "") {
    super(message);
    this.status = status;
    this.code = code;
    this.requestId = requestId;
  }
}

/** The one line to show for a failed call, with the reference support needs. */
export function problemText(error: unknown): string {
  if (error instanceof ApiError) return error.requestId ? `${error.message} (ref ${error.requestId})` : error.message;
  return error instanceof Error ? error.message : "Something went wrong. Please try again.";
}

const consoleHeaders = { Accept: "application/json", "X-Liddr-Console": "1" };

function buildURL(template: string, path?: object, query?: object): string {
  let filled = template;
  for (const [key, value] of Object.entries(path ?? {})) filled = filled.replace(`{${key}}`, encodeURIComponent(String(value)));
  const url = new URL(filled, window.location.origin);
  for (const [key, value] of Object.entries(query ?? {})) {
    if (value !== undefined && value !== null && value !== "") url.searchParams.set(key, String(value));
  }
  return url.pathname + url.search;
}

async function refusal(response: Response): Promise<ApiError> {
  try {
    const body = (await response.json()) as { code?: string; message?: string; request_id?: string };
    return new ApiError(response.status, body.code ?? "HTTP_" + response.status, body.message ?? "The request failed.", body.request_id);
  } catch {
    return new ApiError(response.status, "HTTP_" + response.status, response.status === 502 || response.status === 503 ? "The service is unavailable. Please try again shortly." : "The request failed.");
  }
}

async function raw(method: string, url: string, body: unknown): Promise<Response> {
  const headers: Record<string, string> = { ...consoleHeaders };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  try {
    return await fetch(url, { method: method.toUpperCase(), credentials: "same-origin", cache: "no-store", headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    throw new ApiError(0, "NETWORK", "Could not reach Liddr. Check your connection and try again.");
  }
}

let refreshing: Promise<boolean> | null = null;

/** Rotates the session cookies. Resolves false when the session has ended. */
export function refreshSession(): Promise<boolean> {
  refreshing ??= raw("post", "/v1/auth/web/session/refresh", undefined)
    .then((r) => {
      // The API clears the step-up cookie with the old session.
      stepUpEnded();
      return r.ok;
    })
    .catch(() => false)
    .finally(() => {
      refreshing = null;
    });
  return refreshing;
}

/** Sends the browser to sign-in, remembering where it was. */
export function signedOut(): void {
  if (window.location.pathname === "/signin") return;
  const next = window.location.pathname + window.location.search;
  window.location.assign(`/signin?next=${encodeURIComponent(next)}`);
}

async function call<P extends keyof paths, M extends Method>(method: M, template: P, options: Options<Operation<P, M>> = {}): Promise<Success<Operation<P, M>>> {
  const url = buildURL(template as string, options.path as object | undefined, options.query as object | undefined);
  let response = await raw(method, url, options.body);
  if (response.status === 401) {
    if (!(await refreshSession())) {
      signedOut();
      throw await refusal(response);
    }
    response = await raw(method, url, options.body);
  }
  if (response.status === 403) {
    const error = await refusal(response.clone());
    if (error.code === "STEP_UP_REQUIRED") {
      await requestStepUp();
      response = await raw(method, url, options.body);
    }
  }
  if (!response.ok) throw await refusal(response);
  if (response.status === 204) return null as Success<Operation<P, M>>;
  return (await response.json()) as Success<Operation<P, M>>;
}

export const api = {
  get: <P extends PathsWith<"get">>(path: P, options?: Options<Operation<P, "get">>) => call("get", path, options),
  post: <P extends PathsWith<"post">>(path: P, options?: Options<Operation<P, "post">>) => call("post", path, options),
  delete: <P extends PathsWith<"delete">>(path: P, options?: Options<Operation<P, "delete">>) => call("delete", path, options),
};

/** Signs in with a staff code; the API sets the session cookies. */
export async function startSession(challengeID: string, code: string): Promise<Schemas["ConsoleSession"]> {
  const response = await raw("post", "/v1/auth/web/session", { challenge_id: challengeID, code });
  if (!response.ok) throw await refusal(response);
  return (await response.json()) as Schemas["ConsoleSession"];
}

/** Ends the session and clears its cookies. Succeeds when already signed out. */
export async function endSession(): Promise<void> {
  const response = await raw("delete", "/v1/auth/web/session", undefined);
  if (!response.ok) throw await refusal(response);
}

/** Exchanges an authenticator code for the step-up cookie; resolves its lifetime in seconds. */
export async function confirmStepUp(code: string): Promise<number> {
  let response = await raw("post", "/v1/auth/web/step-up", { code });
  if (response.status === 401 && (await refreshSession())) response = await raw("post", "/v1/auth/web/step-up", { code });
  if (!response.ok) throw await refusal(response);
  return ((await response.json()) as Schemas["ConsoleStepUp"]).expires_in;
}
