// Payouts: refunds and credits awarded in dispute rulings, until someone pays them.

import { get, post, query } from '../api.js';
import { h, fill, when, label, kes, shortId } from '../dom.js';
import { badge, button, field, formDialog, input, paged, select, table, toast } from '../ui.js';
import { filters, pageHead } from '../controls.js';

const STATUSES = [['approved', 'To pay'], ['paid', 'Paid'], ['cancelled', 'Cancelled']];
const CHANNELS = ['mpesa_reversal', 'wallet_credit', 'bank_transfer', 'manual_ops'];
const CHANNEL_NAMES = { mpesa_reversal: 'M-Pesa reversal', wallet_credit: 'Wallet credit', bank_transfer: 'Bank transfer', manual_ops: 'Other, by hand' };
const channelName = (c) => CHANNEL_NAMES[c] || label(c);

export async function mount(page, { params, go, refresh }) {
  const status = STATUSES.some(([s]) => s === params.get('status')) ? params.get('status') : 'approved';
  const settle = (c) => [
    button('Mark paid', { size: 'sm', onClick: () => markPaid(c).then((ok) => ok && refresh()) }),
    button('Cancel', { variant: 'outline', size: 'sm', danger: true, onClick: () => cancel(c).then((ok) => ok && refresh()) }),
  ];
  const list = await paged(
    async (limit, offset) => (await get(`/v1/ops/disputes/compensations${query({ status, limit, offset })}`)).data,
    (rows) => table([
      { title: 'Amount', right: true, cell: (c) => h('span', { class: 'num', text: kes(c.amount_kes) }) },
      { title: 'Type', cell: (c) => label(c.compensation_type) },
      { title: 'To account', cell: (c) => shortId(c.beneficiary_id) },
      status !== 'paid' && { title: 'Ride', cell: (c) => shortId(c.ride_id) },
      { title: status === 'paid' ? 'Paid' : 'Awarded', cell: (c) => h('span', { class: 'muted', text: when(status === 'paid' ? c.processed_at : c.created_at) }) },
      status === 'paid' && { title: 'Paid by', cell: (c) => channelName(c.processing_channel) },
      status === 'paid' && { title: 'Reference', cell: (c) => h('span', { class: 'mono', text: c.processing_reference || '—' }) },
      status === 'approved' && { title: 'Status', cell: () => badge('', { tone: 'amber', text: 'To pay' }) },
      { title: '', right: true, cell: (c) => c.status === 'approved' ? h('div', { class: 'row-actions' }, settle(c)) : '' },
    ].filter(Boolean), rows, undefined, (c) => ({
      title: h('span', { class: 'num', text: kes(c.amount_kes) }),
      status: c.status === 'approved' ? badge('', { tone: 'amber', text: 'To pay' }) : badge(c.status),
      tags: [h('span', { text: label(c.compensation_type) }), h('span', {}, 'To ', shortId(c.beneficiary_id))],
      meta: [
        status === 'paid' ? `Paid ${when(c.processed_at)}` : `Awarded ${when(c.created_at)}`,
        status === 'paid' && channelName(c.processing_channel),
        status === 'paid' && c.processing_reference && h('span', { class: 'mono', text: c.processing_reference }),
        status !== 'paid' && h('span', {}, 'Ride ', shortId(c.ride_id)),
      ],
      actions: c.status === 'approved' ? settle(c) : [],
    })),
    status === 'approved' ? 'Nothing waiting to be paid.' : `No ${label(status).toLowerCase()} payouts.`,
  );
  fill(page,
    pageHead({ title: 'Payouts', desc: 'Send the money first, then record how it was paid and the reference.', refresh }),
    filters([{ key: 'status', label: 'Status', options: STATUSES, value: status, fallback: 'approved' }], (v) => go('', v)),
    list);
  return { show() {}, destroy() {} };
}

function markPaid(c) {
  const channel = select('channel', CHANNELS, CHANNEL_NAMES);
  const reference = input('reference', { required: true, maxLength: 200, placeholder: 'e.g. the M-Pesa receipt number', spellcheck: false });
  return formDialog({
    title: `Record ${kes(c.amount_kes)} as paid`,
    intro: 'Only record this once the money has actually gone out.',
    fields: [field('Paid by', channel), field('Reference', reference)],
    submitText: 'Mark paid',
    submit: async () => {
      await post(`/v1/ops/disputes/compensations/${c.id}/mark-paid`, { channel: channel.value, reference: reference.value.trim() }, { stepUp: true });
      toast('Recorded as paid');
    },
  });
}

function cancel(c) {
  return formDialog({
    title: 'Cancel this payout?',
    intro: `${kes(c.amount_kes)} will not be paid. This cannot be undone.`,
    submitText: 'Cancel payout', danger: true,
    submit: async () => {
      await post(`/v1/ops/disputes/compensations/${c.id}/cancel`, undefined, { stepUp: true });
      toast('Payout cancelled');
    },
  });
}
