// Shared console components: buttons, badges, tables, the detail drawer, dialogs and toasts.

import { Cancelled, verifyStepUp } from './api.js';
import { h, fill, label } from './dom.js';
import { icon } from './icons.js';

const TONES = {
  green: ['approved', 'validated', 'clean', 'success', 'paid', 'resolved'],
  amber: ['pending', 'pending_review', 'under_review', 'submitted', 'triaged', 'scanning', 'resubmission_required', 'pending_callback', 'initiated', 'needs_review'],
  red: ['rejected', 'suspended', 'infected', 'failed', 'timeout', 'permanent_ban'],
  blue: ['active'],
  grey: ['cancelled', 'dismissed', 'expired', 'lifted'],
};
const TONE_OF = new Map(Object.entries(TONES).flatMap(([tone, list]) => list.map((s) => [s, tone])));

/** A status badge. The tone says what the status means for the reviewer. */
export function badge(status, { tone, text } = {}) {
  const t = tone ?? TONE_OF.get(status) ?? '';
  return h('span', { class: `badge ${t}`.trim(), text: text ?? label(status) });
}

export function severity(level) {
  return badge('', { tone: level >= 4 ? 'red' : level >= 2 ? 'amber' : '', text: `Level ${level}` });
}

/** A button. variant: primary (default), outline, ghost, danger, brand. */
export function button(text, { variant = 'primary', size, iconName, onClick, type = 'button', title, danger = false, disabled, className } = {}) {
  const cls = ['btn', variant === 'primary' ? '' : variant, size, danger ? 'danger-text' : '', text ? '' : 'icon-only', className].filter(Boolean).join(' ');
  return h('button', {
    class: cls, type, title, disabled,
    attrs: text ? undefined : { 'aria-label': title },
    on: onClick ? { click: onClick } : undefined,
  }, iconName && icon(iconName, { size: size === 'sm' ? 16 : 18 }), text);
}

/** Runs an action with the button showing progress. */
export async function busy(btn, action) {
  btn.disabled = true;
  btn.classList.add('busy');
  try {
    return await action();
  } finally {
    btn.disabled = false;
    btn.classList.remove('busy');
  }
}

/**
 * A list of records: a table from tablet width up, and tappable cards on
 * phones when card is given. columns: [{title, cell(row), right}].
 * card(row) returns {title, status, tags, meta, actions}. onOpen makes a
 * record open its detail.
 */
export function table(columns, rows, onOpen, card) {
  const wide = h('div', { class: card ? 'table-wrap wide-only' : 'table-wrap' }, h('table', {},
    h('thead', {}, h('tr', {}, columns.map((c) => h('th', { class: c.right ? 'right' : undefined, text: c.title, attrs: { scope: 'col' } })))),
    h('tbody', {}, rows.map((row) => {
      const tr = h('tr', {}, columns.map((c) => h('td', { class: c.right ? 'right' : undefined }, c.cell(row))));
      if (onOpen) {
        tr.className = 'link';
        tr.tabIndex = 0;
        tr.addEventListener('click', (e) => {
          if (!e.target.closest('button, a, input, label')) onOpen(row);
        });
        tr.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' && e.target === tr) onOpen(row);
        });
      }
      return tr;
    }))));
  if (!card) return wide;
  return h('div', {}, h('div', { class: 'cards' }, rows.map((row) => cardFor(card(row), onOpen && (() => onOpen(row))))), wide);
}

// A phone card shows the same fields as the table row, stacked.
function cardFor({ title, status, tags = [], meta = [], actions = [] }, open) {
  const shownTags = tags.filter(Boolean);
  const shownMeta = meta.filter(Boolean);
  const shownActions = actions.filter(Boolean);
  const body = [
    h('span', { class: 'card-top' }, h('span', { class: 'card-title' }, title), status),
    shownTags.length ? h('span', { class: 'card-tags' }, shownTags) : null,
    shownMeta.length ? h('span', { class: 'card-meta' }, shownMeta.flatMap((m, i) => (i ? [h('span', { class: 'dot', text: '·', attrs: { 'aria-hidden': 'true' } }), m] : [m]))) : null,
  ];
  if (open && !shownActions.length) return h('button', { class: 'card', type: 'button', on: { click: open } }, body);
  return h('div', { class: 'card' }, body, shownActions.length ? h('div', { class: 'card-actions' }, shownActions) : null);
}

