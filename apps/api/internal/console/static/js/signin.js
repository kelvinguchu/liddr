// Staff sign-in: a phone code, then the authenticator. Accounts are created
// only by an operator with `api grant-role`, so there is no sign-up here.

import { get, post, requestCode, verifyCode, signOut, staffRoles } from './api.js';
import { h, fill } from './dom.js';
import { icon } from './icons.js';
import { busy, button } from './ui.js';

function frame(root, ...content) {
  root.className = '';
  root.removeAttribute('aria-busy');
  fill(root, h('div', { class: 'auth' },
    h('aside', { class: 'auth-brand' },
      h('img', { src: '/ops/logo.svg', alt: 'liddr', width: 220, height: 96 }),
      h('p', { class: 'foot', text: 'Liddr Operations · Staff only' })),
    h('main', { class: 'auth-side' }, h('div', { class: 'auth-box' },
      h('div', { class: 'mobile-logo' }, h('img', { class: 'logo-on-light', src: '/ops/logo-dark.svg', alt: 'liddr', width: 110, height: 48 }), h('img', { class: 'logo-on-dark', src: '/ops/logo.svg', alt: 'liddr', width: 110, height: 48 })),
      content))));
}

function heading(title, lede) {
  return h('div', {}, h('h1', { text: title }), lede && h('p', { class: 'lede', text: lede }));
}

function errorLine() {
  return h('p', { class: 'error', attrs: { role: 'alert' }, hidden: true });
}

function showError(node, err) {
  fill(node, err.message, err.requestId ? ` (ref ${err.requestId})` : '');
  node.hidden = false;
}

function labelled(text, control, iconName) {
  return h('label', { class: 'field' }, h('span', { text }),
    iconName ? h('div', { class: 'with-icon' }, icon(iconName, { size: 18 }), control) : control);
}

function codeInput() {
  return h('input', { class: 'input lg code', name: 'code', inputMode: 'numeric', autocomplete: 'one-time-code', required: true, maxLength: 6, pattern: '[0-9]{6}', placeholder: '000000' });
}

/** Runs the whole sign-in and resolves once the account can use staff routes. */
export function signIn(root, notice) {
  return new Promise((resolve) => phoneStep(root, notice, resolve));
}

function phoneStep(root, notice, done) {
  const phone = h('input', { class: 'input lg', type: 'tel', name: 'phone', autocomplete: 'tel', required: true, placeholder: '0712 345 678', inputMode: 'tel' });
  const error = errorLine();
  const go = button('Send code', { type: 'submit', size: 'lg' });
  go.classList.add('block');
  const form = h('form', { class: 'form' }, labelled('Phone number', phone, 'phone'), error, go);
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    error.hidden = true;
    try {
      const challenge = await busy(go, () => requestCode(phone.value.replaceAll(' ', '')));
      codeStep(root, phone.value, challenge.challenge_id, done);
    } catch (err) {
      showError(error, err);
    }
  });
  frame(root, heading('Sign in to Liddr Ops', 'Use the phone number your administrator registered.'),
    notice && h('p', { class: 'notice', text: notice }), form);
  phone.focus();
}

function codeStep(root, phone, challengeId, done) {
  const code = codeInput();
  const error = errorLine();
  const go = button('Sign in', { type: 'submit', size: 'lg' });
  go.classList.add('block');
  const back = h('button', { class: 'link-btn', type: 'button', text: 'Use a different number', on: { click: () => phoneStep(root, null, done) } });
  const form = h('form', { class: 'form' }, labelled('SMS code', code), error, go, h('div', {}, back));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    error.hidden = true;
    try {
      await busy(go, () => verifyCode(challengeId, code.value.trim()));
      if (staffRoles().length === 0) {
        await signOut();
        throw new Error('This number does not have staff access.');
      }
      await afterSignIn(root, done);
    } catch (err) {
      showError(error, err);
      code.select();
    }
  });
  frame(root, heading('Check your phone', `We sent a 6-digit code to ${phone}.`), form);
  code.focus();
}

/**
 * Checks the account can reach staff routes from here. A first sign-in goes
 * on to enrol an authenticator.
 */
export async function afterSignIn(root, done) {
  try {
    await get('/v1/ops/moderation/enforcements/metrics');
    done();
  } catch (err) {
    if (err.code === 'MFA_ENROLMENT_REQUIRED') return enrolStep(root, done);
    if (err.code === 'ADDRESS_NOT_ALLOWED') return blocked(root, err, done);
    throw err;
  }
}

function restart(root, done) {
  return async () => {
    await signOut();
    phoneStep(root, null, done);
  };
}

function blocked(root, err, done) {
  frame(root, heading('Not available on this network', err.message),
    h('p', { class: 'muted', text: 'Connect from the office network or VPN, then sign in again.' }),
    button('Sign out', { variant: 'outline', onClick: restart(root, done) }));
}

async function enrolStep(root, done) {
  frame(root, heading('Set up two-step sign-in', 'Preparing your key…'));
  let setup;
  try {
    setup = await post('/v1/auth/mfa/totp/setup');
  } catch (err) {
    frame(root, heading('Set up two-step sign-in'), h('p', { class: 'error', text: err.message }),
      button('Sign in again', { onClick: restart(root, done) }));
    return;
  }
  const code = codeInput();
  const error = errorLine();
  const go = button('Turn on', { type: 'submit', size: 'lg' });
  go.classList.add('block');
  const form = h('form', { class: 'form' },
    h('ol', { class: 'steps' },
      h('li', { text: 'Open Google Authenticator, Microsoft Authenticator or 1Password.' }),
      h('li', { text: 'Add an account with a setup key, time-based, and enter the key below.' }),
      h('li', { text: 'Type the 6-digit code the app shows.' })),
    h('div', { class: 'secret', text: setup.secret.match(/.{1,4}/g).join(' '), attrs: { 'aria-label': 'Setup key' } }),
    h('p', { class: 'note', text: 'This key is shown once. Do not share it or keep a copy anywhere else.' }),
    labelled('Code from the app', code), error, go);
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    error.hidden = true;
    try {
      await busy(go, () => post('/v1/auth/mfa/totp/confirm', { code: code.value.trim() }));
      done();
    } catch (err) {
      if (err.code === 'MFA_SETUP_EXPIRED') return enrolStep(root, done);
      showError(error, err);
      code.select();
    }
  });
  frame(root, heading('Set up two-step sign-in', 'Staff accounts need an authenticator app. You will also use it to confirm high-risk decisions.'), form);
  code.focus();
}
