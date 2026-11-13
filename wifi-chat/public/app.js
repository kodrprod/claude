// LAN Chat front end: screens, chat UI, pairing flows. Talks to a Transport (see SPEC.md).
import { MAX_TEXT, MAX_NAME, sanitizeName } from './protocol.js';
import { createWsTransport } from './transport-ws.js';
import { createRtcHost, createRtcGuest } from './transport-rtc.js';

/* ================================================================== */
/* Small helpers                                                       */
/* ================================================================== */

const SVG_NS = 'http://www.w3.org/2000/svg';

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
      else el.setAttribute(k, v === true ? '' : String(v));
    }
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

function icon(name, cls = '') {
  const s = document.createElementNS(SVG_NS, 'svg');
  s.setAttribute('class', ('i ' + cls).trim());
  s.setAttribute('aria-hidden', 'true');
  s.setAttribute('focusable', 'false');
  const u = document.createElementNS(SVG_NS, 'use');
  u.setAttribute('href', '#i-' + name);
  s.append(u);
  return s;
}

function logo() {
  const s = document.createElementNS(SVG_NS, 'svg');
  s.setAttribute('class', 'logo');
  s.setAttribute('aria-hidden', 'true');
  const u = document.createElementNS(SVG_NS, 'use');
  u.setAttribute('href', '#logo');
  s.append(u);
  return s;
}