export function skeleton(columns = 5, count = 6) {
  return h('div', { attrs: { role: 'status', 'aria-label': 'Loading' } },
    h('div', { class: 'cards' }, Array.from({ length: Math.min(count, 4) }, () => h('div', { class: 'card' },
      h('div', { class: 'bar' }), h('div', { class: 'bar short' }), h('div', { class: 'bar shorter' })))),
    h('div', { class: 'table-wrap wide-only' }, h('table', {}, h('tbody', {},
      Array.from({ length: count }, () => h('tr', { class: 'skeleton-row' },
        Array.from({ length: columns }, () => h('td', {}, h('div', { class: 'bar' })))))))));
}

export function empty(text) {
  return h('p', { class: 'empty', text });
}

export function failure(err, retry) {
  return h('div', { class: 'failed', attrs: { role: 'alert' } },
    h('p', { class: 'error', text: err.message }),
    err.requestId && h('p', { class: 'muted small', text: `Reference ${err.requestId}` }),
    retry && button('Try again', { variant: 'outline', size: 'sm', onClick: retry }));
}

const PAGE = 50;

/**
 * Loads a list in pages of 50. show(rows) draws everything loaded so far.
 * Resolves with the container once the first page is in.
 */
export async function paged(load, show, emptyText) {
  const wrap = h('div', { class: 'page' });
  let rows = [];
  const more = button('Load more', { variant: 'outline', size: 'sm' });
  const next = async () => {
    const page = await load(PAGE, rows.length);
    rows = rows.concat(page);
    fill(wrap, rows.length ? show(rows) : empty(emptyText),
      page.length === PAGE ? h('div', { class: 'more' }, h('span', { text: `Showing ${rows.length}` }), more) : null);
  };
  more.addEventListener('click', () => busy(more, next).catch(report));
  await next();
  return wrap;
}

/**
 * A strip of headline figures: [label, value, tone]. Tone 'brand' marks the
 * figure the reviewer should act on; true or 'warn' marks a problem.
 */
export function stats(items) {
  return h('div', { class: 'stats' }, items.filter(Boolean).map(([k, v, tone]) =>
    h('div', { class: `stat ${tone === true ? 'warn' : tone || ''}`.trim() }, h('span', { class: 'k', text: k }), h('span', { class: 'v' }, v))));
}

/** A titled block of label/value rows. */
export function details(title, rows) {
  return h('section', { class: 'section' }, title && h('h3', { text: title }),
    h('dl', { class: 'rows' }, rows.filter(Boolean).map(([k, v]) => h('div', {},
      h('dt', { text: k }), h('dd', {}, v === undefined || v === null || v === '' ? '—' : v)))));
}

export function section(title, ...children) {
  return h('section', { class: 'section' }, h('h3', { text: title }), children);
}

/**
 * The record drawer. One per page; show() replaces its content. onClose runs
 * when it is dismissed by Esc, the close button or a click outside.
 */
