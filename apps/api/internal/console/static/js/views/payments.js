// Payments: look up a driver's weekly subscription or one M-Pesa payment, and recheck it.

import { get, post } from '../api.js';
import { h, fill, when, label, kes, isUUID } from '../dom.js';
import { icon } from '../icons.js';
import { badge, busy, button, details, empty, failure, report, section, skeleton, stats, table, toast } from '../ui.js';
import { pageHead } from '../controls.js';

const KINDS = [['driver', 'Driver account ID'], ['checkout', 'M-Pesa checkout request ID']];
const PLACEHOLDER = { driver: 'e.g. 8d03619a-027f-441b-…', checkout: 'e.g. ws_CO_10112026…' };
const by = (channel) => (channel === 'stk' ? 'Phone prompt' : 'Paybill');
const STATES = {
  initiated: 'Starting', pending_callback: 'Waiting for M-Pesa', success: 'Paid', failed: 'Failed',
  cancelled: 'Cancelled by driver', timeout: 'Timed out', needs_review: 'Needs review',
};
const state = (s) => badge(s, { text: STATES[s] || label(s) });

export async function mount(page) {
  let kind = 'driver';
  const out = h('div', { class: 'page' }, empty('Look up a driver or a payment to see it here.'));
  const value = h('input', { class: 'input mono', name: 'lookup', required: true, maxLength: 100, spellcheck: false, autocomplete: 'off', placeholder: PLACEHOLDER.driver, attrs: { 'aria-label': 'ID to look up' } });
  const go = button('Look up', { type: 'submit' });
  const pick = h('select', { class: 'select', name: 'kind', attrs: { 'aria-label': 'Look up by' } },
    KINDS.map(([v, text]) => h('option', { value: v, text, selected: v === kind })));
  pick.addEventListener('change', () => {
    kind = pick.value;
    value.placeholder = PLACEHOLDER[kind];
    value.focus();
  });
  const form = h('form', { class: 'toolbar lookup' }, pick, h('div', { class: 'with-icon' }, icon('search', { size: 16 }), value), go);
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const id = value.value.trim();
    if (kind === 'driver' && !isUUID(id)) {
      fill(out, h('p', { class: 'error', text: 'Enter the full driver account ID.' }));
      return;
    }
    fill(out, skeleton(4, 3));
    busy(go, async () => {
      try {
        if (kind === 'driver') fill(out, driver(await get(`/v1/ops/subscriptions/drivers/${id}`)));
        else showPayment(await get(`/v1/ops/subscriptions/payments/${encodeURIComponent(id)}`), id);
      } catch (err) {
        fill(out, err.status === 404 ? empty(kind === 'driver' ? 'No driver has that account ID.' : 'No payment has that checkout request ID.') : failure(err));
      }
    });
  });

  const showPayment = (p, checkoutId) => fill(out, payment(p, checkoutId, showPayment));

  fill(page,
    pageHead({ title: 'Payments', desc: 'Driver subscriptions and M-Pesa payments. A recheck asks M-Pesa directly and can activate a driver who paid.' }),
    form, out);
  value.focus();
  return { show() {}, destroy() {} };
}

function driver(d) {
  return h('div', { class: 'page' },
    stats([['This week', badge(d.status), 'brand'], ['Weekly amount', kes(d.amount_kes)], ['Account reference', h('span', { class: 'mono', text: d.reference })]]),
    section('Payment attempts', d.payments.length ? table([
      { title: 'Requested', cell: (p) => h('span', { class: 'muted', text: when(p.requested_at) }) },
      { title: 'Amount', right: true, cell: (p) => h('span', { class: 'num', text: kes(p.amount_kes) }) },
      { title: 'By', cell: (p) => by(p.channel) },
      { title: 'Receipt', cell: (p) => p.receipt ? h('span', { class: 'mono', text: p.receipt }) : '—' },
      { title: 'Paid', cell: (p) => h('span', { class: 'muted', text: when(p.paid_at) }) },
      { title: 'Status', cell: (p) => state(p.status) },
    ], d.payments, undefined, (p) => ({
      title: h('span', { class: 'num', text: kes(p.amount_kes) }),
      status: state(p.status),
      tags: [h('span', { text: by(p.channel) }), p.receipt && h('span', { class: 'mono', text: p.receipt })],
      meta: [`Requested ${when(p.requested_at)}`, p.paid_at && `Paid ${when(p.paid_at)}`],
    })) : empty('This driver has not tried to pay yet.')));
}

function payment(p, checkoutId, redraw) {
  const recheck = button('Ask M-Pesa again', { variant: 'outline', iconName: 'refresh' });
  recheck.addEventListener('click', () => busy(recheck, async () => {
    const fresh = await post(`/v1/ops/subscriptions/payments/${encodeURIComponent(checkoutId)}/recheck`, undefined, { stepUp: true });
    toast(fresh.status === p.status ? `No change: ${(STATES[fresh.status] || label(fresh.status)).toLowerCase()}` : `Updated: ${(STATES[fresh.status] || label(fresh.status)).toLowerCase()}`);
    redraw(fresh, checkoutId);
  }).catch(report));
  return h('div', { class: 'page' },
    stats([['Amount', kes(p.amount_kes)], ['Status', state(p.status)], ['By', by(p.channel)], ['Receipt', p.receipt ? h('span', { class: 'mono', text: p.receipt }) : '—']]),
    p.status === 'success'
      ? h('p', { class: 'muted', text: 'M-Pesa confirmed this payment. There is nothing to recheck.' })
      : h('div', { class: 'toolbar' }, recheck, h('span', { class: 'muted', text: 'Use this when a driver paid but still shows as unpaid.' })),
    details('Payment', [
      ['Driver account', h('span', { class: 'mono', text: p.driver_id })],
      ['Phone', p.phone_masked],
      ['Checkout request', h('span', { class: 'mono', text: checkoutId })],
      ['Requested', when(p.requested_at)],
      ['Paid', when(p.paid_at)],
    ]));
}