const store = {
  get(k) { try { return localStorage.getItem('lanchat.' + k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem('lanchat.' + k, v); } catch { /* ignore */ } },
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const reducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
const validColor = (c) => (typeof c === 'string' && /^#[0-9a-f]{6}$/i.test(c) ? c : '#0E7490');

function initials(name) {
  const words = String(name || '?').trim().split(/\s+/).filter(Boolean);
  const first = Array.from(words[0] || '?')[0] || '?';
  const second = words.length > 1 ? Array.from(words[1])[0] : '';
  return (first + second).toUpperCase();
}

const timeFmt = new Intl.DateTimeFormat([], { hour: '2-digit', minute: '2-digit' });
const wdayFmt = new Intl.DateTimeFormat([], { weekday: 'short' });
const dmFmt = new Intl.DateTimeFormat([], { day: 'numeric', month: 'short' });
const fmtTime = (ts) => timeFmt.format(new Date(ts));
const dayStart = (ts) => { const d = new Date(ts); d.setHours(0, 0, 0, 0); return d.getTime(); };
function fmtDivider(ts) {
  const diff = Math.round((dayStart(Date.now()) - dayStart(ts)) / 86400000);
  const t = fmtTime(ts);
  if (diff <= 0) return `Today ${t}`;
  if (diff === 1) return `Yesterday ${t}`;
  if (diff < 7) return `${wdayFmt.format(new Date(ts))} ${t}`;
  return `${dmFmt.format(new Date(ts))} ${t}`;
}

async function copyText(text) {
  try { await navigator.clipboard.writeText(text); return true; } catch { /* fall through */ }
  try {
    const ta = h('textarea', { 'aria-hidden': 'true', readonly: true, style: 'position:fixed;top:0;left:0;opacity:0;font-size:16px' });
    ta.value = text;
    document.body.append(ta);
    ta.focus(); ta.select(); ta.setSelectionRange(0, text.length);
    const ok = document.execCommand('copy');
    ta.remove();
    return ok;
  } catch { return false; }
}

/* ================================================================== */
/* State                                                               */
/* ================================================================== */

const S = {
  mode: 'rtc',            // 'server' | 'rtc'
  role: null,             // 'server' | 'host' | 'guest'
  info: null,             // /api/info payload (server mode)
  t: null,                // current transport
  offs: [],               // transport unsubscribers
  name: '',
  roomName: '',
  selfId: null,
  users: [],
  status: { state: 'connecting' },
  peers: { pending: 0, connected: 0 },
  joined: false,
  focusComposer: false,
  onPairFail: null,
};

const rootEl = document.getElementById('root');
const screenEl = h('div', { id: 'screen', style: 'height:100%' });
const overlayEl = h('div', { id: 'overlay' });
const toastsEl = h('div', { class: 'toasts' });
const announceEl = document.getElementById('announce');

function announce(text) {
  announceEl.textContent = '';
  requestAnimationFrame(() => { announceEl.textContent = text; });
}

function toast(text, { error = false, ms } = {}) {
  const el = h('div', { class: 'toast' + (error ? ' err' : ''), role: error ? 'alert' : 'status' },
    icon(error ? 'alert' : 'check'), h('span', { text }));
  const kill = () => el.remove();
  for (const old of [...toastsEl.children]) if (old.textContent === text) old.remove();
  if (error) el.append(h('button', { class: 'xbtn', type: 'button', 'aria-label': 'Dismiss', onclick: kill }, icon('x')));
  toastsEl.append(el);
  while (toastsEl.children.length > 3) toastsEl.firstChild.remove();
  setTimeout(kill, ms || (error ? 5000 : 3000));
}

function mount(node, { focusHeading = false } = {}) {
  closeDialog(true);
  screenEl.replaceChildren(node);
  if (focusHeading) node.querySelector('h1, h2')?.focus?.({ preventScroll: true });
}

/* ================================================================== */
/* Viewport (iOS keyboard) fallback                                    */
/* ================================================================== */

function syncViewport() {
  const vv = window.visualViewport;
  const rs = document.documentElement.style;
  if (!vv) return;
  if (Math.abs(vv.height - window.innerHeight) > 1 || vv.offsetTop > 0) {
    rs.setProperty('--vvh', vv.height + 'px');
    rs.setProperty('--vvt', vv.offsetTop + 'px');
    if (window.scrollY) window.scrollTo(0, 0);
  } else {
    rs.removeProperty('--vvh');
    rs.removeProperty('--vvt');
  }
}
if (window.visualViewport) {
  let wasBottom = false;
  const onVV = () => {
    wasBottom = chat.mounted && chat.nearBottom(120);
    syncViewport();
    if (wasBottom) chat.scrollBottom();
  };
  window.visualViewport.addEventListener('resize', onVV);
  window.visualViewport.addEventListener('scroll', syncViewport);
}
document.addEventListener('focusout', () => setTimeout(syncViewport, 120));

/* ================================================================== */
/* Dialogs (sheet / popover / modal)                                   */
/* ================================================================== */

let dlg = null; // { el, opener, onClose, keyHandler }
const FOCUSABLE = 'a[href],button:not([disabled]),textarea:not([disabled]),input:not([disabled]),select,summary,[tabindex]:not([tabindex="-1"])';

function openDialog({ cls, title, onClose, dismissible = true }) {
  closeDialog(true);
  const opener = document.activeElement;
  const titleId = 'dlg-title-' + Math.random().toString(36).slice(2, 7);
  const body = h('div', { class: 'dlg-body' });
  const closeBtn = h('button', { class: 'icon-btn muted', type: 'button', 'aria-label': 'Close', onclick: () => closeDialog() }, icon('x'));
  const titleEl = h('h3', { id: titleId, text: title });
  const el = h('div', { class: 'dlg sheet ' + cls, role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': titleId },
    h('div', { class: 'grab', 'aria-hidden': 'true' }),
    h('div', { class: 'sheet-head' }, titleEl, dismissible ? closeBtn : null),
    body);
  const scrim = h('div', { class: 'scrim', onclick: () => dismissible && closeDialog() });
  overlayEl.replaceChildren(scrim, el);
  overlayEl.classList.add('on');
  screenEl.setAttribute('inert', '');
  const keyHandler = (e) => {
    if (e.key === 'Escape' && dismissible) {
      if (e.target.closest?.('details[open]') && e.target.tagName === 'SUMMARY') { e.target.closest('details').open = false; return; }
      e.preventDefault(); closeDialog(); return;
    }
    if (e.key !== 'Tab') return;
    const f = [...el.querySelectorAll(FOCUSABLE)].filter((n) => n.getClientRects().length);
    if (!f.length) { e.preventDefault(); return; }
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && (document.activeElement === first || !el.contains(document.activeElement))) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && (document.activeElement === last || !el.contains(document.activeElement))) { e.preventDefault(); first.focus(); }
  };
  document.addEventListener('keydown', keyHandler);
  dlg = { el, body, opener, onClose, keyHandler };
  return { el, body, close: () => closeDialog(), setTitle: (t) => { titleEl.textContent = t; } };
}

function closeDialog(silent = false) {
  if (!dlg) return;
  const d = dlg; dlg = null;
  document.removeEventListener('keydown', d.keyHandler);
  overlayEl.classList.remove('on');
  overlayEl.replaceChildren();
  screenEl.removeAttribute('inert');
  try { d.onClose?.(); } catch (e) { console.error(e); }
  if (!silent && d.opener && d.opener.isConnected) d.opener.focus?.({ preventScroll: true });
}

function confirmDialog({ title, text, confirmLabel, danger = false }) {
  return new Promise((resolve) => {
    let result = false;
    const d = openDialog({ cls: 'confirm', title, onClose: () => resolve(result) });
    d.body.append(
      h('p', { text }),
      h('div', { class: 'dlg-actions' },
        h('button', { class: 'btn primary block' + (danger ? ' danger-fill' : ''), type: 'button', onclick: () => { result = true; d.close(); } }, confirmLabel),
        h('button', { class: 'btn secondary block', type: 'button', onclick: () => d.close() }, 'Cancel')));
    d.body.querySelector('.btn.secondary').focus();
  });
}

/* ================================================================== */
/* Reusable form / code widgets                                        */
/* ================================================================== */

function btn(label, { kind = 'secondary', ic, onclick, block = false, small = false, type = 'button', id, attrs } = {}) {
  const b = h('button', { class: `btn ${kind}${block ? ' block' : ''}${small ? ' small' : ''}`, type, id, onclick, ...attrs },
    ic ? icon(ic) : null, h('span', { class: 'lbl', text: label }));
  return b;
}

function setBusy(b, busy, label) {
  if (busy) {
    b.dataset.old = b.querySelector('.lbl').textContent;
    b.setAttribute('aria-disabled', 'true'); b.setAttribute('aria-busy', 'true'); b.disabled = false;
    const i = b.querySelector('svg.i'); if (i) i.replaceWith(h('span', { class: 'spin', 'aria-hidden': 'true' }));
    else if (!b.querySelector('.spin')) b.prepend(h('span', { class: 'spin', 'aria-hidden': 'true' }));
    if (label) b.querySelector('.lbl').textContent = label;
  } else {
    b.removeAttribute('aria-disabled'); b.removeAttribute('aria-busy');
    b.querySelector('.spin')?.remove();
    if (b.dataset.old) b.querySelector('.lbl').textContent = b.dataset.old;
  }
}

function setEnabled(b, on) { if (on) b.removeAttribute('aria-disabled'); else b.setAttribute('aria-disabled', 'true'); }
const isDisabled = (b) => b.getAttribute('aria-disabled') === 'true';

function field({ id, label, value = '', help, placeholder, maxlength, autocomplete, autocapitalize }) {
  const input = h('input', { class: 'input', id, type: 'text', placeholder, maxlength, autocomplete: autocomplete || 'off',
    autocapitalize: autocapitalize || 'words', autocorrect: 'off', spellcheck: 'false', enterkeyhint: 'next', 'aria-describedby': id + '-help' });
  input.value = value;
  const err = h('p', { class: 'msg err', id: id + '-err', hidden: true });
  const el = h('div', { class: 'field' }, h('label', { for: id, text: label }), input,
    help ? h('p', { class: 'help', id: id + '-help', text: help }) : h('span', { id: id + '-help', hidden: true }), err);
  const setErr = (msg) => {
    err.replaceChildren();
    if (!msg) { err.hidden = true; input.classList.remove('err'); input.removeAttribute('aria-invalid'); return; }
    err.hidden = false; err.append(icon('alert'), h('span', { text: msg, role: 'alert' }));
    input.classList.add('err'); input.setAttribute('aria-invalid', 'true');
    input.setAttribute('aria-describedby', id + '-err');
  };
  input.addEventListener('input', () => { if (!err.hidden) setErr(null); });
  return { el, input, setErr };
}

function errBox(text, actions = []) {
  return h('div', { class: 'errbox', role: 'alert' }, icon('alert'),
    h('div', null, h('span', { text }), ...actions));
}

function stepper(n, total, title) {
  const h2 = h('h2', { tabindex: '-1', text: title });
  const ol = h('ol', { 'aria-label': 'Progress' });
  for (let i = 1; i <= total; i++) {
    ol.append(h('li', { class: i < n ? 'done' : '', 'aria-current': i === n ? 'step' : null }, h('span', { class: 'sr', text: `Step ${i}` })));
  }
  return { el: h('div', { class: 'stepper' }, h('div', { class: 'n', text: `Step ${n} of ${total}` }), h2, ol), h2 };
}

const CODE_RE = /LC[01]\.[A-Za-z0-9_-]{16,}/;
const looksLikeCode = (s) => CODE_RE.test(String(s).replace(/\s+/g, ''));

async function readClipboardInto(ta, onChange) {
  try {
    const t = await navigator.clipboard.readText();
    if (!t) { toast('The clipboard is empty.', { error: true }); return; }
    ta.value = t; onChange?.();
  } catch {
    toast('Could not read the clipboard. Touch and hold in the box, then choose Paste.', { error: true });
    ta.focus();
  }
}

function codeInput({ id, label, help }) {
  const ta = h('textarea', { class: 'input mono', id, rows: '4', autocapitalize: 'off', autocorrect: 'off', autocomplete: 'off', spellcheck: 'false', inputmode: 'text', 'aria-describedby': id + '-valid' });
  const valid = h('div', { class: 'valid-line', id: id + '-valid', 'aria-live': 'polite' });
  const update = () => {
    const v = ta.value.trim();
    valid.replaceChildren();
    if (!v) return;
    if (looksLikeCode(v)) valid.append(h('p', { class: 'msg ok' }, icon('check'), h('span', { text: 'Looks like a valid code' })));
    else valid.append(h('p', { class: 'help', text: 'Codes start with LC1. Paste the whole code.' }));
    ta.dispatchEvent(new CustomEvent('codechange'));
  };
  ta.addEventListener('input', update);
  const pasteBtn = btn('Paste from clipboard', { kind: 'ghost', ic: 'clip', small: true, onclick: () => readClipboardInto(ta, update) });
  const el = h('div', { class: 'field' },
    h('div', { class: 'lbl-row' }, h('label', { for: id, text: label }), navigator.clipboard?.readText ? pasteBtn : null),
    ta, help ? h('p', { class: 'help', text: help }) : null, valid);
  return { el, ta, update, isValid: () => looksLikeCode(ta.value) };
}

/* ---- QR ---- */
async function buildQr(text, label) {
  try {
    const mod = await import('./vendor/qrcode-generator.mjs');
    const qr = mod.default(0, 'L');
    qr.addData(text);
    qr.make();
    const n = qr.getModuleCount();
    let d = '';
    for (let r = 0; r < n; r++) {
      let run = -1;
      for (let c = 0; c <= n; c++) {
        const dark = c < n && qr.isDark(r, c);
        if (dark && run < 0) run = c;
        else if (!dark && run >= 0) { d += `M${run} ${r}h${c - run}v1h-${c - run}z`; run = -1; }
      }
    }
    const svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', `0 0 ${n} ${n}`);
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', label);
    const bg = document.createElementNS(SVG_NS, 'rect');
    bg.setAttribute('width', n); bg.setAttribute('height', n); bg.setAttribute('fill', '#fff');
    const p = document.createElementNS(SVG_NS, 'path');
    p.setAttribute('d', d); p.setAttribute('fill', '#000');
    svg.append(bg, p);
    return svg;
  } catch (e) {
    return null; // too long (or library missing): text-only
  }
}

function canLinkInvite() {
  return window.top === window && /^https?:$/.test(location.protocol)
    && !['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
}
const inviteLink = (code) => location.origin + location.pathname + '#' + code;

/** Code panel: QR + text + copy/share. `qr` is an <svg> from buildQr or null. */
function codePanel({ code, qr, qrLabelNote, copyLabel, shareText }) {
  const codeEl = h('code', { tabindex: '0', 'aria-label': 'Code text' });
  codeEl.textContent = code;
  const box = h('div', { class: 'codebox' }, codeEl);
  const selectAll = () => { const r = document.createRange(); r.selectNodeContents(codeEl); const s = getSelection(); s.removeAllRanges(); s.addRange(r); };
  codeEl.addEventListener('click', selectAll);
  const toggle = h('button', { class: 'code-toggle', type: 'button', 'aria-expanded': 'false', text: 'Show full code' });
  const setOpen = (o) => { box.classList.toggle('open', o); toggle.setAttribute('aria-expanded', String(o)); toggle.textContent = o ? 'Hide code' : 'Show full code'; };
  toggle.addEventListener('click', () => setOpen(!box.classList.contains('open')));
  const meta = h('div', { class: 'code-meta' }, toggle, h('span', { class: 'sz', text: (code.length / 1024).toFixed(1) + ' KB' }));

  const status = h('span', { class: 'sr', role: 'status', 'aria-live': 'polite' });
  const copyBtn = h('button', { class: 'btn primary', type: 'button' }, icon('copy'), h('span', { class: 'lbl', text: copyLabel }));
  let timer = null;
  copyBtn.addEventListener('click', async () => {
    const ok = await copyText(code);
    if (!ok) {
      toast('Could not copy. Select the code and copy it by hand.', { error: true });
      setOpen(true); selectAll(); return;
    }
    status.textContent = 'Code copied';
    copyBtn.replaceChildren(icon('check'), h('span', { class: 'lbl', text: 'Copied' }));
    clearTimeout(timer);
    timer = setTimeout(() => { copyBtn.replaceChildren(icon('copy'), h('span', { class: 'lbl', text: copyLabel })); status.textContent = ''; }, 2000);
  });
  const actions = h('div', { class: 'actions' }, copyBtn, status);
  if (navigator.share) {
    actions.append(h('button', { class: 'btn secondary', type: 'button', onclick: async () => {
      try { await navigator.share({ title: 'LAN Chat', text: shareText || code }); } catch (e) { if (e?.name !== 'AbortError') toast('Could not open sharing. Use Copy instead.', { error: true }); }
    } }, icon('share'), h('span', { class: 'lbl', text: 'Share…' })));
  }

  const textPart = h('div', { style: 'display:grid;gap:12px;min-width:0' },
    qr ? h('p', { class: 'or', text: 'Or send as text' }) : null, box, meta, actions);
  if (!qr) {
    return h('div', { class: 'qr-code' },
      h('p', { class: 'qr-note', text: 'This code is too long for a QR picture. Use Copy or Share.' }), textPart);
  }
  const qrWrap = h('div', { class: 'qr-wrap' }, h('div', { class: 'qr' }, qr), qrLabelNote ? h('p', { class: 'qr-note', text: qrLabelNote }) : null);
  return h('div', { class: 'qr-code two' }, qrWrap, textPart);
}

function howDetails(text) {
  return h('details', { class: 'how' }, h('summary', null, icon('chev'), 'How does this work?'), h('div', { text }));
}

/* ================================================================== */
/* Transport glue                                                      */
/* ================================================================== */

function unbind() { for (const off of S.offs) { try { off(); } catch { /* ignore */ } } S.offs = []; }

function bindTransport(t) {
  unbind();
  S.t = t;
  S.offs.push(
    t.on('welcome', onWelcome),
    t.on('message', (m) => chat.onMessage(m)),
    t.on('presence', ({ users }) => { S.users = users; chat.renderPeople(); chat.renderHeader(); chat.renderEmpty(); }),
    t.on('typing', (e) => chat.onTyping(e)),
    t.on('system', (e) => chat.onSystem(e)),
    t.on('status', onStatus),
    t.on('peers', (p) => { S.peers = p; chat.renderHeader(); chat.renderPeople(); }),
  );
}

function onWelcome(w) {
  S.selfId = w.selfId;
  S.users = w.users || [];
  S.roomName = w.roomName || S.roomName || 'LAN Chat';
  const me = S.users.find((u) => u.id === S.selfId);
  if (me) S.name = me.name;
  const first = !S.joined;
  S.joined = true;
  if (!chat.mounted) chat.mount();
  chat.applyHistory(w.history || []);
  chat.renderHeader(); chat.renderPeople(); chat.renderEmpty(); chat.renderBanners();
  if (first && S.role === 'guest') toast(`You joined ${S.roomName}`);
}

function onStatus(st) {
  S.status = st || { state: 'connecting' };
  chat.renderHeader(); chat.renderBanners(); chat.updateComposerState();
  if (S.role === 'guest' && S.status.state === 'disconnected') {
    if (S.joined) showEnded();
    else S.onPairFail?.(S.status.detail);
  }
}

function teardown() {
  unbind();
  window.removeEventListener('beforeunload', onBeforeUnload);
  try { S.t?.close(); } catch { /* ignore */ }
  S.t = null; S.role = null; S.selfId = null; S.users = []; S.joined = false;
  S.status = { state: 'connecting' }; S.peers = { pending: 0, connected: 0 }; S.onPairFail = null;
  chat.reset();
  closeDialog(true);
}

function onBeforeUnload(e) {
  if (S.role === 'host' && S.peers.connected > 0) { e.preventDefault(); e.returnValue = ''; return ''; }
  return undefined;
}

/* ================================================================== */
/* Screens                                                             */
/* ================================================================== */

function pageCard(...kids) {
  return h('div', { class: 'page' }, h('div', { class: 'card' }, ...kids));
}
function brand(title, sub) {
  return h('div', { class: 'brand' }, logo(), h('h1', { tabindex: '-1', text: title }), sub ? h('p', { text: sub }) : null);
}

function showStart() {
  const hostBtn = h('button', { class: 'choice', type: 'button', onclick: showHostSetup },
    h('span', { class: 'ico' }, icon('home')),
    h('span', null, h('b', { text: 'Host a chat on this device' }), h('span', { class: 'd', text: 'This device becomes the room. Others connect to you.' })),
    icon('chev', 'chev'));
  const joinBtn = h('button', { class: 'choice alt', type: 'button', onclick: () => showGuestJoin() },
    h('span', { class: 'ico' }, icon('link')),
    h('span', null, h('b', { text: 'Join a chat' }), h('span', { class: 'd', text: 'Someone is already hosting. You will paste their invite.' })),
    icon('chev', 'chev'));
  const hint = h('details', { class: 'how' },
    h('summary', null, icon('chev'), 'Have a computer? Run server mode'),
    h('div', null, 'Run ', h('code', { text: 'node server/server.js' }), ' on any computer on your WiFi, then open the address it prints on every device. Guests just type their name.'));
  mount(pageCard(brand('LAN Chat', 'Chat with people on the same WiFi. No internet or accounts needed.'), hostBtn, joinBtn, hint,
    h('p', { class: 'foot-note', text: 'Works on the same WiFi only.' })));
}

/* ---- server mode: name screen ---- */
function showName() {
  const saved = sanitizeName(S.name || store.get('name') || '');
  const room = S.info?.roomName || 'LAN Chat';
  const online = S.info?.users > 0 ? `${S.info.users} online` : 'Enter your name to join';
  let changing = !saved;
  const body = h('div', { style: 'display:grid;gap:16px' });
  const render = () => {
    body.replaceChildren();
    const join = async (name) => {
      S.name = name; store.set('name', name);
      S.focusComposer = true;
      startServerSession(name, primary);
    };
    let primary;
    if (!changing) {
      primary = btn(`Continue as ${saved}`, { kind: 'primary', block: true, onclick: () => join(saved) });
      body.append(primary, btn('Change name', { kind: 'ghost', block: true, onclick: () => { changing = true; render(); body.querySelector('input').focus(); } }));
    } else {
      const f = field({ id: 'name', label: 'Your name', value: saved, placeholder: 'e.g. Sam', help: `Up to ${MAX_NAME} characters.`, maxlength: MAX_NAME, autocomplete: 'nickname' });
      const go = () => {
        const n = sanitizeName(f.input.value);
        if (!n) { f.setErr(`Pick a name, up to ${MAX_NAME} characters.`); f.input.focus(); return; }
        join(n);
      };
      f.input.enterKeyHint = 'go';
      f.input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); go(); } });
      primary = btn('Join chat', { kind: 'primary', block: true, onclick: go });
      body.append(f.el, primary);
    }
  };
  render();
  mount(pageCard(brand(room, online), body));
}

