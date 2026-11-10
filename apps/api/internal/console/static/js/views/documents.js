// Driver verification: the application queue and a review drawer per driver.

import { get, post, query } from '../api.js';
import { h, fill, when, day, label } from '../dom.js';
import { icon } from '../icons.js';
import { badge, busy, button, details, drawer, field, formDialog, paged, report, stats, table, textArea, toast } from '../ui.js';
import { filters, pageHead } from '../controls.js';

// Under review comes first: an application lands there once every document is in.
const STATUSES = [
  ['under_review', 'Ready to review'], ['pending', 'Still uploading'], ['resubmission_required', 'Waiting on resubmission'],
  ['approved', 'Approved'], ['rejected', 'Rejected'], ['suspended', 'Suspended'],
];
const EMPTY = {
  under_review: 'No applications are waiting for review.',
  pending: 'No drivers are part way through uploading.',
};

const DOCUMENT_NAMES = {
  national_id_front: 'National ID (front)', national_id_back: 'National ID (back)', drivers_licence: "Driver's licence",
  psv_badge: 'PSV badge', good_conduct_certificate: 'Good conduct certificate', vehicle_logbook: 'Vehicle logbook',
  commercial_insurance: 'Commercial insurance', vehicle_photo_front: 'Vehicle photo (front)',
  vehicle_photo_back: 'Vehicle photo (back)', vehicle_photo_side: 'Vehicle photo (side)', driver_selfie_liveness: 'Selfie (liveness)',
};
const ORDER = Object.keys(DOCUMENT_NAMES);
const docName = (type) => DOCUMENT_NAMES[type] || label(type);
const OPEN = ['pending', 'under_review', 'resubmission_required'];