export function drawer(onClose) {
  const head = h('div', { class: 'sheet-head' });
  const body = h('div', { class: 'sheet-body' });
  const close = button('', { variant: 'ghost', size: 'sm', iconName: 'close', title: 'Close' });
  close.classList.add('sheet-close');
  const dialog = h('dialog', { class: 'sheet', attrs: { 'aria-labelledby': 'sheet-title' } }, head, body);
  close.addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', (e) => {
    if (e.target === dialog) dialog.close();
  });
  dialog.addEventListener('close', () => onClose());
  document.body.append(dialog);
  return {
    loading() {
      fill(head, close, h('div', { class: 'bar' }));
      fill(body, skeleton(2, 4));
      if (!dialog.open) dialog.showModal();
    },
    show({ eyebrow, title, sub, actions = [] }, ...content) {
      fill(head, close,
        h('div', {}, h('p', { class: 'eyebrow', text: eyebrow }), h('h2', { id: 'sheet-title', text: title }), sub && h('p', { class: 'sub', text: sub })),
        actions.filter(Boolean).length ? h('div', { class: 'actions' }, actions) : null);
      fill(body, content);
      if (!dialog.open) dialog.showModal();
      // Start reading at the title, not on the close button.
      const heading = head.querySelector('h2');
      heading.tabIndex = -1;
      heading.focus({ preventScroll: true });
    },
    fail(err, retry) {
      fill(head, close, h('h2', { id: 'sheet-title', text: 'This did not load' }));
      fill(body, failure(err, retry));
      if (!dialog.open) dialog.showModal();
    },
    close() {
      if (dialog.open) dialog.close();
    },
    destroy() {
      dialog.remove();
    },
  };
}

export function toast(message, tone = '') {
  const node = h('div', { class: `toast ${tone}`.trim(), attrs: { role: tone === 'bad' ? 'alert' : 'status' } },
    icon(tone === 'bad' ? 'alert' : 'check'), h('span', { text: message }));
  document.getElementById('toasts').append(node);
  setTimeout(() => node.remove(), 5000);
}

/** Shows an action's error. A closed authenticator prompt is not an error. */
export function report(err) {
  if (err instanceof Cancelled) return;
  toast(err.requestId ? `${err.message} (ref ${err.requestId})` : err.message, 'bad');
}

/**
 * Opens a modal form. submit(form) does the work and throws to keep the
 * dialog open with the error shown. Resolves true once it succeeded.
 */
export function formDialog({ title, intro, fields = [], submitText, danger = false, submit }) {
  return new Promise((resolve) => {
    const error = h('p', { class: 'error', attrs: { role: 'alert' }, hidden: true });
    const go = button(submitText, { variant: danger ? 'danger' : 'primary', type: 'submit' });
    const cancel = button('Cancel', { variant: 'outline', onClick: () => dialog.close() });
    const form = h('form', { method: 'dialog' },
      h('div', {}, h('h2', { text: title }), intro && h('p', { class: 'muted', text: intro })),
      fields, error, h('div', { class: 'foot' }, cancel, go));
    const dialog = h('dialog', { class: 'modal', attrs: { 'aria-label': title } }, form);
    let done = false;
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      error.hidden = true;
      try {
        await busy(go, () => submit(form));
        done = true;
        dialog.close();
      } catch (err) {
        if (err instanceof Cancelled) return;
        fill(error, err.message, err.requestId ? ` (ref ${err.requestId})` : '');
        error.hidden = false;
      }
    });
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(done);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

export function field(text, control, hint) {
  return h('label', { class: 'field' }, h('span', { text }), control, hint && h('span', { class: 'hint', text: hint }));
}

export function input(name, props = {}) {
  return h('input', { class: 'input', name, ...props });
}

export function select(name, values, names = {}) {
  return h('select', { class: 'select', name, required: true }, values.map((v) => h('option', { value: v, text: names[v] || label(v) })));
}

export function textArea(name, { required = false, max = 1000, placeholder } = {}) {
  return h('textarea', { class: 'textarea', name, required, maxLength: max, placeholder });
}

/** Asks for an authenticator code and exchanges it for a step-up token. */
export function askStepUp() {
  return new Promise((resolve, reject) => {
    const code = input('code', { inputMode: 'numeric', autocomplete: 'one-time-code', required: true, pattern: '[0-9]{6}', maxLength: 6 });
    code.classList.add('code');
    formDialog({
      title: 'Confirm with your authenticator',
      intro: 'High-risk actions need a fresh code. It covers the next five minutes.',
      fields: [field('6-digit code', code)], submitText: 'Confirm',
      submit: () => verifyStepUp(code.value.trim()),
    }).then((ok) => (ok ? resolve() : reject(new Cancelled())));
  });
}
