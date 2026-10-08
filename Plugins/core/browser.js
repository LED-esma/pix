// Pix's browser: finds what can be clicked or typed into on a page, numbers it, reports the text,
// and clicks or types for Pix. Injected into pages in the Pix Browser window (Browser.swift).
function pixTargets() {
  const els = [...document.querySelectorAll('a[href], button, input:not([type=hidden]), select, textarea, [role=button], [role=link], [role=tab], [role=menuitem], [onclick], [contenteditable=true]')];
  return els.filter(e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e);
    return r.width > 2 && r.height > 2 && s.visibility !== 'hidden' && s.display !== 'none' && r.bottom > 0 && r.top < innerHeight * 3; }).slice(0, 60);
}
function pixLabel(e) {
  return (e.getAttribute('aria-label') || e.innerText || e.value || e.placeholder || e.title || e.name || e.alt || '').replace(/\s+/g, ' ').trim().slice(0, 80);
}
function pixSecret(e) {
  const t = (e.type || '').toLowerCase(), ac = (e.autocomplete || '').toLowerCase(), n = ((e.name || '') + ' ' + (e.id || '')).toLowerCase();
  return t === 'password' || ac.startsWith('cc-') || ac.includes('password') || /card|cvv|cvc|ssn|social|routing|iban|account.?num|passcode|pin\b/.test(n);
}
function pixLook() {
  const els = pixTargets();
  const rows = els.map((e, i) => { e.dataset.pix = i; const tag = e.tagName.toLowerCase();
    const kind = tag === 'a' ? 'link' : tag === 'input' ? (e.type || 'text') + ' field' : tag === 'textarea' ? 'text box' : tag === 'select' ? 'menu' : 'button';
    return '[' + i + '] ' + kind + ' "' + pixLabel(e) + '"' + (pixSecret(e) ? ' (user types this)' : ''); });
  const text = (document.body ? document.body.innerText : '').replace(/\n{3,}/g, '\n\n').slice(0, 2500);
  return 'Things to use:\n' + rows.join('\n') + '\n\nPage text:\n' + text;
}
function pixFind(n) { return document.querySelector('[data-pix="' + n + '"]') || pixTargets()[n]; }
function pixSearch(e, f) {
  const n = ((e.name || '') + ' ' + (e.id || '') + ' ' + (e.getAttribute('aria-label') || '') + ' ' + (e.placeholder || '')).toLowerCase();
  return e.type === 'search' || /\b(q|query|search|keywords?|find)\b/.test(n) || !!e.closest('[role=search]')
    || (!!f && (/search|find|query/i.test(f.action || '') || f.getAttribute('role') === 'search' || !!f.querySelector('input[type=search]')));
}
function pixInfo(n) { const e = pixFind(n); if (!e) return '{}';
  const f = e.form || e.closest('form');
  const submits = (e.type === 'submit') || (e.tagName === 'BUTTON' && !!f && (e.type || 'submit') === 'submit');
  return JSON.stringify({ label: pixLabel(e), secret: pixSecret(e), submits: submits, search: pixSearch(e, f), tag: e.tagName }); }
function pixClick(n) { const e = pixFind(n); if (!e) return false; e.scrollIntoView({block: 'center'}); e.click(); return true; }
function pixType(n, text, submit) { const e = pixFind(n); if (!e) return false;
  if (!('value' in e) && !e.isContentEditable) return false;
  e.focus(); if (e.isContentEditable) { e.textContent = text; } else {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e), 'value'); setter && setter.set ? setter.set.call(e, text) : (e.value = text); }
  e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true}));
  if (submit) { const f = e.form || e.closest('form'); if (f && f.requestSubmit) f.requestSubmit(); else e.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); }
  return true; }
