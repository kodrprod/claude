// protocol.js - shared by the browser (transports) and the Node server.
// Pure ES module: no DOM / Node APIs except guarded CompressionStream, btoa, crypto.
//
// Exports:
//   constants      MAX_TEXT, MAX_NAME, MAX_HISTORY, COLORS
//   Emitter        tiny on/off/once/emit event emitter (transports extend it)
//   uid(len)       random id
//   Msg, parseWire, wireToEvents, chunkWire, WireReader   wire-format helpers
//   HubCore        the chat room logic (users, names, colors, history, validation, rate limit)
//   encodeCode / decodeCode   pairing codes ("LC1." deflate-raw+base64url, "LC0." plain)

export const MAX_TEXT = 2000;
export const MAX_NAME = 24;
export const MAX_HISTORY = 200;

// Fixed palette; HubCore hands out the least-used colour first.
export const COLORS = [
  '#E5484D', '#F76B15', '#C79A00', '#30A46C', '#12A594', '#0091FF',
  '#3E63DD', '#8E4EC6', '#D6409F', '#A18072', '#6E56CF', '#00A2C7',
];

/* ------------------------------------------------------------------ */
/* Emitter + ids                                                       */
/* ------------------------------------------------------------------ */

export class Emitter {
  constructor() { this._h = new Map(); }
  /** Subscribe. Returns an unsubscribe function for convenience. */
  on(type, fn) {
    if (!this._h.has(type)) this._h.set(type, new Set());
    this._h.get(type).add(fn);
    return () => this.off(type, fn);
  }
  off(type, fn) { this._h.get(type)?.delete(fn); }
  once(type, fn) {
    const w = (p) => { this.off(type, w); fn(p); };
    return this.on(type, w);
  }
  emit(type, payload) {
    const set = this._h.get(type);
    if (!set) return;
    for (const fn of [...set]) {
      try { fn(payload); } catch (e) { console.error(`[emitter] handler for "${type}" threw`, e); }
    }
  }
}

const ID_ALPHABET = '0123456789abcdefghijklmnopqrstuvwxyz';
/** Random lowercase-alphanumeric id. Uses WebCrypto when present. */
export function uid(len = 10) {
  const bytes = new Uint8Array(len);
  const c = globalThis.crypto;
  if (c && typeof c.getRandomValues === 'function') c.getRandomValues(bytes);
  else for (let i = 0; i < len; i++) bytes[i] = Math.floor(Math.random() * 256);
  let out = '';
  for (let i = 0; i < len; i++) out += ID_ALPHABET[bytes[i] % ID_ALPHABET.length];
  return out;
}

/* ------------------------------------------------------------------ */
/* Wire format helpers                                                 */
/* ------------------------------------------------------------------ */

/** Builders for client -> host messages. */
export const Msg = {
  // `rid` is an optional stable per-client "resume id": a hello carrying the
  // same rid as a live user replaces that user (clean reconnects, no "Anna 2").
  hello: (name, rid) => (rid ? { t: 'hello', name, rid } : { t: 'hello', name }),
  msg: (text, cid) => ({ t: 'msg', text, cid }),
  typing: (typing) => ({ t: 'typing', typing: !!typing }),
  ping: () => ({ t: 'ping' }),
};

/** Parse a JSON wire string. Returns an object with a string `t`, else null. */
export function parseWire(str) {
  if (typeof str !== 'string') return null;
  let o;
  try { o = JSON.parse(str); } catch { return null; }
  if (!o || typeof o !== 'object' || Array.isArray(o) || typeof o.t !== 'string') return null;
  return o;
}

/**
 * Translate a host->client wire object into transport events on `emitter`.
 *   welcome -> 'welcome' {selfId, users, history, roomName}
 *   msg     -> 'message' ChatMsg (+ cid when it is our own echo)
 *   presence-> 'presence' {users}     typing -> 'typing' {userId,name,typing}
 *   system  -> 'system' {text}        error  -> 'system' {text, error:true}
 * pong is swallowed. Returns the wire object's `t`.
 */