async function startServerSession(name, button) {
  setBusy(button, true, 'Joining…');
  S.role = 'server';
  const t = createWsTransport();
  bindTransport(t);
  t.connect({ name }).catch(() => { /* closed before joining */ });
}

/* ---- browser-host: setup ---- */
function showHostSetup() {
  const name = field({ id: 'name', label: 'Your name', value: sanitizeName(store.get('name') || ''), placeholder: 'e.g. Sam', help: `Up to ${MAX_NAME} characters.`, maxlength: MAX_NAME, autocomplete: 'nickname' });
  const room = field({ id: 'room', label: 'Room name', value: store.get('room') || '', placeholder: 'e.g. Family chat', maxlength: 40, autocapitalize: 'sentences' });
  const err = h('div', { 'aria-live': 'polite' });
  const go = async () => {
    const n = sanitizeName(name.input.value);
    if (!n) { name.setErr(`Pick a name, up to ${MAX_NAME} characters.`); name.input.focus(); return; }
    const r = (room.input.value.trim().replace(/\s+/g, ' ').slice(0, 40)) || `${n}'s chat`;
    S.name = n; store.set('name', n); store.set('room', room.input.value.trim());
    setBusy(cont, true, 'Starting…');
    S.role = 'host'; S.roomName = r; S.focusComposer = true;
    const host = createRtcHost({ name: n, roomName: r });
    bindTransport(host);
    window.addEventListener('beforeunload', onBeforeUnload);
    try { await host.connect(); } catch (e) { setBusy(cont, false); err.replaceChildren(errBox(e.message || 'Could not start the chat.')); teardown(); }
  };
  room.input.enterKeyHint = 'go';
  name.input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); room.input.focus(); } });
  room.input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); go(); } });
  const cont = btn('Continue', { kind: 'primary', block: true, onclick: go });
  mount(pageCard(brand('Host a chat', 'This device becomes the room. Others connect to you.'), name.el, room.el, err, cont,
    btn('Back', { kind: 'ghost', block: true, onclick: showStart })), { focusHeading: false });
}

