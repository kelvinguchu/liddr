// Disputes: fare and service complaints, with a drawer to rule on each one.

import { get, post, query } from '../api.js';
import { h, fill, when, label, shortId } from '../dom.js';
import { badge, details, drawer, field, formDialog, input, paged, section, select, severity, stats, table, textArea, toast } from '../ui.js';
import { filters, pageHead } from '../controls.js';

const STATUSES = [['submitted', 'New'], ['triaged', 'Triaged'], ['under_review', 'Under review'], ['resolved', 'Resolved'], ['dismissed', 'Dismissed']];
const OUTCOMES = ['no_action', 'refund_full', 'refund_partial', 'credit_note', 'escalate', 'dismissed'];
const OUTCOME_NAMES = {
  no_action: 'No action', refund_full: 'Refund the full fare', refund_partial: 'Refund part of the fare',
  credit_note: 'Credit for a future ride', escalate: 'Escalate', dismissed: 'Dismiss',
};

export async function mount(page, { params, go, goto, refresh }) {
  const status = STATUSES.some(([s]) => s === params.get('status')) ? params.get('status') : 'submitted';
  const sheet = drawer(() => go(''));
  const loaded = new Map();

  const load = () => paged(
    async (limit, offset) => {
      const rows = (await get(`/v1/ops/disputes${query({ status, limit, offset })}`)).data;
      for (const d of rows) loaded.set(d.id, d);
      return rows;
    },
    (rows) => table([
      { title: 'Severity', cell: (d) => severity(d.severity) },
      { title: 'Type', cell: (d) => label(d.dispute_type) },
      { title: 'Asks for', cell: (d) => d.requested_resolution ? label(d.requested_resolution) : h('span', { class: 'muted', text: 'Nothing specific' }) },
      { title: 'Ride', cell: (d) => shortId(d.ride_id) },
      { title: 'Against', cell: (d) => shortId(d.reported_id) },
      { title: 'Received', cell: (d) => h('span', { class: 'muted', text: when(d.created_at) }) },
      { title: 'Status', cell: (d) => badge(d.status) },
    ], rows, (d) => go(d.id), (d) => ({
      title: label(d.dispute_type),
      status: badge(d.status),
      tags: [severity(d.severity), h('span', { text: d.requested_resolution ? `Asks for ${label(d.requested_resolution).toLowerCase()}` : 'Nothing specific asked for' })],
      meta: [h('span', {}, 'Ride ', shortId(d.ride_id)), h('span', {}, 'Against ', shortId(d.reported_id)), when(d.created_at)],
    })),
    status === 'submitted' ? 'No new disputes.' : 'No disputes in this state.',
  );
  const list = h('div', {}, await load());

  fill(page,
    pageHead({ title: 'Disputes', desc: 'Refunds are capped at what the person was charged for the ride.', refresh }),
    filters([{ key: 'status', label: 'Status', options: STATUSES, value: status, fallback: 'submitted' }], (v) => go('', v)),
    list);

  function open(id) {
    const d = loaded.get(id);
    if (!d) {
      sheet.fail(new Error('That dispute is not in this list. It may have moved to another status.'));
      return;
    }
    const isOpen = d.status !== 'resolved' && d.status !== 'dismissed';
    sheet.show({
      eyebrow: 'Dispute',
      title: label(d.dispute_type),
      sub: `${label(d.incident_type)} · received ${when(d.created_at)}`,
      actions: isOpen ? [
        h('button', { class: 'btn', type: 'button', text: 'Rule on this', on: { click: () => resolve(d).then(async (ok) => { if (ok) { go(''); fill(list, await load()); } }) } }),
      ] : [],
    },
    stats([['Severity', severity(d.severity)], ['Status', badge(d.status)], ['Asks for', d.requested_resolution ? label(d.requested_resolution) : '—']]),
    section('What they said', h('div', { class: 'panel quote', text: d.description })),
    details('People and ride', [
      ['Raised by', d.reporter_id ? h('span', { class: 'mono', text: d.reporter_id }) : '—'],
      ['Against', h('span', { class: 'mono', text: d.reported_id })],
      ['Ride', d.ride_id ? h('span', { class: 'mono', text: d.ride_id }) : '—'],
    ]),
    h('div', {}, h('button', { class: 'btn outline sm', type: 'button', text: 'See payouts', on: { click: () => goto('payouts') } })));
  }

  return {
    show(id) {
      if (id) open(id);
      else sheet.close();
    },
    destroy: () => sheet.destroy(),
  };
}

function resolve(d) {
  const outcome = select('outcome', OUTCOMES, OUTCOME_NAMES);
  if (OUTCOMES.includes(d.requested_resolution)) outcome.value = d.requested_resolution;
  const amount = input('amount_kes', { type: 'number', min: 1, step: 1, inputMode: 'numeric' });
  const amountField = field('Amount (KES)', amount, 'No more than the fare charged.');
  const summary = textArea('summary', { max: 1000 });
  const sync = () => {
    amountField.hidden = outcome.value !== 'refund_partial' && outcome.value !== 'credit_note';
    amount.required = !amountField.hidden;
  };
  outcome.addEventListener('change', sync);
  sync();
  return formDialog({
    title: 'Rule on this dispute',
    intro: 'A refund or credit becomes a payout to settle under Payouts.',
    fields: [field('Outcome', outcome), amountField, field('Summary', summary, 'Shared with both sides. Up to 1000 characters.')],
    submitText: 'Record ruling',
    submit: async () => {
      await post(`/v1/ops/disputes/${d.id}/resolve`, {
        outcome: outcome.value,
        amount_kes: amountField.hidden ? undefined : Number(amount.value),
        summary: summary.value.trim() || undefined,
      }, { stepUp: true });
      toast('Ruling recorded');
    },
  });
}