export async function mount(page, { params, go, refresh }) {
  const status = STATUSES.some(([s]) => s === params.get('status')) ? params.get('status') : 'under_review';
  const sheet = drawer(() => go(''));
  let current = '';

  const load = () => paged(
    async (limit, offset) => (await get(`/v1/ops/verification/applications${query({ status, limit, offset })}`)).data,
    (rows) => table([
      { title: 'Driver', cell: (r) => r.full_name || 'Name not given' },
      { title: 'Phone', cell: (r) => h('span', { class: 'num', text: r.phone_masked }) },
      { title: 'Plate', cell: (r) => h('span', { class: 'mono', text: r.plate_number || '—' }) },
      { title: 'Application', cell: (r) => badge(r.application.status) },
      { title: 'Driver status', cell: (r) => label(r.driver_status) },
      { title: 'Submitted', cell: (r) => h('span', { class: 'muted', text: when(r.application.created_at) }) },
    ], rows, (r) => go(r.application.id), (r) => ({
      title: r.full_name || 'Name not given',
      status: badge(r.application.status),
      tags: [r.plate_number && h('span', { class: 'mono', text: r.plate_number }), h('span', { class: 'num', text: r.phone_masked })],
      meta: [`Driver ${label(r.driver_status).toLowerCase()}`, `Submitted ${when(r.application.created_at)}`],
    })),
    EMPTY[status] || 'No applications in this state.',
  );
  const list = h('div', {}, await load());
  const reloadList = async () => fill(list, await load());

  fill(page,
    pageHead({ title: 'Driver documents', desc: 'Check every document against the driver, then decide on the application.', refresh }),
    filters([{ key: 'status', label: 'Status', options: STATUSES, value: status, fallback: 'under_review' }], (v) => go('', v)),
    list);

  async function open(id) {
    current = id;
    sheet.loading();
    try {
      const app = await get(`/v1/ops/verification/applications/${encodeURIComponent(id)}`);
      if (current === id) review(app);
    } catch (err) {
      if (current === id) sheet.fail(err, () => open(id));
    }
  }

  function review(app) {
    const s = app.summary;
    const id = s.application.id;
    const isOpen = OPEN.includes(s.application.status);
    const docs = [...app.documents].sort((a, b) => ORDER.indexOf(a.document.document_type) - ORDER.indexOf(b.document.document_type));
    const reviewable = (d) => isOpen && d.document.status === 'pending_review' && d.scan_status === 'clean';
    const validated = docs.filter((d) => d.document.status === 'validated').length;
    const waiting = docs.filter(reviewable).length;
    const after = async () => {
      await Promise.all([open(id), reloadList()]);
    };

    const chosen = new Set();
    const bulk = button('Approve selected', { size: 'sm', disabled: true });
    bulk.addEventListener('click', () => busy(bulk, async () => {
      const res = await post('/v1/ops/verification/documents/reviews/bulk', { document_ids: [...chosen], decision: 'approve' }, { stepUp: true });
      const failed = res.data.filter((r) => !r.ok);
      toast(failed.length ? `${res.data.length - failed.length} approved, ${failed.length} not (${label(failed[0].code)})` : `${res.data.length} documents approved`, failed.length ? 'bad' : '');
      await after();
    }).catch(report));

    const view = (d) => (e) => busy(e.currentTarget, async () => {
      const link = await post(`/v1/ops/verification/documents/${d.document.id}/download`);
      const decision = await viewer(d, link, reviewable(d));
      if (decision && await decideDocument(d, decision)) await after();
    }).catch(report);

    const items = docs.map((d) => {
      const can = reviewable(d);
      const pick = can && h('input', {
        type: 'checkbox', attrs: { 'aria-label': `Select ${docName(d.document.document_type)}` },
        on: { change: (e) => { if (e.target.checked) chosen.add(d.document.id); else chosen.delete(d.document.id); bulk.disabled = chosen.size === 0; fill(bulk, chosen.size ? `Approve selected (${chosen.size})` : 'Approve selected'); } },
      });
      return h('div', { class: 'item' },
        pick || h('span', { class: 'tick', attrs: { 'aria-hidden': 'true' } }),
        h('div', { class: 'main-col' },
          h('div', { class: 'top' },
            h('span', { class: 'title', text: docName(d.document.document_type) }),
            h('span', { class: 'badges' }, badge(d.document.status), d.scan_status !== 'clean' && badge(d.scan_status, { text: `Scan ${label(d.scan_status).toLowerCase()}` }))),
          h('div', { class: 'meta', text: [`Version ${d.document.version}`, `uploaded ${when(d.document.created_at)}`, d.document.expires_on && `expires ${day(d.document.expires_on)}`].filter(Boolean).join(' · ') }),
          d.document.rejection_reason && h('div', { class: 'meta', text: `Reason: ${d.document.rejection_reason}` }),
          h('div', { class: 'row-actions' },
            button('View', { variant: 'outline', size: 'sm', iconName: 'eye', disabled: d.scan_status !== 'clean', title: d.scan_status !== 'clean' ? 'Only files that passed the virus scan can be opened' : undefined, onClick: view(d) }),
            can && button('Approve', { variant: 'outline', size: 'sm', onClick: () => decideDocument(d, 'approve').then((ok) => ok && after()) }),
            can && button('Reject', { variant: 'outline', size: 'sm', danger: true, onClick: () => decideDocument(d, 'reject').then((ok) => ok && after()) }),
            can && button('Ask again', { variant: 'ghost', size: 'sm', onClick: () => decideDocument(d, 'request_resubmission').then((ok) => ok && after()) }))));
    });

    const decide = (decision, text, opts) => button(text, { ...opts, onClick: () => decideApplication(id, decision).then((ok) => ok && after()) });
    sheet.show({
      eyebrow: 'Driver application',
      title: s.full_name || 'Name not given',
      sub: [s.plate_number, s.phone_masked, `submitted ${when(s.application.created_at)}`].filter(Boolean).join(' · '),
      actions: isOpen ? [
        decide('approve', 'Approve driver', {}),
        decide('request_resubmission', 'Ask for resubmission', { variant: 'outline' }),
        decide('reject', 'Reject', { variant: 'outline', danger: true }),
        decide('suspend', 'Suspend', { variant: 'ghost', danger: true }),
      ] : [],
    },
    stats([['Application', badge(s.application.status)], ['Validated', `${validated} of ${docs.length}`], ['Awaiting you', String(waiting), waiting > 0 && 'brand'], ['Driver status', label(s.driver_status)]]),
    !isOpen && h('p', { class: 'muted', text: `Decided ${when(s.application.decided_at)}${s.application.decision_reason ? `: ${s.application.decision_reason}` : '.'}` }),
    h('section', { class: 'section' },
      h('div', { class: 'bulkbar' }, h('h3', { text: 'Documents' }), h('span', { class: 'spacer' }), isOpen && waiting > 0 && bulk),
      docs.length ? h('div', { class: 'list' }, items) : h('p', { class: 'empty', text: 'The driver has not uploaded anything yet.' })),
    details('Driver', [['Driver ID', h('span', { class: 'mono', text: s.driver_id })], ['Phone', s.phone_masked], ['Plate', s.plate_number]]));
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

/**
 * Shows one document large, with the decisions beside it. Resolves with the
 * decision the reviewer picked, or null when they closed it.
 */
function viewer(d, link, canDecide) {
  return new Promise((resolve) => {
    let picked = null;
    const pick = (decision) => () => {
      picked = decision;
      dialog.close();
    };
    const name = docName(d.document.document_type);
    const external = h('a', { class: 'btn outline sm', href: link.url, target: '_blank', rel: 'noopener noreferrer' }, icon('external', { size: 16 }), 'Open in new tab');
    const close = button('', { variant: 'ghost', size: 'sm', iconName: 'close', title: 'Close', onClick: () => dialog.close() });
    const dialog = h('dialog', { class: 'modal viewer', attrs: { 'aria-label': name } },
      h('div', { class: 'viewer-head' },
        h('div', {}, h('h2', { text: name }), h('p', { class: 'muted small', text: `Version ${d.document.version} · link expires ${when(link.expires_at)}` })),
        close),
      h('div', { class: 'preview' }, d.content_type.startsWith('image/')
        ? h('img', { src: link.url, alt: name, referrerPolicy: 'no-referrer' })
        : h('div', { class: 'failed' }, h('p', { class: 'muted', text: 'This document is a PDF. Open it in a new tab to read it.' }))),
      h('div', { class: 'viewer-foot' }, external, h('span', { class: 'spacer' }),
        canDecide && button('Ask again', { variant: 'ghost', size: 'sm', onClick: pick('request_resubmission') }),
        canDecide && button('Reject', { variant: 'outline', size: 'sm', danger: true, onClick: pick('reject') }),
        canDecide && button('Approve', { size: 'sm', iconName: 'check', onClick: pick('approve') })));
    dialog.addEventListener('click', (e) => {
      if (e.target === dialog) dialog.close();
    });
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(picked);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

const DOCUMENT_COPY = {
  approve: { title: 'Approve this document?', submit: 'Approve', done: 'Document approved' },
  reject: { title: 'Reject this document', submit: 'Reject', done: 'Document rejected', reason: true },
  request_resubmission: { title: 'Ask for a new upload', submit: 'Ask again', done: 'Driver asked to upload it again', reason: true },
};

function decideDocument(d, decision) {
  const copy = DOCUMENT_COPY[decision];
  const reason = textArea('reason', { required: true, max: 500, placeholder: 'The driver sees this, so keep it clear and kind.' });
  return formDialog({
    title: copy.title,
    intro: `${docName(d.document.document_type)}, version ${d.document.version}.`,
    fields: copy.reason ? [field('Reason', reason, 'Shown to the driver. Up to 500 characters.')] : [],
    submitText: copy.submit, danger: decision === 'reject',
    submit: async () => {
      await post(`/v1/ops/verification/documents/${d.document.id}/review`, { decision, reason: copy.reason ? reason.value.trim() : undefined }, { stepUp: true });
      toast(copy.done);
    },
  });
}

const APPLICATION_COPY = {
  approve: { title: 'Approve this driver?', intro: 'They can pay the weekly subscription and go online.', submit: 'Approve driver', done: 'Driver approved' },
  request_resubmission: { title: 'Ask for resubmission', intro: 'The driver is notified and asked to upload documents again.', submit: 'Send request', done: 'Resubmission requested' },
  reject: { title: 'Reject this application', intro: 'The driver cannot drive with Liddr on this application.', submit: 'Reject', done: 'Application rejected' },
  suspend: { title: 'Suspend this driver', intro: 'For fraud or safety concerns. The driver is notified and cannot drive while suspended.', submit: 'Suspend', done: 'Driver suspended' },
};

function decideApplication(id, decision) {
  const copy = APPLICATION_COPY[decision];
  const needsReason = decision !== 'approve';
  const reason = textArea('reason', { required: needsReason, max: 500 });
  return formDialog({
    title: copy.title, intro: copy.intro,
    fields: [field(needsReason ? 'Reason' : 'Note (optional)', reason, 'Recorded with your decision. Up to 500 characters.')],
    submitText: copy.submit, danger: decision === 'reject' || decision === 'suspend',
    submit: async () => {
      await post(`/v1/ops/verification/applications/${encodeURIComponent(id)}/review`, { decision, reason: reason.value.trim() || undefined }, { stepUp: true });
      toast(copy.done);
    },
  });
}

