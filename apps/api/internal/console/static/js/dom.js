// DOM helpers. Text always goes in through textContent, never as HTML, so
// nothing a rider, driver or reporter typed can run as code in this console.

/**
 * Builds an element. props: class, text, on (event map), attrs, and any
 * plain property (type, value, disabled, hidden, href...).
 */
export function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === 'class') el.className = value;
    else if (key === 'text') el.textContent = String(value);
    else if (key === 'on') for (const [name, fn] of Object.entries(value)) el.addEventListener(name, fn);
    else if (key === 'dataset') Object.assign(el.dataset, value);
    else if (key === 'attrs') for (const [name, v] of Object.entries(value)) el.setAttribute(name, String(v));
    else if (key === 'href') el.setAttribute('href', safeHref(value));
    else el[key] = value;
  }
  append(el, children);
  return el;
}

function append(el, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

/** Replaces an element's children. */
export function fill(el, ...children) {
  el.replaceChildren();
  append(el, children);
  return el;
}

// Only in-app hash links and https links may become hrefs.
function safeHref(value) {
  const href = String(value);
  if (href.startsWith('#') || href.startsWith('/ops/')) return href;
  try {
    const url = new URL(href);
    if (url.protocol === 'https:' || (url.protocol === 'http:' && isLocal(url.hostname))) return url.href;
  } catch {
    // Not a URL; fall through to a dead link.
  }
  return '#';
}

function isLocal(host) {
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]';
}

export { safeHref };

const dateTime = new Intl.DateTimeFormat('en-KE', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Africa/Nairobi' });
const dateOnly = new Intl.DateTimeFormat('en-KE', { dateStyle: 'medium', timeZone: 'Africa/Nairobi' });
const shillings = new Intl.NumberFormat('en-KE');

/** Formats an API timestamp in Nairobi time. */
export function when(value) {
  if (!value) return '—';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? '—' : dateTime.format(d);
}

/** Formats an ISO date (no time). */
export function day(value) {
  if (!value) return '—';
  const d = new Date(`${value}T00:00:00+03:00`);
  return Number.isNaN(d.getTime()) ? value : dateOnly.format(d);
}

export function kes(amount) {
  return amount === undefined || amount === null ? '—' : `KES ${shillings.format(amount)}`;
}

/** Turns snake_case into a sentence-case label. */
export function label(value) {
  if (!value) return '—';
  const text = String(value).replaceAll('_', ' ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}

/** Shows the first block of an ID; the full ID stays in the tooltip. */
export function shortId(id) {
  if (!id) return h('span', { class: 'muted', text: '—' });
  return h('span', { class: 'mono', text: String(id).slice(0, 8), title: id });
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function isUUID(value) {
  return UUID.test(String(value).trim());
}