export function wireToEvents(emitter, o) {
  switch (o.t) {
    case 'welcome':
      emitter.emit('welcome', { selfId: o.selfId, users: o.users || [], history: o.history || [], roomName: o.roomName });
      break;
    case 'msg': {
      const { t, ...m } = o; // keeps cid if the server echoed one
      emitter.emit('message', m);
      break;
    }
    case 'presence': emitter.emit('presence', { users: o.users || [] }); break;
    case 'typing': emitter.emit('typing', { userId: o.userId, name: o.name, typing: !!o.typing }); break;
    case 'system': emitter.emit('system', { text: String(o.text ?? '') }); break;
    case 'error': emitter.emit('system', { text: String(o.text ?? 'Error'), error: true }); break;
    default: break; // pong, unknown
  }
  return o.t;
}

/**
 * DataChannels have small message limits (esp. Safari), and a welcome with a
 * full history can reach hundreds of KB. Split big wire strings into
 * {t:'chunk', id, i, n, d} envelopes. Never splits a surrogate pair.
 */
export function chunkWire(str, max = 16000) {
  if (str.length <= max) return [str];
  const parts = [];
  for (let pos = 0; pos < str.length;) {
    let end = Math.min(pos + max, str.length);
    const code = str.charCodeAt(end - 1);
    if (end < str.length && code >= 0xd800 && code <= 0xdbff) end--; // don't cut a pair
    parts.push(str.slice(pos, end));
    pos = end;
  }
  const id = uid(6);
  return parts.map((d, i) => JSON.stringify({ t: 'chunk', id, i, n: parts.length, d }));
}

/** Reassembles chunkWire output; calls onMessage(obj) for each complete wire object. */
export class WireReader {
  constructor(onMessage) { this.onMessage = onMessage; this.partial = new Map(); }
  feed(str) {
    const o = parseWire(str);
    if (!o) return;
    if (o.t !== 'chunk') return this.onMessage(o);
    if (!Number.isInteger(o.n) || o.n < 1 || o.n > 128 || !Number.isInteger(o.i) || o.i < 0 || o.i >= o.n) return;
    let p = this.partial.get(o.id);
    if (!p) {
      if (this.partial.size >= 4) this.partial.delete(this.partial.keys().next().value); // drop oldest
      p = { n: o.n, parts: new Array(o.n), got: 0 };
      this.partial.set(o.id, p);
    }
    if (p.parts[o.i] === undefined) { p.parts[o.i] = String(o.d); p.got++; }
    if (p.got === p.n) {
      this.partial.delete(o.id);
      const full = parseWire(p.parts.join(''));
      if (full) this.onMessage(full);
    }
  }
}

/* ------------------------------------------------------------------ */
/* HubCore - the chat room                                             */
/* ------------------------------------------------------------------ */

const CTRL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F  ]/g;

export function sanitizeName(raw) {
  if (typeof raw !== 'string') return '';
  return raw.replace(CTRL, ' ').replace(/\s+/g, ' ').trim().slice(0, MAX_NAME).trim();
}

/**
 * Transport-agnostic room logic, used by the Node server and the browser RTC host.
 *
 * A "conn" is any object `{ send(obj), close?() }` representing one participant's
 * link. The hub sets `conn.userId` once the participant has said hello; set
 * `conn.isHost = true` on the host's own local conn (client-sent claims are ignored).
 *
 *   hub.handle(conn, wireObj)   feed a parsed client message
 *   hub.drop(conn)              the link went away (broadcasts leave + presence)
 */
export class HubCore {
  constructor({
    roomName = 'LAN Chat', history = [], maxHistory = MAX_HISTORY, now = Date.now,
    onHistoryChange = null, rateMax = 10, rateWindowMs = 5000, typingTtlMs = 8000,
  } = {}) {
    this.roomName = roomName;
    this.maxHistory = maxHistory;
    this.now = now;
    this.onHistoryChange = onHistoryChange;
    this.rateMax = rateMax;
    this.rateWindowMs = rateWindowMs;
    this.typingTtlMs = typingTtlMs;
    this.history = history.slice(-maxHistory);
    this.entries = new Map(); // userId -> { user, conn, rid, stamps[], typing, typingTimer }
  }