/* ---- browser-host: guest ---- */
function showGuestJoin({ invite = '', error = '' } = {}) {
  S.onPairFail = null;
  const st = stepper(1, 2, 'Paste the invite');
  const name = field({ id: 'name', label: 'Your name', value: sanitizeName(S.name || store.get('name') || ''), placeholder: 'e.g. Sam', maxlength: MAX_NAME, autocomplete: 'nickname' });
  const code = codeInput({ id: 'invite', label: 'Invite from the host' });
  const errHold = h('div', null, error ? errBox(error) : null);
  if (invite) { code.ta.value = invite; code.update(); }
  const cont = btn('Continue', { kind: 'primary', block: true });
  const go = async () => {
    if (isDisabled(cont)) return;
    errHold.replaceChildren();
    const n = sanitizeName(name.input.value);
    if (!n) { name.setErr(`Pick a name, up to ${MAX_NAME} characters.`); name.input.focus(); return; }
    if (!code.ta.value.trim()) { errHold.append(errBox('Paste the invite you received first.')); code.ta.focus(); return; }
    S.name = n; store.set('name', n); S.focusComposer = true;
    setBusy(cont, true, 'Preparing reply…');
    S.role = 'guest';
    const guest = createRtcGuest({ name: n });
    bindTransport(guest);
    try {
      await guest.connect({ name: n });
      const reply = await guest.acceptInvite(code.ta.value);
      const qr = await buildQr(reply, 'QR code of your reply');
      showGuestReply(reply, qr, n);
    } catch (e) {
      const msg = /expired/i.test(e.message) ? 'This invite has expired. Ask for a new one.' : (e.message || 'That code does not look right. Make sure you copied all of it.');
      teardown();
      showGuestJoin({ invite: code.ta.value, error: msg });
    }
  };
  cont.addEventListener('click', go);
  mount(pageCard(st.el, name.el, code.el, errHold, cont,
    btn('Back', { kind: 'ghost', block: true, onclick: () => { S.mode === 'rtc' && showStart(); } })));
  if (error) announce(error);
}

function showGuestReply(reply, qr, name) {
  const st = stepper(2, 2, 'Send your reply to the host');
  const waiting = h('div', { class: 'waiting', role: 'status' }, h('span', { class: 'wait-dot', 'aria-hidden': 'true' }), 'Waiting for the host to accept…');
  const panel = h('div', { class: 'panel' }, codePanel({ code: reply, qr, qrLabelNote: 'The host scans this with their camera.', copyLabel: 'Copy reply' }), waiting);
  S.onPairFail = () => {
    panel.replaceChildren(errBox('Could not connect. Are you both on the same WiFi?', [
      btn('Try again', { kind: 'secondary', small: true, onclick: () => { teardown(); showGuestJoin(); } })]));
    announce('Could not connect.');
  };
  const cancel = btn('Cancel', { kind: 'ghost', block: true, onclick: () => { teardown(); showStart(); } });
  mount(pageCard(st.el, h('p', { class: 'lead', text: `Send this to whoever is hosting, ${name}. They paste it on their device to let you in.` }), panel, cancel), { focusHeading: true });
  announce('Step 2 of 2');
}

function showEnded() {
  const was = S.role;
  teardown();
  const back = btn('Back to start', { kind: 'primary', block: true, onclick: () => (S.mode === 'server' ? showName() : showStart()) });
  mount(pageCard(
    h('div', { class: 'brand' },
      h('div', { class: 'empty', style: 'padding:0;position:static;pointer-events:auto' }, h('div', { class: 'ico' }, icon('home'))),
      h('h1', { tabindex: '-1', text: 'The host ended the chat.' }),
      h('p', { text: was === 'guest' ? 'You were disconnected. Ask the host for a new invite to join again.' : 'The connection was closed.' })),
    back), { focusHeading: true });
  announce('The host ended the chat.');
}

function leaveChat() {
  const server = S.mode === 'server';
  teardown();
  if (server) showName(); else showStart();
}

/* ================================================================== */
/* Host pairing dialog                                                 */
/* ================================================================== */

