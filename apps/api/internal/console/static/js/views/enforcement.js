// Penalties: what is in force, applying one directly, and lifting one early.

import { get, post, query } from '../api.js';
import { h, fill, when, label, isUUID, shortId } from '../dom.js';
import { badge, button, empty, field, filter, formDialog, input, pageHead, paged, select, stats, table, textArea, toast } from '../ui.js';
import { icon } from '../icons.js';
import { nairobi } from './reports.js';

const STATUSES = [['active', 'In force'], ['expired', 'Expired'], ['lifted', 'Lifted']];
const ACTIONS = ['warning', 'feature_restriction', 'temporary_suspension', 'permanent_ban'];

export async function mount(page, { params, go, refresh }) {
  const status = STATUSES.some(([s]) => s === params.get('status')) ? params.get('status') : 'active';
  const user = isUUID(params.get('user') || '') ? params.get('user') : '';
  const reload = refresh;

  const [metrics, list] = await Promise.all([
    get('/v1/ops/moderation/enforcements/metrics'),
    paged(
      async (limit, offset) => (await get(`/v1/ops/moderation/enforcements${query({ status, limit, offset })}`)).data,
      (rows) => {
        const shown = user ? rows.filter((r) => r.user_id === user) : rows;
        if (!shown.length) return empty('This account has no penalties in the rows loaded so far.');
        return table([
          { title: 'Account', cell: (r) => shortId(r.user_id) },
          { title: 'Penalty', cell: (r) => label(r.action) },
          { title: 'Reason', cell: (r) => h('span', { class: 'mono', text: r.reason_code }) },
          { title: 'From', cell: (r) => h('span', { class: 'muted', text: when(r.starts_at) }) },
          { title: status === 'lifted' ? 'Lifted' : 'Until', cell: (r) => h('span', { class: 'muted', text: status === 'lifted' ? when(r.lifted_at) : r.ends_at ? when(r.ends_at) : 'No end' }) },
          { title: 'Status', cell: (r) => badge(r.status, { text: r.status === 'active' ? 'In force' : label(r.status) }) },
          { title: '', right: true, cell: (r) => r.status === 'active' ? h('div', { class: 'row-actions' }, button('Lift', { variant: 'outline', size: 'sm', onClick: () => lift(r).then((ok) => ok && reload()) })) : '' },
        ], shown);
      },
      status === 'active' ? 'No penalties are in force.' : `No ${label(status).toLowerCase()} penalties.`,
    ),
  ]);

  const active = metrics.data.filter((m) => m.status === 'active');
  const total = (action) => active.filter((m) => m.action === action).reduce((n, m) => n + m.total, 0);
  const clear = button('', { variant: 'ghost', size: 'sm', iconName: 'close', title: 'Show every account', onClick: () => go('', { status }) });

  fill(page,
    pageHead('Penalties', 'Every penalty carries a reason and the staff member who applied it.',
      button('Apply a penalty', { iconName: 'plus', onClick: () => apply(user).then((ok) => ok && reload()) })),
    stats([
      ['Suspended now', String(total('temporary_suspension'))],
      ['Banned', String(total('permanent_ban'))],
      ['Restricted', String(total('feature_restriction'))],
      ['Suspensions past their end', String(metrics.overdue_suspensions), metrics.overdue_suspensions > 0],
    ]),
    h('div', { class: 'toolbar' },
      filter('Status', STATUSES, status, (s) => go('', { status: s, user })),
      user && h('span', { class: 'chip' }, icon('search', { size: 14 }), h('span', { class: 'mono', text: `Account ${user.slice(0, 8)}` }), clear)),
    list);

  return { show() {}, destroy() {} };
}

function lift(row) {
  return formDialog({
    title: 'Lift this penalty?',
    intro: `${label(row.action)} on account ${row.user_id.slice(0, 8)} ends now.`,
    submitText: 'Lift penalty',
    submit: async () => {
      await post(`/v1/ops/moderation/enforcements/${row.id}/lift`, undefined, { stepUp: true });
      toast('Penalty lifted');
    },
  });
}

function apply(user) {
  const account = input('user_id', { required: true, value: user, placeholder: 'Full account ID', spellcheck: false });
  account.classList.add('mono');
  const action = select('action', ACTIONS);
  const scope = select('scope', ['platform', 'communication'], { platform: 'Everything', communication: 'In-ride chat only' });
  const reasonCode = input('reason_code', { required: true, maxLength: 100, placeholder: 'e.g. harassment' });
  const reasonText = textArea('reason_text', { max: 1000 });
  const ends = input('ends_at', { type: 'datetime-local' });
  const endsField = field('Until', ends, 'Nairobi time. Leave empty for a restriction with no end.');
  const sync = () => {
    endsField.hidden = action.value === 'warning' || action.value === 'permanent_ban';
    ends.required = action.value === 'temporary_suspension';
  };
  action.addEventListener('change', sync);
  sync();
  return formDialog({
    title: 'Apply a penalty',
    intro: 'Prefer deciding a report, which ties the penalty to its evidence. Use this when there is no report.',
    fields: [field('Account ID', account), field('Penalty', action), field('Applies to', scope), field('Reason code', reasonCode), endsField, field('Details', reasonText, 'Internal. Up to 1000 characters.')],
    submitText: 'Apply penalty', danger: true,
    submit: async () => {
      if (!isUUID(account.value)) throw new Error('Enter the full account ID.');
      await post('/v1/ops/moderation/enforcements', {
        user_id: account.value.trim(),
        action: action.value,
        scope: scope.value,
        reason_code: reasonCode.value.trim(),
        reason_text: reasonText.value.trim() || undefined,
        ends_at: endsField.hidden ? undefined : nairobi(ends.value),
      }, { stepUp: true });
      toast('Penalty applied');
    },
  });
}
