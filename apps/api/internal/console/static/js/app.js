// Liddr Ops: boot, the app frame and the hash router.

import { get, hasSession, refresh, setSignedOutHandler, setStepUpPrompt, signOut, staffRoles, stepUpExpiresAt } from './api.js';
import { h, fill } from './dom.js';
import { icon } from './icons.js';
import { signIn, afterSignIn } from './signin.js';
import { askStepUp, badge, button, failure, skeleton } from './ui.js';
import * as documents from './views/documents.js';
import * as reports from './views/reports.js';
import * as disputes from './views/disputes.js';
import * as enforcement from './views/enforcement.js';
import * as payouts from './views/payouts.js';
import * as payments from './views/payments.js';

const root = document.getElementById('root');

const NAV = [
  { title: 'Review', items: [
    { path: 'documents', label: 'Driver documents', icon: 'documents', view: documents },
    { path: 'reports', label: 'Reports', icon: 'flag', view: reports },
    { path: 'disputes', label: 'Disputes', icon: 'scale', view: disputes },
  ] },
  { title: 'Enforcement', items: [
    { path: 'penalties', label: 'Penalties', icon: 'ban', view: enforcement },
  ] },
  { title: 'Money', items: [
    { path: 'payouts', label: 'Payouts', icon: 'cash', view: payouts },
    { path: 'payments', label: 'Payments', icon: 'receipt', view: payments },
  ] },
];
const SECTIONS = NAV.flatMap((g) => g.items);

let shellEl = null;
let main = null;
let crumb = null;
let stepUpChip = null;
let stepUpTimer = 0;
let mounted = null;
let me = null;

