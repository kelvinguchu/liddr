// The API client. The access token lives only in memory. The refresh token
// sits in sessionStorage so a reload keeps the session, and closing the tab
// ends it. High-risk calls carry a step-up token from the authenticator.

const REFRESH_KEY = 'liddr.ops.refresh';

let access = null;
let accessUntil = 0;
let roles = [];
let refreshing = null;
let stepUp = null;
let stepUpPending = null;
let promptStepUp = null;
let onSignedOut = () => {};

export class ApiError extends Error {
  constructor(status, body) {
    super(body && typeof body.message === 'string' ? body.message : 'Something went wrong. Please try again.');
    this.status = status;
    this.code = body && typeof body.code === 'string' ? body.code : 'UNKNOWN';
    this.requestId = body && typeof body.request_id === 'string' ? body.request_id : '';
  }
}

/** Thrown when someone closes the authenticator prompt. */
export class Cancelled extends Error {
  constructor() {
    super('Cancelled');
    this.code = 'CANCELLED';
  }
}

function readRefresh() {
  try {
    return sessionStorage.getItem(REFRESH_KEY);
  } catch {
    return null;
  }
}

function writeRefresh(token) {
  try {
    if (token) sessionStorage.setItem(REFRESH_KEY, token);
    else sessionStorage.removeItem(REFRESH_KEY);
  } catch {
    // Storage is blocked; the session then lasts only as long as this page.
  }
}

async function send(method, path, { body, token, stepUpToken } = {}) {
  const headers = { Accept: 'application/json' };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  if (stepUpToken) headers['X-Step-Up-Token'] = stepUpToken;
  let res;
  try {
    res = await fetch(path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      credentials: 'omit', cache: 'no-store', redirect: 'error',
    });
  } catch {
    throw new ApiError(0, { code: 'OFFLINE', message: 'Cannot reach Liddr. Check your connection and try again.' });
  }
  if (res.status === 204) return null;
  let data = null;
  try {
    data = await res.json();
  } catch {
    data = null;
  }
  if (!res.ok) throw new ApiError(res.status, data);
  return data;
}

function keep(session) {
  access = session.access_token;
  accessUntil = Date.now() + Math.max(session.access_token_expires_in - 30, 5) * 1000;
  roles = session.roles || [];
  writeRefresh(session.refresh_token);
}

function forget() {
  access = null;
  accessUntil = 0;
  roles = [];
  stepUp = null;
  writeRefresh(null);
}

/** When the current step-up token expires, in epoch milliseconds, or 0. */
export function stepUpExpiresAt() {
  return stepUp ? stepUp.until : 0;
}

export function hasSession() {
  return Boolean(access || readRefresh());
}

export function staffRoles() {
  return roles.filter((r) => r === 'ops' || r === 'admin');
}

export function setSignedOutHandler(fn) {
  onSignedOut = fn;
}

/** Registers the UI that asks for an authenticator code; it resolves once verifyStepUp succeeds. */
export function setStepUpPrompt(fn) {
  promptStepUp = fn;
}

export function requestCode(phone) {
  return send('POST', '/v1/auth/otp/request', { body: { phone, role: 'staff' } });
}

export async function verifyCode(challengeId, code) {
  keep(await send('POST', '/v1/auth/otp/verify', { body: { challenge_id: challengeId, code } }));
}

/** Rotates the refresh token. Concurrent callers share one rotation, since a reused token revokes the session. */
export function refresh() {
  if (!refreshing) {
    refreshing = (async () => {
      const token = readRefresh();
      if (!token) throw new ApiError(401, { code: 'SIGNED_OUT', message: 'Please sign in.' });
      try {
        keep(await send('POST', '/v1/auth/refresh', { body: { refresh_token: token } }));
      } catch (err) {
        if (err.status === 401 || err.status === 403) forget();
        throw err;
      }
    })().finally(() => {
      refreshing = null;
    });
  }
  return refreshing;
}

export async function signOut() {
  const token = readRefresh();
  forget();
  if (!token) return;
  try {
    await send('POST', '/v1/auth/logout', { body: { refresh_token: token } });
  } catch {
    // The local session is gone either way; the server expires the rest.
  }
}

export async function verifyStepUp(code) {
  const grant = await call('POST', '/v1/auth/step-up', { body: { code } });
  stepUp = { token: grant.step_up_token, until: Date.now() + Math.max(grant.expires_in - 15, 5) * 1000 };
}

async function stepUpToken() {
  if (stepUp && Date.now() < stepUp.until) return stepUp.token;
  stepUp = null;
  if (!promptStepUp) throw new ApiError(403, { code: 'STEP_UP_REQUIRED', message: 'Confirm with your authenticator code to continue.' });
  if (!stepUpPending) {
    stepUpPending = promptStepUp().finally(() => {
      stepUpPending = null;
    });
  }
  await stepUpPending;
  return stepUp.token;
}

/**
 * Calls the API as the signed-in staff member. Expired access tokens are
 * refreshed once; with stepUp set, the authenticator is asked for when needed.
 */
export async function call(method, path, { body, stepUp: needsStepUp = false } = {}) {
  for (let attempt = 0; ; attempt++) {
    if (!access || Date.now() >= accessUntil) {
      try {
        await refresh();
      } catch (err) {
        if (err.status === 401 || err.status === 403) onSignedOut(err);
        throw err;
      }
    }
    const extra = needsStepUp ? await stepUpToken() : undefined;
    try {
      return await send(method, path, { body, token: access, stepUpToken: extra });
    } catch (err) {
      if (err.status === 401 && attempt === 0) {
        access = null;
        continue;
      }
      if (err.code === 'STEP_UP_REQUIRED' && needsStepUp && attempt === 0) {
        stepUp = null;
        continue;
      }
      if (err.status === 401) {
        forget();
        onSignedOut(err);
      }
      throw err;
    }
  }
}

export const get = (path) => call('GET', path);
export const post = (path, body, opts = {}) => call('POST', path, { body, ...opts });

/** Builds a query string from defined values. */
export function query(params) {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== '') q.set(k, String(v));
  const s = q.toString();
  return s ? `?${s}` : '';
}
