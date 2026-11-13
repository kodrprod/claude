// transport-ws.js - Mode A transport: WebSocket to the Node server.
//
// createWsTransport({ url? }) -> transport (see SPEC "Transport interface").
//   connect({ name })  Promise<void>, resolves on first 'welcome'. If the server is
//                      unreachable it keeps retrying (status 'reconnecting'); the
//                      promise rejects only if close() is called first.
//   send(text)         returns the client temp id (cid) that the server will echo on
//                      our own 'message' event, or null when not connected.
//   setTyping(bool), close(), selfId
// Events: welcome, message (own echoes carry `cid`), presence, typing,
//         system ({text, error?}), status ({state, detail?}).

import { Emitter, Msg, parseWire, wireToEvents, uid } from './protocol.js';

const PING_MS = 15_000;
const STALE_MS = 40_000;       // no frame from the server this long => connection is dead
const OPEN_TIMEOUT_MS = 8_000;

export class WsTransport extends Emitter {
  constructor(url) {
    super();
    this.url = url || `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`;
    this.selfId = null;
    this.name = '';
    this.rid = uid(16);          // stable across reconnects so the server can swap the stale session
    this.ws = null;
    this.attempt = 0;
    this.userClosed = false;
    this.lastRx = 0;
    this._timers = { retry: null, ping: null, open: null };
    this._joined = null;         // { resolve, reject } for connect()
    this._typing = false;
    this._onWake = () => {
      if (this.userClosed || (typeof document !== 'undefined' && document.visibilityState === 'hidden')) return;
      if (!this.ws || this.ws.readyState > 1) this._reconnectNow();      // CLOSING/CLOSED
      else if (this.ws.readyState === 1) this.ws.send(JSON.stringify(Msg.ping())); // probe a maybe-stale socket
    };
  }

  connect({ name } = {}) {
    if (name) this.name = name;
    this.userClosed = false;
    const p = new Promise((resolve, reject) => { this._joined = { resolve, reject }; });
    if (typeof document !== 'undefined') document.addEventListener('visibilitychange', this._onWake);
    if (typeof window !== 'undefined') window.addEventListener('online', this._onWake);
    this._open();
    return p;
  }

  send(text) {
    if (!this.ws || this.ws.readyState !== 1 || !this.selfId) {
      this.emit('system', { text: 'Not connected - message not sent', error: true });
      return null;
    }
    const cid = uid(10);
    this.ws.send(JSON.stringify(Msg.msg(String(text), cid)));
    return cid;
  }

  setTyping(typing) {
    typing = !!typing;
    if (typing === this._typing) return;
    this._typing = typing;
    if (this.ws && this.ws.readyState === 1 && this.selfId) this.ws.send(JSON.stringify(Msg.typing(typing)));
  }

  close() {
    this.userClosed = true;
    this._clearTimers();
    if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', this._onWake);
    if (typeof window !== 'undefined') window.removeEventListener('online', this._onWake);
    if (this._joined) { this._joined.reject(new Error('closed')); this._joined = null; }
    const ws = this.ws; this.ws = null;
    try { ws?.close(1000); } catch { /* ignore */ }
    this.selfId = null;
    this.emit('status', { state: 'disconnected' });
  }

  /* ---- internals ---- */

  _clearTimers() {
    for (const k of Object.keys(this._timers)) { clearTimeout(this._timers[k]); clearInterval(this._timers[k]); this._timers[k] = null; }
  }

  _open() {
    clearTimeout(this._timers.retry);
    this.emit('status', this.attempt === 0 ? { state: 'connecting' } : { state: 'reconnecting', detail: { attempt: this.attempt } });
    let ws;
    try { ws = new WebSocket(this.url); } catch (e) { return this._scheduleRetry(); }
    this.ws = ws;
    this._timers.open = setTimeout(() => { if (ws.readyState === 0) ws.close(); }, OPEN_TIMEOUT_MS);
    ws.onopen = () => {
      clearTimeout(this._timers.open);
      this.lastRx = Date.now();
      ws.send(JSON.stringify(Msg.hello(this.name, this.rid)));
      clearInterval(this._timers.ping);
      this._timers.ping = setInterval(() => {
        if (Date.now() - this.lastRx > STALE_MS) return ws.close(); // triggers onclose -> reconnect
        if (ws.readyState === 1) ws.send(JSON.stringify(Msg.ping()));
      }, PING_MS);
    };
    ws.onmessage = (ev) => {
      this.lastRx = Date.now();
      const o = parseWire(ev.data);
      if (!o) return;
      if (o.t === 'welcome') {
        this.selfId = o.selfId;
        this.attempt = 0;
        this._typing = false;
        this.emit('status', { state: 'connected' });
        if (this._joined) { this._joined.resolve(); this._joined = null; }
      }
      wireToEvents(this, o);
    };
    ws.onclose = () => {
      if (this.ws !== ws) return; // superseded
      clearInterval(this._timers.ping); clearTimeout(this._timers.open);
      this.ws = null; this.selfId = null;
      if (!this.userClosed) this._scheduleRetry();
    };
    ws.onerror = () => { /* onclose follows */ };
  }

  _scheduleRetry() {
    this.attempt++;
    const delay = Math.min(10_000, 500 * 2 ** (this.attempt - 1)) * (0.8 + Math.random() * 0.4);
    this.emit('status', { state: 'reconnecting', detail: { attempt: this.attempt, delayMs: Math.round(delay) } });
    clearTimeout(this._timers.retry);
    this._timers.retry = setTimeout(() => this._open(), delay);
  }

  _reconnectNow() {
    clearTimeout(this._timers.retry);
    const old = this.ws; this.ws = null;
    try { old?.close(); } catch { /* ignore */ }
    this.attempt = Math.max(this.attempt, 1);
    this._open();
  }
}

export function createWsTransport({ url } = {}) { return new WsTransport(url); }