/** Reads #/section/id?key=value. */
function route() {
  const raw = location.hash.replace(/^#\/?/, '');
  const [path, search = ''] = raw.split('?');
  const [section = '', id = ''] = path.split('/').map(decodeURIComponent);
  return { section, id, params: new URLSearchParams(search) };
}

/** Moves to a route. Views call it to change a filter or open a record. */
function go(section, id = '', params = {}) {
  const entries = params instanceof URLSearchParams ? [...params] : Object.entries(params);
  const q = new URLSearchParams(entries.filter(([, v]) => v)).toString();
  const next = `#/${section}${id ? `/${encodeURIComponent(id)}` : ''}${q ? `?${q}` : ''}`;
  if (location.hash === next) render();
  else location.hash = next;
}

function initials(name) {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return 'ST';
  return (parts.length === 1 ? parts[0].slice(0, 2) : parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

function shell() {
  const name = (me && me.display_name) || 'Staff member';
  const nav = h('nav', { class: 'nav', attrs: { 'aria-label': 'Sections' } }, NAV.map((group) => h('div', {},
    h('span', { class: 'nav-title', text: group.title }),
    h('div', { class: 'nav-group' }, group.items.map((s) => h('a', { href: `#/${s.path}`, dataset: { section: s.path } }, icon(s.icon), h('span', { text: s.label })))))));
  nav.addEventListener('click', (e) => {
    if (e.target.closest('a')) shellEl.classList.remove('nav-open');
  });
  const logo = (cls, src) => h('img', { class: cls, src, alt: 'liddr', width: 74, height: 32 });
  crumb = h('strong');
  stepUpChip = h('span', { hidden: true });
  const reload = button('', { variant: 'outline', size: 'sm', iconName: 'refresh', title: 'Refresh this page', onClick: () => { mounted = null; render(); } });
  main = h('main', { class: 'main', id: 'main', tabIndex: -1 });
  shellEl = h('div', { class: 'shell' },
    h('div', { class: 'scrim', on: { click: () => shellEl.classList.remove('nav-open') } }),
    h('aside', { class: 'sidebar' },
      h('div', { class: 'brand' }, logo('logo-on-light', '/ops/logo-dark.svg'), logo('logo-on-dark', '/ops/logo.svg'), h('span', { class: 'tag', text: 'Ops' })),
      nav,
      h('div', { class: 'user' },
        h('div', { class: 'avatar', text: initials(name), attrs: { 'aria-hidden': 'true' } }),
        h('div', { class: 'who' }, h('div', { class: 'name', text: name }), badge('', { text: staffRoles().map((r) => r === 'admin' ? 'Admin' : 'Operations').join(' · ') })),
        button('', { variant: 'ghost', size: 'sm', iconName: 'signout', title: 'Sign out', onClick: leave }))),
    h('div', { class: 'frame' },
      h('header', { class: 'topbar' },
        button('', { variant: 'outline', size: 'sm', iconName: 'menu', title: 'Open menu', onClick: () => shellEl.classList.add('nav-open') }),
        h('div', { class: 'crumbs' }, h('span', { text: 'Operations' }), h('span', { text: '/' }), crumb),
        h('div', { class: 'end' }, stepUpChip, reload)),
      main));
  shellEl.querySelector('.topbar .btn').classList.add('only-mobile');
  fill(root, shellEl);
  root.className = '';
  root.removeAttribute('aria-busy');
  clearInterval(stepUpTimer);
  stepUpTimer = setInterval(showStepUp, 10000);
}

// The top bar says while high-risk actions are confirmed, and for how long.
function showStepUp() {
  if (!stepUpChip) return;
  const left = stepUpExpiresAt() - Date.now();
  if (left <= 0) {
    stepUpChip.hidden = true;
    return;
  }
  fill(stepUpChip, badge('', { tone: 'green', text: `Confirmed · ${Math.max(1, Math.round(left / 60000))} min left` }));
  stepUpChip.firstChild.prepend(icon('shield', { size: 14 }));
  stepUpChip.hidden = false;
}

function render() {
  if (!main) return;
  const { section, id, params } = route();
  const current = SECTIONS.find((s) => s.path === section);
  if (!current) {
    location.replace('#/documents');
    return;
  }
  const key = `${section}?${params}`;
  showStepUp();
  if (mounted && mounted.key === key) {
    if (mounted.handle) mounted.handle.show(id);
    return;
  }
  if (mounted && mounted.handle) mounted.handle.destroy();
  for (const link of shellEl.querySelectorAll('.nav a')) {
    if (link.dataset.section === current.path) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
  fill(crumb, current.label);
  document.title = `${current.label} · Liddr Ops`;
  const page = h('div', { class: 'page' }, skeleton());
  fill(main, page);
  const mount = { key, handle: null };
  mounted = mount;
  current.view.mount(page, { params, go: (sub, p) => go(section, sub, p ?? params), goto: go, refresh: () => { mounted = null; render(); } })
    .then((handle) => {
      if (mounted !== mount) return handle.destroy();
      mount.handle = handle;
      return handle.show(route().id);
    })
    .catch((err) => fill(page, failure(err, () => { mounted = null; render(); })));
}

async function leave() {
  clearInterval(stepUpTimer);
  if (mounted && mounted.handle) mounted.handle.destroy();
  mounted = null;
  await signOut();
  location.hash = '';
  start('You have signed out.');
}

async function start(notice) {
  main = null;
  if (hasSession()) {
    try {
      await refresh();
      // Resolves once the account can use staff routes, which may first mean
      // finishing authenticator setup.
      await new Promise((resolve, reject) => {
        afterSignIn(root, resolve).catch(reject);
      });
      return enter();
    } catch {
      // Fall through to a fresh sign-in.
    }
  }
  await signIn(root, notice);
  return enter();
}

async function enter() {
  try {
    me = await get('/v1/me');
  } catch {
    me = null;
  }
  mounted = null;
  shell();
  render();
}

setStepUpPrompt(() => askStepUp().finally(showStepUp));
setSignedOutHandler(() => {
  if (!main) return;
  if (mounted && mounted.handle) mounted.handle.destroy();
  mounted = null;
  start('Your session ended. Please sign in again.');
});
window.addEventListener('hashchange', render);
start().catch((err) => {
  root.className = 'boot';
  fill(root, failure(err, () => location.reload()));
});
