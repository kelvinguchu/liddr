// Page title rows and list filters. From tablet width they sit inline. On
// phones, page actions move behind a ⋯ button and filters behind a button at
// the bottom right, both opening sheets from the bottom of the screen.

import { h, fill } from './dom.js';
import { icon } from './icons.js';
import { busy, button, report } from './ui.js';

/**
 * The page title row. refresh reloads the page's data in place. actions are
 * [{text, iconName, variant, onClick}]: buttons on wide screens, a ⋯ sheet on phones.
 */
export function pageHead({ title, desc, refresh, actions = [] }) {
  const reload = refresh && button('', {
    variant: 'outline', size: 'sm', iconName: 'refresh', title: 'Refresh',
    onClick: (e) => busy(e.currentTarget, refresh).catch(report),
  });
  const more = actions.length > 0 && button('', {
    variant: 'outline', size: 'sm', iconName: 'more', title: 'More actions', className: 'narrow-only',
    onClick: () => actionSheet(actions),
  });
  return h('header', { class: 'page-head' },
    h('div', { class: 'page-title' }, h('h1', { text: title }), desc && h('p', { class: 'desc', text: desc })),
    h('div', { class: 'actions' }, reload, more,
      actions.map((a) => button(a.text, { variant: a.variant, iconName: a.iconName, className: 'wide-only', onClick: a.onClick }))));
}

function actionSheet(actions) {
  const sheet = bottomSheet('Actions');
  fill(sheet.body, h('div', { class: 'options' }, actions.map((a) => h('button', {
    class: 'option', type: 'button',
    on: { click: () => { sheet.close(); a.onClick(); } },
  }, a.iconName && icon(a.iconName), h('span', { text: a.text })))));
}

/**
 * Filters for a list. items are [{key, label, options: [[value, text]], value,
 * fallback, hidden}]: hidden items are set elsewhere on the page (an account
 * chip, say) but still count as active and are reset by Clear. apply(values)
 * runs with every filter's value once the reviewer changes them.
 */
export function filters(items, apply) {
  const values = () => Object.fromEntries(items.map((i) => [i.key, i.value]));
  const active = items.filter((i) => i.value !== i.fallback).length;
  const reset = () => apply(Object.fromEntries(items.map((i) => [i.key, i.fallback])));
  const shown = items.filter((i) => !i.hidden);

  const wide = h('div', { class: 'toolbar wide-only' },
    shown.map((i) => {
      const el = h('select', { class: 'select', name: i.key, attrs: { 'aria-label': i.label } },
        i.options.map(([value, text]) => h('option', { value, text, selected: value === i.value })));
      el.addEventListener('change', () => apply({ ...values(), [i.key]: el.value }));
      return el;
    }),
    active > 0 && button('Clear', { variant: 'ghost', size: 'sm', onClick: reset }));

  const open = h('button', {
    class: 'fab', type: 'button',
    attrs: { 'aria-label': active ? `Filters, ${active} active` : 'Filters' },
    on: { click: () => filterSheet(shown, values(), apply) },
  }, icon('sliders', { size: 20 }), active > 0 && h('span', { class: 'fab-count', text: String(active), attrs: { 'aria-hidden': 'true' } }));
  const clear = active > 0 && h('button', {
    class: 'fab small', type: 'button', attrs: { 'aria-label': 'Clear filters' }, on: { click: reset },
  }, icon('close', { size: 18 }));

  return [wide, h('div', { class: 'fab-stack narrow-only' }, clear, open)];
}

// The phone filter sheet. Choices are staged and applied together on Done.
function filterSheet(items, current, apply) {
  const staged = { ...current };
  const sheet = bottomSheet('Filters');
  const textOf = (item) => (item.options.find(([v]) => v === staged[item.key]) || [, 'Any'])[1];
  fill(sheet.body, h('div', { class: 'form' }, items.map((item) => {
    const text = h('span', { text: textOf(item) });
    const picker = h('button', {
      class: 'picker', type: 'button', attrs: { 'aria-haspopup': 'dialog' },
      on: {
        click: async () => {
          const value = await choose(item, staged[item.key]);
          if (value === null) return;
          staged[item.key] = value;
          fill(text, textOf(item));
        },
      },
    }, text, icon('chevronDown', { size: 16 }));
    return h('div', { class: 'field' }, h('span', { text: item.label }), picker);
  })));
  fill(sheet.foot, button('Done', {
    className: 'block',
    onClick: () => {
      sheet.close();
      if (items.some((i) => staged[i.key] !== current[i.key])) apply(staged);
    },
  }));
}

// A second sheet listing one filter's options. Resolves with the pick, or null.
function choose(item, current) {
  return new Promise((resolve) => {
    let picked = null;
    const sheet = bottomSheet(item.label, () => resolve(picked));
    fill(sheet.body, h('div', { class: 'options' }, item.options.map(([value, text]) => h('button', {
      class: 'option', type: 'button', attrs: value === current ? { 'aria-current': 'true' } : undefined,
      on: { click: () => { picked = value; sheet.close(); } },
    }, h('span', { text }), value === current && icon('check')))));
  });
}

/** A sheet that rises from the bottom of the screen. onClose runs once it is dismissed. */
export function bottomSheet(title, onClose) {
  const body = h('div', { class: 'bottom-body' });
  const foot = h('div', { class: 'bottom-foot' });
  const dialog = h('dialog', { class: 'bottom', attrs: { 'aria-label': title } },
    h('div', { class: 'grip', attrs: { 'aria-hidden': 'true' } }),
    h('div', { class: 'bottom-head' }, h('h2', { text: title }),
      button('', { variant: 'ghost', size: 'sm', iconName: 'close', title: 'Close', onClick: () => dialog.close() })),
    body, foot);
  dialog.addEventListener('click', (e) => {
    if (e.target === dialog) dialog.close();
  });
  dialog.addEventListener('close', () => {
    dialog.remove();
    if (onClose) onClose();
  });
  document.body.append(dialog);
  dialog.showModal();
  return { body, foot, close: () => dialog.close() };
}