  /** Public User[] list (copies). */
  get users() { return [...this.entries.values()].map((e) => ({ ...e.user })); }

  handle(conn, o) {
    if (!o || typeof o !== 'object' || typeof o.t !== 'string') return this._error(conn, 'Bad message');
    const entry = conn.userId ? this.entries.get(conn.userId) : null;
    if (o.t === 'ping') return this._send(conn, { t: 'pong' });
    if (o.t === 'hello') return entry ? this._rename(entry, o.name) : this._join(conn, o);
    if (!entry) return this._error(conn, 'Send "hello" first');
    if (o.t === 'msg') return this._chat(entry, o);
    if (o.t === 'typing') return this._setTyping(entry, !!o.typing);
    return this._error(conn, 'Unknown message type');
  }

  drop(conn) {
    const entry = conn.userId ? this.entries.get(conn.userId) : null;
    if (entry) this._remove(entry, { announce: true });
  }

  /* ---- internals ---- */

  _send(conn, obj) { try { conn.send(obj); } catch { /* dead link; its owner will call drop() */ } }
  _error(conn, text) { this._send(conn, { t: 'error', text }); }
  _broadcast(obj, exceptId) {
    for (const [id, e] of this.entries) if (id !== exceptId) this._send(e.conn, obj);
  }
  _presence() { this._broadcast({ t: 'presence', users: this.users }); }

  _uniqueName(base, exceptId) {
    const taken = new Set();
    for (const [id, e] of this.entries) if (id !== exceptId) taken.add(e.user.name.toLowerCase());
    if (!taken.has(base.toLowerCase())) return base;
    for (let n = 2; ; n++) {
      const suffix = ' ' + n;
      const cand = base.slice(0, MAX_NAME - suffix.length).trimEnd() + suffix;
      if (!taken.has(cand.toLowerCase())) return cand;
    }
  }

  _pickColor() {
    const use = new Map(COLORS.map((c) => [c, 0]));
    for (const e of this.entries.values()) use.set(e.user.color, (use.get(e.user.color) || 0) + 1);
    let best = COLORS[0];
    for (const c of COLORS) if (use.get(c) < use.get(best)) best = c;
    return best;
  }

  _join(conn, o) {
    const rid = typeof o.rid === 'string' && o.rid.length <= 64 ? o.rid : null;
    // Same resume id => this is a reconnect; quietly replace the stale session.
    let resumed = false;
    if (rid) {
      for (const e of [...this.entries.values()]) {
        if (e.rid === rid && e.conn !== conn) {
          this._remove(e, { announce: false });
          try { e.conn.close?.(); } catch { /* ignore */ }
          resumed = true;
        }
      }
    }
    const name = this._uniqueName(sanitizeName(o.name) || 'Guest');
    const user = { id: uid(8), name, color: this._pickColor(), isHost: conn.isHost === true };
    conn.userId = user.id;
    this.entries.set(user.id, { user, conn, rid, stamps: [], typing: false, typingTimer: null });
    this._send(conn, { t: 'welcome', selfId: user.id, users: this.users, history: this.history, roomName: this.roomName });
    this._presence();
    if (!resumed) this._broadcast({ t: 'system', text: `${name} joined` }, user.id);
  }

  _rename(entry, rawName) {
    const clean = sanitizeName(rawName);
    if (!clean) return;
    const name = this._uniqueName(clean, entry.user.id);
    if (name === entry.user.name) return;
    const old = entry.user.name;
    entry.user.name = name;
    this._broadcast({ t: 'system', text: `${old} is now ${name}` });
    this._presence();
  }