function openPairing() {
  const host = S.t;
  if (S.role !== 'host' || !host) return;
  const p = { step: 1, phase: 'preparing', token: 0, invite: '', qr: null, err: '', created: 0, guestName: '', baseIds: new Set(), waitTimer: null, tick: null, link: '' };
  const offs = [];
  const d = openDialog({ cls: 'pair tall', title: 'Add a person', onClose: () => { clearInterval(p.tick); clearTimeout(p.waitTimer); offs.forEach((o) => o()); p.token = -1; } });

  const focusHeading = () => d.body.querySelector('h2')?.focus({ preventScroll: true });

  async function makeInvite() {
    const token = ++p.token;
    p.step = 1; p.phase = 'preparing'; render();
    try {
      const code = await host.createInvite();
      if (token !== p.token) return;
      p.invite = code; p.created = Date.now();
      p.link = canLinkInvite() ? inviteLink(code) : '';
      p.qr = await buildQr(p.link || code, 'QR code of the invite');
      if (token !== p.token) return;
      p.phase = 'ready';
    } catch (e) {
      if (token !== p.token) return;
      p.phase = 'error'; p.err = e.message || 'Could not create an invite.';
    }
    render();
  }

  function ago() {
    const s = Math.max(0, Math.round((Date.now() - p.created) / 1000));
    return s < 60 ? `${s} s ago` : `${Math.floor(s / 60)} min ago`;
  }

  function render() {
    clearInterval(p.tick);
    d.body.replaceChildren();
    if (p.step === 1) {
      const st = stepper(1, 2, 'Send this invite to your guest');
      d.body.append(st.el);
      if (p.phase === 'preparing') {
        const b = btn('Preparing invite…', { kind: 'primary', block: true }); setBusy(b, true);
        d.body.append(h('div', { class: 'panel', role: 'status' }, b, h('p', { class: 'help', text: 'This takes a few seconds.' })));
      } else if (p.phase === 'error') {
        d.body.append(errBox(p.err, [btn('Make a new invite', { kind: 'secondary', small: true, onclick: makeInvite })]));
      } else {
        const cap = h('p', { class: 'cap' });
        const upd = () => { cap.textContent = `Valid for about 10 minutes. Created ${ago()}.`; };
        upd(); p.tick = setInterval(upd, 5000);
        d.body.append(
          h('div', { class: 'panel' }, codePanel({
            code: p.invite, qr: p.qr, copyLabel: 'Copy invite', shareText: p.link || p.invite,
            qrLabelNote: p.link ? 'Scan with the Camera app on the other device.' : 'The other device scans this with its camera.',
          }), cap),
          btn('Next: I have their reply', { kind: 'primary', block: true, onclick: () => { p.step = 2; render(); } }),
          btn('Cancel', { kind: 'ghost', block: true, onclick: () => d.close() }),
          howDetails('Send this invite to the other person (message, AirDrop or QR). They open LAN Chat, choose Join a chat and paste it. They send you a reply code back. Everyone must be on the same WiFi. No internet needed.'));
      }
    } else if (p.step === 2) {
      const st = stepper(2, 2, 'Paste their reply');
      const code = codeInput({ id: 'reply', label: 'Reply from your guest' });
      const errHold = h('div');
      const go = h('button', { class: 'btn primary block', type: 'button', 'aria-disabled': 'true' }, h('span', { class: 'lbl', text: 'Connect' }));
      code.ta.addEventListener('codechange', () => setEnabled(go, code.isValid()));
      go.addEventListener('click', async () => {
        if (isDisabled(go)) return;
        errHold.replaceChildren();
        setBusy(go, true, 'Connecting…');
        p.baseIds = new Set(S.users.map((u) => u.id));
        try {
          await host.acceptReply(code.ta.value);
        } catch (e) {
          setBusy(go, false);
          const m = e.message || '';
          const txt = /already|match/i.test(m) ? 'This reply was already used or does not match an open invite. Make a new invite.' : (m || 'That code does not look right. Make sure you copied all of it.');
          errHold.replaceChildren(errBox(txt, [btn('Make a new invite', { kind: 'secondary', small: true, onclick: makeInvite })]));
          return;
        }
        clearTimeout(p.waitTimer);
        p.waitTimer = setTimeout(() => {
          setBusy(go, false);
          errHold.replaceChildren(errBox('Could not connect. Are you both on the same WiFi?', [btn('Make a new invite', { kind: 'secondary', small: true, onclick: makeInvite })]));
        }, 25000);
      });
      d.body.append(st.el, h('div', { class: 'panel' }, code.el), errHold, go,
        btn('Back to invite', { kind: 'ghost', block: true, onclick: () => { p.step = 1; render(); } }));
    } else {
      const name = p.guestName || 'Your guest';
      d.body.append(h('div', { class: 'panel success-panel' },
        h('div', { class: 'tick' }, icon('check')),
        h('h2', { tabindex: '-1', text: `${name} is connected.` }),
        h('p', { text: 'They can see the chat now.' })),
        btn('Back to chat', { kind: 'primary', block: true, onclick: () => d.close() }),
        btn('Add another person', { kind: 'secondary', block: true, ic: 'userplus', onclick: makeInvite }));
    }
    focusHeading();
    announce(p.step === 1 ? 'Step 1 of 2' : p.step === 2 ? 'Step 2 of 2' : 'Connected');
  }

  offs.push(host.on('presence', ({ users }) => {
    if (p.step !== 2) return;
    const fresh = p.baseIds.size ? users.find((u) => !p.baseIds.has(u.id)) : null;
    if (fresh) {
      clearTimeout(p.waitTimer);
      p.guestName = fresh.name; p.step = 3; render();
    }
  }));
  makeInvite();
}

/* ================================================================== */
/* Chat                                                                */
/* ================================================================== */

