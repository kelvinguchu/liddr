// Safety and conduct reports: the queue and a drawer to claim and decide each one.

import { get, post, query } from '../api.js';
import { h, fill, when, label, shortId } from '../dom.js';
import { badge, busy, button, details, drawer, field, formDialog, input, paged, report, section, select, severity, stats, table, textArea, toast } from '../ui.js';
import { filters, pageHead } from '../controls.js';

const STATUSES = [['submitted', 'New'], ['triaged', 'Triaged'], ['under_review', 'Under review'], ['resolved', 'Resolved'], ['dismissed', 'Dismissed']];
const DECISIONS = ['no_action', 'warning', 'temporary_suspension', 'permanent_ban', 'needs_more_info', 'escalate', 'dismiss'];

export async function mount(page, { params, go, goto, refresh }) {
  const status = STATUSES.some(([s]) => s === params.get('status')) ? params.get('status') : 'submitted';
  const sheet = drawer(() => go(''));
  let current = '';

  const load = () => paged(
    async (limit, offset) => (await get(`/v1/ops/moderation/reports${query({ status, limit, offset })}`)).data,
    (rows) => table([
      { title: 'Severity', cell: (r) => severity(r.severity) },
      { title: 'Category', cell: (r) => label(r.category) },
      { title: 'Incident', cell: (r) => label(r.incident_type) },
      { title: 'Source', cell: (r) => label(r.source) },
      { title: 'About account', cell: (r) => shortId(r.reported_id) },
      { title: 'Received', cell: (r) => h('span', { class: 'muted', text: when(r.created_at) }) },
      { title: 'Status', cell: (r) => badge(r.status) },
    ], rows, (r) => go(r.id), (r) => ({
      title: label(r.category),
      status: badge(r.status),
      tags: [severity(r.severity), h('span', { text: label(r.incident_type) })],
      meta: [label(r.source), h('span', {}, 'About ', shortId(r.reported_id)), when(r.created_at)],
    })),
    status === 'submitted' ? 'No new reports.' : 'No reports in this state.',
  );
  const list = h('div', {}, await load());
  const reloadList = async () => fill(list, await load());

  fill(page,
    pageHead({ title: 'Reports', desc: 'Most severe first. Start a review before looking into a case, so two people do not work it at once.', refresh }),
    filters([{ key: 'status', label: 'Status', options: STATUSES, value: status, fallback: 'submitted' }], (v) => go('', v)),
    list);

  async function open(id) {
    current = id;
    sheet.loading();
    try {
      const r = await get(`/v1/ops/moderation/reports/${encodeURIComponent(id)}`);
      if (current === id) showReport(r);
    } catch (err) {
      if (current === id) sheet.fail(err, () => open(id));
    }
  }

  function showReport(r) {
    const s = r.summary;
    const after = () => Promise.all([open(s.id), reloadList()]);
    const closed = s.status === 'resolved' || s.status === 'dismissed';
    const claim = (to, text, variant) => {
      const b = button(text, { variant });
      b.addEventListener('click', () => busy(b, async () => {
        await post(`/v1/ops/moderation/reports/${s.id}/triage`, { status: to });
        toast(to === 'under_review' ? 'Review started' : 'Marked triaged');
        await after();
      }).catch(report));
      return b;
    };
    sheet.show({
      eyebrow: 'Report',
      title: label(s.category),
      sub: `${label(s.incident_type)} · received ${when(s.created_at)}`,
      actions: closed ? [] : [
        s.status !== 'under_review' && claim('under_review', 'Start review', 'primary'),
        s.status === 'submitted' && claim('triaged', 'Mark triaged', 'outline'),
        button('Decide', { variant: s.status === 'under_review' ? 'primary' : 'outline', onClick: () => decide(s.id).then((ok) => ok && after()) }),
      ],
    },
    stats([['Severity', severity(s.severity)], ['Status', badge(s.status)], ['Source', label(s.source)], ['Outcome', r.outcome ? label(r.outcome) : '—']]),
    section('What was reported',
      h('div', { class: 'panel quote', text: r.description || 'No description was given.' }),
      h('p', { class: 'note', text: 'The reporter\'s own words. Never share them, or who sent them, with the reported person.' })),
    details('People and ride', [
      ['Reported account', h('span', { class: 'mono', text: s.reported_id })],
      ['Reported by', s.reporter_id ? h('span', { class: 'mono', text: s.reporter_id }) : 'System'],
      ['Ride', s.ride_id ? h('span', { class: 'mono', text: s.ride_id }) : 'Not linked to a ride'],
    ]),
    h('div', {}, button('Penalties on this account', { variant: 'outline', size: 'sm', iconName: 'ban', onClick: () => goto('penalties', '', { user: s.reported_id }) })));
  }

  return {
    show(id) {
      if (id) open(id);
      else {
        current = '';
        sheet.close();
      }
    },
    destroy: () => sheet.destroy(),
  };
}

function decide(id) {
  const decision = select('decision', DECISIONS);
  const reasonCode = input('reason_code', { maxLength: 100, placeholder: 'e.g. unsafe_driving' });
  const notes = textArea('notes', { max: 1000 });
  const ends = input('ends_at', { type: 'datetime-local' });
  const endsField = field('Suspended until', ends, 'Nairobi time.');
  const sync = () => {
    endsField.hidden = decision.value !== 'temporary_suspension';
    ends.required = !endsField.hidden;
  };
  decision.addEventListener('change', sync);
  sync();
  return formDialog({
    title: 'Decide this report',
    intro: 'Penalties apply straight away and are recorded against your account.',
    fields: [field('Decision', decision), field('Reason code', reasonCode, 'Short and consistent, so penalties can be counted.'), endsField, field('Notes', notes, 'Internal. Up to 1000 characters.')],
    submitText: 'Record decision',
    submit: async () => {
      await post(`/v1/ops/moderation/reports/${encodeURIComponent(id)}/review`, {
        decision: decision.value,
        reason_code: reasonCode.value.trim() || undefined,
        notes: notes.value.trim() || undefined,
        ends_at: endsField.hidden ? undefined : nairobi(ends.value),
      }, { stepUp: true });
      toast('Decision recorded');
    },
  });
}

/** Reads a datetime-local value as Nairobi time (UTC+3, no daylight saving). */
export function nairobi(value) {
  if (!value) return undefined;
  const d = new Date(`${value}:00+03:00`);
  if (Number.isNaN(d.getTime())) throw new Error('Enter a valid date and time.');
  if (d.getTime() <= Date.now()) throw new Error('Choose a time in the future.');
  return d.toISOString();
}