  _chat(entry, o) {
    const conn = entry.conn;
    if (typeof o.text !== 'string') return this._error(conn, 'Message must be text');
    const text = o.text.replace(/\r\n?/g, '\n').replace(CTRL, '').trim();
    if (!text) return this._error(conn, 'Message is empty');
    if (text.length > MAX_TEXT) return this._error(conn, `Message too long (max ${MAX_TEXT} characters)`);
    const t = this.now();
    entry.stamps = entry.stamps.filter((s) => t - s < this.rateWindowMs);
    if (entry.stamps.length >= this.rateMax) return this._error(conn, 'Slow down - too many messages');
    entry.stamps.push(t);

    const msg = { id: uid(12), userId: entry.user.id, name: entry.user.name, color: entry.user.color, text, ts: t };
    this.history.push(msg);
    if (this.history.length > this.maxHistory) this.history.splice(0, this.history.length - this.maxHistory);
    this.onHistoryChange?.(this.history);

    if (entry.typing) this._setTyping(entry, false);
    const cid = typeof o.cid === 'string' && o.cid.length <= 64 ? o.cid : undefined;
    for (const [id, e] of this.entries) {
      this._send(e.conn, id === entry.user.id && cid ? { t: 'msg', ...msg, cid } : { t: 'msg', ...msg });
    }
  }

  _setTyping(entry, typing) {
    clearTimeout(entry.typingTimer);
    entry.typingTimer = null;
    if (typing) {
      // Safety net: if the client never says "stopped", clear it ourselves.
      entry.typingTimer = setTimeout(() => this._setTyping(entry, false), this.typingTtlMs);
      entry.typingTimer.unref?.();
    }
    if (entry.typing === typing) return;
    entry.typing = typing;
    this._broadcast({ t: 'typing', userId: entry.user.id, name: entry.user.name, typing }, entry.user.id);
  }

  _remove(entry, { announce }) {
    clearTimeout(entry.typingTimer);
    this.entries.delete(entry.user.id);
    entry.conn.userId = null;
    if (entry.typing) this._broadcast({ t: 'typing', userId: entry.user.id, name: entry.user.name, typing: false });
    if (announce) this._broadcast({ t: 'system', text: `${entry.user.name} left` });
    this._presence();
  }
}

/* ------------------------------------------------------------------ */
/* Pairing codes (WebRTC mode)                                         */
/* ------------------------------------------------------------------ */

function bytesToB64u(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64uToBytes(s) {
  let b = s.replace(/-/g, '+').replace(/_/g, '/');
  while (b.length % 4) b += '=';
  const bin = atob(b);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function runStream(bytes, stream) {
  const piped = new Blob([bytes]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(piped).arrayBuffer());
}

/**
 * Object -> shareable text. "LC1." + base64url(deflate-raw(JSON)); falls back to
 * "LC0." + base64url(JSON) when CompressionStream is unavailable.
 */
export async function encodeCode(obj) {
  const raw = new TextEncoder().encode(JSON.stringify(obj));
  if (typeof CompressionStream === 'function') {
    try { return 'LC1.' + bytesToB64u(await runStream(raw, new CompressionStream('deflate-raw'))); } catch { /* fall through */ }
  }
  return 'LC0.' + bytesToB64u(raw);
}

/**
 * Inverse of encodeCode. Tolerant of whitespace/line-wrapping, quotes, and
 * links like "https://x/#LC1.abc". Throws Error with a user-presentable message.
 */
export async function decodeCode(code) {
  const m = /LC([01])\.([A-Za-z0-9_-]+)/.exec(String(code ?? '').replace(/\s+/g, ''));
  if (!m) throw new Error('That does not look like a pairing code (it should start with LC1.)');
  try {
    let bytes = b64uToBytes(m[2]);
    if (m[1] === '1') {
      if (typeof DecompressionStream !== 'function') throw new Error('This browser cannot read compressed codes');
      bytes = await runStream(bytes, new DecompressionStream('deflate-raw'));
    }
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch (e) {
    if (/cannot read compressed/.test(e.message)) throw e;
    throw new Error('The pairing code is damaged or incomplete - copy it again in full');
  }
}