const chat = (() => {
  const C = {
    mounted: false,
    els: {},
    seen: new Set(),
    echoed: new Set(),   // cids whose echo arrived synchronously (RTC host)
    pend: new Map(),     // cid -> entry
    last: null,          // { userId, ts, li }
    lastTs: 0,
    count: 0,            // message items in the log
    unseen: 0,
    typers: new Map(),   // userId -> { name, timer }
    bannerKey: '',
    hostWarnDismissed: false,
    people: new Set(),   // containers to keep in sync
    typingOn: false, typingSent: 0, typingIdle: null,
    sysLast: null,
  };
  const E = C.els;

  C.reset = () => {
    C.mounted = false; C.els = {}; Object.keys(E).forEach((k) => delete E[k]);
    C.seen.clear(); C.echoed.clear(); for (const e of C.pend.values()) clearTimeout(e.timer); C.pend.clear();
    C.last = null; C.lastTs = 0; C.count = 0; C.unseen = 0;
    for (const t of C.typers.values()) clearTimeout(t.timer); C.typers.clear();
    C.bannerKey = ''; C.people.clear(); C.typingOn = false; clearTimeout(C.typingIdle); C.sysLast = null;
    C.hostWarnDismissed = false;
  };

  /* ---- mount ---- */
  C.mount = () => {
    const isHost = S.role === 'host';
    // sidebar
    E.sideList = h('div', { class: 'side-body', style: 'display:flex;flex-direction:column;min-height:0;flex:1' });
    const sidebar = h('aside', { class: 'sidebar', 'aria-label': 'People' },
      h('div', { class: 'sb-brand' }, logo(), 'LAN Chat'), E.sideList);
    C.people.add(E.sideList);

    // header
    E.title = h('h2', { text: S.roomName });
    E.dot = h('span', { class: 'dot', 'aria-hidden': 'true' });
    E.statusText = h('span');
    E.facepile = h('span', { class: 'facepile', 'aria-hidden': 'true' });
    E.peopleCount = h('span');
    E.peopleBtn = h('button', { class: 'people-btn', type: 'button', 'aria-haspopup': 'dialog', onclick: openPeople }, E.facepile, E.peopleCount);
    const right = h('div', { class: 'hdr-right' }, E.peopleBtn);
    if (isHost) right.prepend(h('button', { class: 'icon-btn', type: 'button', 'aria-label': 'Add person', onclick: openPairing }, icon('userplus')));
    const header = h('header', { class: 'header' },
      h('div', { class: 'h-title' }, E.title, h('div', { class: 'status', role: 'status' }, E.dot, E.statusText)), right);

    E.banners = h('div', { class: 'banner-slot' });

    // messages
    E.log = h('ol', { class: 'log', role: 'log', 'aria-label': 'Messages', 'aria-live': 'off', 'aria-relevant': 'additions' });
    E.messages = h('div', { class: 'messages', id: 'messages' }, E.log);
    E.empty = h('div', { class: 'empty' });
    E.typingText = h('span', { class: 'tx' });
    E.typing = h('div', { class: 'typing', 'aria-hidden': 'true', hidden: true }, h('span', { class: 'dots' }, h('i'), h('i'), h('i')), E.typingText);
    E.pill = h('button', { class: 'pill-new', type: 'button', hidden: true, onclick: () => { C.scrollBottom(true); } }, icon('down'), h('span'));
    const main = h('main', { class: 'main' }, E.messages, E.empty, E.typing, E.pill);

    // composer
    E.input = h('textarea', { id: 'msg', rows: '1', placeholder: 'Message', enterkeyhint: 'send', autocapitalize: 'sentences', autocomplete: 'off', autocorrect: 'on', 'aria-describedby': 'counter' });
    E.counter = h('div', { class: 'counter', id: 'counter', hidden: true });
    E.send = h('button', { class: 'send', type: 'submit', 'aria-label': 'Send', 'aria-disabled': 'true' }, icon('send'));
    const pillbox = h('div', { class: 'pillbox' }, E.input, E.send);
    E.form = h('form', { class: 'composer', autocomplete: 'off' },
      h('label', { class: 'sr', for: 'msg', text: 'Message' }), E.counter, pillbox);
    E.form.addEventListener('submit', (e) => { e.preventDefault(); if (!sendSwallow) C.send(); });

    const app = h('div', { class: 'app' }, sidebar, header, E.banners, main, E.form);
    mount(app);

    // events
    E.input.addEventListener('input', C.onInput);
    E.input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); C.send(); }
    });
    E.input.addEventListener('blur', () => C.typing(false));
    // send via pointerdown so focus (and the iPad keyboard) stay put
    let sendSwallow = false;
    E.send.addEventListener('pointerdown', (e) => {
      if (e.button) return;
      e.preventDefault();
      sendSwallow = true; setTimeout(() => { sendSwallow = false; }, 450);
      C.send();
    });
    E.messages.addEventListener('scroll', () => C.onScroll(), { passive: true });
    new ResizeObserver(() => { if (C.stick) C.scrollBottom(); }).observe(E.messages);
    C.stick = true;
    E.messages.addEventListener('scroll', () => { C.stick = C.nearBottom(80); }, { passive: true });
    C.mounted = true;
    C.updateComposerState();
    if (S.focusComposer) { S.focusComposer = false; setTimeout(() => E.input.focus({ preventScroll: true }), 30); }
    if (S.role === 'host') window.addEventListener('beforeunload', onBeforeUnload);
    setTimeout(() => E.log.setAttribute('aria-live', 'polite'), 400);
  };

  /* ---- scrolling ---- */
  C.nearBottom = (px = 80) => {
    const m = E.messages; if (!m) return true;
    return m.scrollHeight - m.scrollTop - m.clientHeight <= px;
  };
  C.scrollBottom = (smooth = false) => {
    const m = E.messages; if (!m) return;
    m.scrollTo({ top: m.scrollHeight, behavior: smooth && !reducedMotion() ? 'smooth' : 'auto' });
    C.unseen = 0; C.stick = true; C.updatePill();
  };
  C.onScroll = () => { if (C.nearBottom(80)) C.unseen = 0; C.updatePill(); };
  C.updatePill = () => {
    if (!E.pill) return;
    const show = C.unseen > 0 && !C.nearBottom(80);
    E.pill.hidden = !show;
    if (show) E.pill.querySelector('span').textContent = `${C.unseen} new message${C.unseen === 1 ? '' : 's'}`;
  };

  /* ---- header / status ---- */
  C.renderHeader = () => {
    if (!C.mounted) return;
    E.title.textContent = S.roomName;
    const st = S.status.state;
    let text, cls = 'dot';
    if (st === 'connected') {
      text = S.role === 'host'
        ? `Hosting · ${S.peers.connected} connected${S.peers.pending ? ` · ${S.peers.pending} waiting` : ''}`
        : 'Connected';
    } else if (st === 'disconnected') { text = 'Offline'; cls += ' bad'; }
    else { text = 'Reconnecting…'; cls += ' warn'; }
    E.dot.className = cls; E.statusText.textContent = text;
    const users = sortedUsers();
    E.facepile.replaceChildren(...users.slice(0, 3).map((u) => avatar(u, 'sm')));
    E.peopleCount.textContent = `${users.length} online`;
    E.peopleBtn.setAttribute('aria-label', `People, ${users.length} online`);
  };

  C.renderBanners = () => {
    if (!C.mounted) return;
    const st = S.status;
    const items = [];
    if (st.state === 'reconnecting' || st.state === 'connecting') {
      if ((st.detail?.attempt || 0) >= 5) items.push('offline'); else items.push('reconnecting');
    } else if (st.state === 'disconnected') items.push('offline');
    if (S.role === 'host' && !C.hostWarnDismissed && st.state === 'connected') items.push('hostwarn');
    const key = items.join(',');
    if (key === C.bannerKey) return;
    C.bannerKey = key;
    E.banners.replaceChildren(...items.map((k) => {
      if (k === 'reconnecting') return h('div', { class: 'banner warn', role: 'status' }, h('span', { class: 'spin', 'aria-hidden': 'true' }), h('span', { class: 'grow', text: 'Reconnecting… You can keep typing; sending resumes when you are back.' }));
      if (k === 'offline') return h('div', { class: 'banner bad', role: 'status' }, icon('alert'), h('span', { class: 'grow', text: 'You are offline. Trying again every few seconds.' }),
        S.mode === 'server' ? h('button', { class: 'btn', type: 'button', text: 'Retry now', onclick: () => S.t?._reconnectNow?.() }) : null);
      return h('div', { class: 'banner info' }, icon('alert'), h('span', { class: 'grow', text: 'You are hosting. If you close this tab or lock the screen, the chat ends for everyone.' }),
        h('button', { class: 'xbtn', type: 'button', 'aria-label': 'Dismiss', onclick: () => { C.hostWarnDismissed = true; C.bannerKey = ''; C.renderBanners(); } }, icon('x')));
    }));
  };

  /* ---- composer ---- */
  C.updateComposerState = () => {
    if (!C.mounted) return;
    const online = S.status.state === 'connected';
    const len = E.input.value.length;
    const can = online && E.input.value.trim().length > 0 && len <= MAX_TEXT;
    setEnabled(E.send, can);
    E.input.placeholder = online ? 'Message' : 'Waiting to reconnect…';
    if (len >= 1800) {
      E.counter.hidden = false;
      E.counter.className = 'counter' + (len > MAX_TEXT ? ' over' : '');
      E.counter.textContent = `${len.toLocaleString()} / ${MAX_TEXT.toLocaleString()}` + (len > MAX_TEXT ? ' · Message is too long' : '');
    } else E.counter.hidden = true;
  };
  C.autoGrow = () => {
    const t = E.input;
    t.style.height = 'auto';
    const max = parseFloat(getComputedStyle(t).fontSize) * 1.4 * 5 + 18;
    t.style.height = Math.min(t.scrollHeight, max) + 'px';
  };
  C.onInput = () => {
    C.autoGrow(); C.updateComposerState();
    if (E.input.value.trim()) C.typing(true); else C.typing(false);
  };
  C.typing = (on) => {
    clearTimeout(C.typingIdle);
    if (!S.t) return;
    if (on) {
      const now = Date.now();
      if (!C.typingOn || now - C.typingSent > 3000) { S.t.setTyping(true); C.typingOn = true; C.typingSent = now; }
      C.typingIdle = setTimeout(() => C.typing(false), 2000);
    } else if (C.typingOn) { C.typingOn = false; S.t.setTyping(false); }
  };
  C.send = () => {
    const text = E.input.value.trim();
    if (!text || text.length > MAX_TEXT || S.status.state !== 'connected' || !S.t) return;
    const cid = S.t.send(text);
    if (cid == null) return; // not connected: draft stays, an error toast was emitted
    C.typing(false);
    if (!C.echoed.has(cid)) C.addOwnPending(text, cid); // the RTC host is echoed synchronously
    E.input.value = '';
    C.autoGrow(); C.updateComposerState();
    C.scrollBottom();
    E.input.focus({ preventScroll: true });
  };

  /* ---- message log ---- */
  const GROUP_MS = 5 * 60e3, DIV_MS = 30 * 60e3;

  function avatar(u, size = '') {
    const a = h('span', { class: 'av ' + size, 'aria-hidden': 'true', text: initials(u.name) });
    a.style.setProperty('--user', validColor(u.color));
    return a;
  }
  C.avatar = avatar;

  function restyle(li) {
    const stack = li.querySelector('.stack');
    const rows = [...stack.querySelectorAll(':scope > .mrow')];
    rows.forEach((r, i) => {
      const b = r.querySelector('.bubble');
      b.classList.remove('b-first', 'b-mid', 'b-last');
      if (rows.length > 1) b.classList.add(i === 0 ? 'b-first' : i === rows.length - 1 ? 'b-last' : 'b-mid');
    });
    let tm = stack.querySelector(':scope > time');
    if (!tm) { tm = h('time'); }
    stack.append(tm); // keep last
    const ts = Number(li.dataset.lastTs);
    tm.textContent = fmtTime(ts); tm.dateTime = new Date(ts).toISOString();
  }

  function newGroup(m, own) {
    const li = h('li', { class: 'grp' + (own ? ' own' : ''), 'aria-live': own ? 'off' : null });
    li.style.setProperty('--user', validColor(m.color));
    const stack = h('div', { class: 'stack' });
    if (!own) {
      li.append(avatar(m));
      stack.append(h('div', { class: 'who', text: m.name }));
    }
    li.append(stack);
    return li;
  }

  function insertItem(m, own, build, { initial = false } = {}) {
    const wasNear = C.nearBottom(80);
    const ts = m.ts || Date.now();
    // divider
    if (C.count > 0 && C.lastTs && (ts - C.lastTs > DIV_MS || dayStart(ts) !== dayStart(C.lastTs))) {
      E.log.append(h('li', { class: 'dv', role: 'separator' }, fmtDivider(ts)));
      C.last = null;
    }
    let li = null;
    if (C.last && C.last.userId === m.userId && ts - C.last.ts < GROUP_MS && E.log.lastElementChild === C.last.li) li = C.last.li;
    const fresh = !li;
    if (!li) li = newGroup(m, own);
    const entry = build(li);
    li.dataset.lastTs = String(ts);
    if (fresh) E.log.append(li);
    restyle(li);
    C.last = { userId: m.userId, ts, li };
    C.lastTs = ts; C.count++;
    C.sysLast = null;
    if (initial) li.classList.add('old');
    return { entry, wasNear, li };
  }

  function makeRow(m, own, { pending = false } = {}) {
    const bubble = h('div', { class: 'bubble' + (pending ? ' pending' : ''), dir: 'auto' });
    bubble.textContent = m.text;
    const row = h('div', { class: 'mrow' }, own ? null : h('span', { class: 'sr', text: `${m.name}, ${fmtTime(m.ts || Date.now())}:` }), bubble);
    return { row, bubble };
  }

  C.onMessage = (m) => {
    if (!C.mounted) return;
    C.addMessage(m, false);
    // someone who sent a message is no longer typing
    C.dropTyper(m.userId);
  };

  C.addMessage = (m, initial) => {
    if (m.id && C.seen.has(m.id)) return;
    const own = m.userId === S.selfId;
    if (own) {
      if (m.cid) { C.echoed.add(m.cid); if (C.echoed.size > 50) C.echoed.delete(C.echoed.values().next().value); }
      let e = m.cid ? C.pend.get(m.cid) : null;
      if (!e) for (const x of C.pend.values()) if (x.text === m.text) { e = x; break; }
      if (e) { C.confirm(e, m); return; }
    }
    if (m.id) C.seen.add(m.id);
    const { wasNear, li } = insertItem(m, own, (li2) => {
      const { row } = makeRow(m, own);
      li2.querySelector('.stack').append(row);
      return row;
    }, { initial });
    afterAppend(own, wasNear, initial);
  };

  function afterAppend(own, wasNear, initial) {
    C.renderEmpty();
    if (initial || own || wasNear) C.scrollBottom();
    else { C.unseen++; C.updatePill(); }
  }

  C.addOwnPending = (text, cid) => {
    const me = S.users.find((u) => u.id === S.selfId) || { name: S.name, color: '#0B6E75' };
    const m = { userId: S.selfId, name: me.name, color: me.color, text, ts: Date.now() };
    let entry;
    insertItem(m, true, (li) => {
      const { row, bubble } = makeRow(m, true, { pending: true });
      li.querySelector('.stack').append(row);
      entry = { cid, text, row, bubble, li, status: 'pending', ts: m.ts, timer: null, failEl: null };
      return entry;
    });
    entry.timer = setTimeout(() => C.fail(entry), 10000);
    C.pend.set(cid, entry);
    C.renderEmpty();
  };

  C.confirm = (e, m) => {
    clearTimeout(e.timer);
    if (e.cid) C.pend.delete(e.cid);
    e.status = 'sent';
    e.bubble.classList.remove('pending', 'failed');
    e.failEl?.remove(); e.failEl = null;
    if (m.id) C.seen.add(m.id);
    if (m.ts) {
      e.ts = m.ts;
      if (e.li.querySelector('.stack > .mrow:last-of-type') === e.row) { e.li.dataset.lastTs = String(m.ts); restyle(e.li); }
    }
    C.updatePill();
  };

  C.fail = (e) => {
    if (e.status !== 'pending') return;
    clearTimeout(e.timer);
    e.status = 'failed';
    e.bubble.classList.remove('pending'); e.bubble.classList.add('failed');
    e.failEl = h('button', { class: 'fail-line', type: 'button', onclick: () => C.retry(e) }, icon('alert'), 'Not sent. Tap to try again.');
    e.row.append(e.failEl);
    announce('Message not sent.');
  };

  C.retry = (e) => {
    if (S.status.state !== 'connected' || !S.t) { toast('You are offline. Try again when you are back.', { error: true }); return; }
    const cid = S.t.send(e.text);
    if (cid == null) return;
    C.pend.delete(e.cid);
    e.cid = cid; e.status = 'pending';
    e.bubble.classList.remove('failed'); e.bubble.classList.add('pending');
    e.failEl?.remove(); e.failEl = null;
    e.timer = setTimeout(() => C.fail(e), 10000);
    C.pend.set(cid, e);
  };

  C.applyHistory = (list) => {
    if (!C.mounted) return;
    E.log.setAttribute('aria-live', 'off');
    const wasEmpty = C.count === 0;
    for (const m of list) C.addMessage(m, wasEmpty);
    if (wasEmpty) C.scrollBottom();
    setTimeout(() => E.log && E.log.setAttribute('aria-live', 'polite'), 300);
  };

  /* ---- system lines ---- */
  C.onSystem = (e) => {
    if (e.error) {
      toast(e.text, { error: true });
      // mark the newest in-flight message as failed
      let latest = null;
      for (const x of C.pend.values()) if (x.status === 'pending') latest = x;
      if (latest) C.fail(latest);
      return;
    }
    C.addSystem(e.text);
  };

  C.addSystem = (text) => {
    if (!C.mounted) return;
    const wasNear = C.nearBottom(80);
    const mt = /^(.+) (joined|left)$/.exec(text);
    const now = Date.now();
    if (mt && C.sysLast && C.sysLast.verb === mt[2] && now - C.sysLast.t < 15000 && E.log.lastElementChild === C.sysLast.li) {
      C.sysLast.names.push(mt[1]); C.sysLast.t = now;
      const n = C.sysLast.names;
      const who = n.length === 1 ? n[0] : n.length === 2 ? `${n[0]} and ${n[1]}` : n.length === 3 ? `${n[0]}, ${n[1]} and ${n[2]}` : `${n[0]}, ${n[1]} and ${n.length - 2} others`;
      C.sysLast.p.textContent = `${who} ${mt[2]}`;
    } else {
      const p = h('p', { class: 'sys', text });
      const li = h('li', { class: 'sysl' }, p);
      E.log.append(li);
      C.sysLast = mt ? { verb: mt[2], names: [mt[1]], li, p, t: now } : null;
    }
    C.last = null;
    if (wasNear) C.scrollBottom(); else C.updatePill();
  };

  /* ---- typing ---- */
  C.onTyping = ({ userId, name, typing }) => {
    if (!C.mounted || userId === S.selfId) return;
    if (!typing) { C.dropTyper(userId); return; }
    const old = C.typers.get(userId);
    if (old) clearTimeout(old.timer);
    C.typers.set(userId, { name, timer: setTimeout(() => C.dropTyper(userId), 5000) });
    C.renderTyping();
  };
  C.dropTyper = (userId) => {
    const t = C.typers.get(userId);
    if (!t) return;
    clearTimeout(t.timer); C.typers.delete(userId); C.renderTyping();
  };
  C.renderTyping = () => {
    if (!E.typing) return;
    const names = [...C.typers.values()].map((t) => t.name);
    E.typing.hidden = names.length === 0;
    E.typingText.textContent = names.length === 0 ? '' : names.length === 1 ? `${names[0]} is typing`
      : names.length === 2 ? `${names[0]} and ${names[1]} are typing` : 'Several people are typing';
    if (names.length && C.stick) C.scrollBottom();
  };

  /* ---- people ---- */
  function sortedUsers() {
    return [...S.users].sort((a, b) => {
      const ra = a.id === S.selfId ? 0 : a.isHost ? 1 : 2, rb = b.id === S.selfId ? 0 : b.isHost ? 1 : 2;
      return ra - rb || a.name.localeCompare(b.name);
    });
  }

  function fillPeople(box, { inDialog = false } = {}) {
    const users = sortedUsers();
    const list = h('ul', { class: 'plist' }, users.map((u) => {
      const row = h('li', { class: 'prow' }, avatar(u, 'lg'),
        h('span', { class: 'nm', text: u.name }),
        u.isHost ? h('span', { class: 'chip host', text: 'Host' }) : null,
        u.id === S.selfId ? h('span', { class: 'chip you', text: 'You' }) : null);
      return row;
    }));
    const foot = h('div', { class: 'sb-foot' });
    if (S.role === 'host') {
      foot.append(btn('Add another person', { kind: 'secondary', ic: 'userplus', block: true, onclick: () => { closeDialog(true); openPairing(); } }),
        btn('End chat for everyone', { kind: 'danger', block: true, onclick: () => endChatConfirm() }));
    } else {
      if (S.role === 'server' && S.info?.addresses?.length) {
        foot.append(h('p', { class: 'help', text: 'Others can join at:' }),
          h('div', { class: 'addr-list' }, S.info.addresses.map((a) => addrRow(a))));
      }
      foot.append(btn('Leave chat', { kind: 'danger', block: true, onclick: () => leaveConfirm() }));
    }
    const head = !inDialog ? h('div', { class: 'sb-head', text: `People · ${users.length}` }) : null;
    box.replaceChildren(...[head, list, foot].filter(Boolean));
    box.dataset.dialog = inDialog ? '1' : '';
  }
  C.renderPeople = () => {
    for (const box of C.people) if (box.isConnected) fillPeople(box, { inDialog: box.dataset.dialog === '1' });
    if (dlgPeople) dlgPeople.setTitle(`People · ${S.users.length}`);
  };

  let dlgPeople = null;
  function openPeople() {
    const d = openDialog({ cls: 'people', title: `People · ${S.users.length}`, onClose: () => { C.people.delete(box); dlgPeople = null; } });
    const box = d.body; box.dataset.dialog = '1';
    C.people.add(box); dlgPeople = d;
    fillPeople(box, { inDialog: true });
  }

  /* ---- empty state ---- */
  C.renderEmpty = () => {
    if (!E.empty) return;
    const show = C.count === 0;
    E.empty.hidden = !show;
    if (!show) { E.empty.replaceChildren(); E.empty.dataset.k = ''; return; }
    const alone = S.users.length <= 1;
    const key = `${alone}|${S.role}`;
    if (E.empty.dataset.k === key) return;
    E.empty.dataset.k = key;
    E.empty.replaceChildren(...[
      h('div', { class: 'ico' }, icon('chat')),
      h('h3', { text: alone ? "You're the first one here" : 'No messages yet' }),
      h('p', { text: alone ? 'Say hello, or invite someone to join.' : 'Say hello to get things started.' }),
      S.role === 'host' ? btn('Add a person', { kind: 'primary', ic: 'userplus', onclick: openPairing }) : null,
      S.role === 'server' && S.info?.addresses?.[0] ? h('div', null, h('p', { class: 'help', text: 'Open this address on another device:' }), addrRow(S.info.addresses[0])) : null].filter(Boolean));
  };

  function addrRow(a) {
    const b = h('button', { class: 'btn secondary', type: 'button', 'aria-label': `Copy ${a}` }, 'Copy');
    b.addEventListener('click', async () => {
      const ok = await copyText(a);
      if (ok) { b.textContent = 'Copied'; announce('Address copied'); setTimeout(() => { b.textContent = 'Copy'; }, 2000); }
      else toast('Could not copy. Select the address and copy it by hand.', { error: true });
    });
    return h('div', { class: 'addr' }, h('span', { text: a }), b);
  }

  return C;
})();

async function endChatConfirm() {
  const ok = await confirmDialog({ title: 'End the chat?', text: 'Everyone will be disconnected. Messages are not saved.', confirmLabel: 'End chat for everyone', danger: true });
  if (ok) leaveChat();
}
async function leaveConfirm() {
  const ok = await confirmDialog({ title: 'Leave this chat?', text: 'You can join again later.', confirmLabel: 'Leave chat' });
  if (ok) leaveChat();
}

/* ================================================================== */
/* Boot                                                                */
/* ================================================================== */

async function probeServer() {
  if (!/^https?:$/.test(location.protocol)) return null;
  const ctl = new AbortController();
  const to = setTimeout(() => ctl.abort(), 2500);
  try {
    const r = await fetch('api/info', { signal: ctl.signal, cache: 'no-store' });
    if (!r.ok) return null;
    const j = await r.json();
    return j && j.app === 'lan-chat' ? j : null;
  } catch { return null; } finally { clearTimeout(to); }
}

async function boot() {
  rootEl.replaceChildren(screenEl, overlayEl, toastsEl);
  const info = await probeServer();
  let hash = location.hash || '';
  try { hash = decodeURIComponent(hash); } catch { /* keep raw */ }
  const m = /LC[01]\.[A-Za-z0-9_-]+/.exec(hash);
  if (info) {
    S.mode = 'server'; S.info = info;
    showName();
  } else {
    S.mode = 'rtc';
    if (m) {
      try { history.replaceState(null, '', location.pathname + location.search); } catch { /* ignore */ }
      showGuestJoin({ invite: m[0] });
    } else showStart();
  }
  if ('serviceWorker' in navigator && /^https?:$/.test(location.protocol)) {
    const reg = () => navigator.serviceWorker.register('sw.js').catch(() => {});
    if (document.readyState === 'complete') reg(); else window.addEventListener('load', reg);
  }
}

boot();
