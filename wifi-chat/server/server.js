// LAN Chat server - zero dependencies, Node >= 18.
//   * static file server for ../public
//   * GET /api/info
//   * hand-written RFC 6455 WebSocket endpoint at /ws, feeding the shared HubCore
//
// Env: PORT (8080), ROOM_NAME ("LAN Chat"), HISTORY_FILE (server/history.json),
//      ALLOWED_ORIGINS (comma list of extra Origins allowed to open the WebSocket)

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { HubCore, MAX_HISTORY } from '../public/protocol.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_PAYLOAD = 64 * 1024;   // largest frame / reassembled message we accept
const HEARTBEAT_MS = 10_000;     // how often we ping and sweep
const SILENT_LIMIT_MS = 30_000;  // drop clients that sent nothing (not even a pong) this long
const MAX_CLIENTS = 200;

/* ------------------------------------------------------------------ */
/* WebSocket connection (server side)                                  */
/* ------------------------------------------------------------------ */

class WsConnection {
  constructor(socket, { onMessage, onClose }) {
    this.socket = socket;
    this.onMessage = onMessage;
    this.onClose = onClose;
    this.buf = Buffer.alloc(0);
    this.frag = null;          // { chunks: Buffer[], size } while a fragmented text message is in flight
    this.closing = false;      // we have sent / received a close frame
    this.closed = false;
    this.lastSeen = Date.now();
    socket.setNoDelay(true);
    socket.on('data', (d) => this._onData(d));
    socket.on('error', () => socket.destroy());
    socket.on('close', () => this._finish());
  }

  sendText(str) { this._write(0x1, Buffer.from(str, 'utf8')); }
  ping() { this._write(0x9, Buffer.alloc(0)); }

  /** Send a close frame, then end the TCP stream (destroy if the peer never answers). */
  close(code = 1000, reason = '') {
    if (this.closing || this.closed) return;
    this.closing = true;
    const r = Buffer.from(reason, 'utf8').subarray(0, 100);
    const payload = Buffer.alloc(2 + r.length);
    payload.writeUInt16BE(code, 0);
    r.copy(payload, 2);
    this._write(0x8, payload);
    this.socket.end();
    setTimeout(() => this.socket.destroy(), 2000).unref();
  }

  terminate() { this.socket.destroy(); }

  _write(opcode, payload) {
    if (this.closed || this.socket.destroyed || !this.socket.writable) return;
    // A client that doesn't read lets our buffer grow without bound: cut it off.
    if (this.socket.writableLength > 4 * 1024 * 1024) return this.terminate();
    const len = payload.length;
    let head;
    if (len < 126) { head = Buffer.alloc(2); head[1] = len; }
    else if (len < 65536) { head = Buffer.alloc(4); head[1] = 126; head.writeUInt16BE(len, 2); }
    else { head = Buffer.alloc(10); head[1] = 127; head.writeBigUInt64BE(BigInt(len), 2); }
    head[0] = 0x80 | opcode; // FIN + opcode; server frames are never masked
    this.socket.write(Buffer.concat([head, payload]));
  }

  _fail(code, reason) { this.close(code, reason); this.buf = Buffer.alloc(0); }

  _onData(chunk) {
    if (this.closing) return; // ignore everything after close
    this.lastSeen = Date.now();
    this.buf = this.buf.length ? Buffer.concat([this.buf, chunk]) : chunk;
    // Parse as many complete frames as the buffer holds.
    while (!this.closing && this.buf.length >= 2) {
      const b0 = this.buf[0], b1 = this.buf[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let off = 2;
      if (b0 & 0x70) return this._fail(1002, 'reserved bits set');
      if (!masked) return this._fail(1002, 'client frames must be masked');
      if (len === 126) {
        if (this.buf.length < 4) return;
        len = this.buf.readUInt16BE(2); off = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return;
        const big = this.buf.readBigUInt64BE(2);
        if (big > BigInt(MAX_PAYLOAD)) return this._fail(1009, 'message too big');
        len = Number(big); off = 10;
      }
      if (len > MAX_PAYLOAD) return this._fail(1009, 'message too big'); // reject before buffering the body
      if (opcode >= 0x8 && (len > 125 || !fin)) return this._fail(1002, 'bad control frame');
      if (this.buf.length < off + 4 + len) return; // wait for the rest
      const mask = this.buf.subarray(off, off + 4);
      const payload = Buffer.from(this.buf.subarray(off + 4, off + 4 + len)); // copy, we unmask in place
      for (let i = 0; i < len; i++) payload[i] ^= mask[i & 3];
      this.buf = this.buf.subarray(off + 4 + len);
      this._frame(fin, opcode, payload);
    }
  }

  _frame(fin, opcode, payload) {
    switch (opcode) {
      case 0x0: // continuation
      case 0x1: // text
      case 0x2: { // binary (unsupported)
        if (opcode === 0x2) return this._fail(1003, 'binary not supported');
        if (opcode === 0x1) {
          if (this.frag) return this._fail(1002, 'expected continuation');
          this.frag = { chunks: [], size: 0 };
        } else if (!this.frag) {
          return this._fail(1002, 'unexpected continuation');
        }
        this.frag.chunks.push(payload);
        this.frag.size += payload.length;
        if (this.frag.size > MAX_PAYLOAD) return this._fail(1009, 'message too big');
        if (!fin) return;
        const whole = Buffer.concat(this.frag.chunks);
        this.frag = null;
        let text;
        try { text = new TextDecoder('utf-8', { fatal: true }).decode(whole); }
        catch { return this._fail(1007, 'invalid UTF-8'); }
        this.onMessage(text);
        return;
      }
      case 0x8: { // close: echo the code and finish
        if (payload.length === 1) return this._fail(1002, 'bad close frame');
        const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1000;
        const valid = (code >= 1000 && code <= 1011 && code !== 1004 && code !== 1005 && code !== 1006) || (code >= 3000 && code <= 4999);
        this.close(valid ? code : 1002);
        return;
      }
      case 0x9: this._write(0xa, payload); return; // ping -> pong with same payload
      case 0xa: return;                            // pong: lastSeen already refreshed
      default: this._fail(1002, 'unknown opcode');
    }
  }

  _finish() {
    if (this.closed) return;
    this.closed = true;
    this.onClose();
  }
}

/* ------------------------------------------------------------------ */
/* Static files                                                        */
/* ------------------------------------------------------------------ */

const MIME = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp', '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8', '.map': 'application/json; charset=utf-8',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.wasm': 'application/wasm',
};

/** Map a request pathname to a file inside publicDir, or null if unsafe. */
function resolveSafe(publicDir, pathname) {
  let decoded;
  try { decoded = decodeURIComponent(pathname); } catch { return null; }
  if (decoded.includes('\0') || decoded.includes('\\')) return null;
  if (decoded.endsWith('/')) decoded += 'index.html';
  const segments = decoded.split('/').filter(Boolean);
  if (segments.some((s) => s === '..' || s.startsWith('.'))) return null; // traversal + dotfiles
  const full = path.join(publicDir, ...segments);
  // Belt and braces: the joined path must still live under publicDir.
  if (full !== publicDir && !full.startsWith(publicDir + path.sep)) return null;
  return full;
}

function serveStatic(req, res, publicDir, pathname) {
  const send = (code, body, type = 'text/plain; charset=utf-8') => {
    res.writeHead(code, { 'Content-Type': type, 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-cache' });
    res.end(req.method === 'HEAD' ? undefined : body);
  };
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.setHeader('Allow', 'GET, HEAD');
    return send(405, 'Method Not Allowed');
  }
  const file = resolveSafe(publicDir, pathname);
  if (!file) return send(404, 'Not found');
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) return send(404, 'Not found');
    const lastModified = st.mtime.toUTCString();
    const headers = {
      'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
      'Content-Length': st.size,
      'Cache-Control': 'no-cache',
      'Last-Modified': lastModified,
      'X-Content-Type-Options': 'nosniff',
    };
    const ims = req.headers['if-modified-since'];
    if (ims && Math.floor(Date.parse(ims) / 1000) >= Math.floor(st.mtimeMs / 1000)) {
      res.writeHead(304, { 'Cache-Control': 'no-cache', 'Last-Modified': lastModified });
      return res.end();
    }
    res.writeHead(200, headers);
    if (req.method === 'HEAD') return res.end();
    const stream = fs.createReadStream(file);
    stream.on('error', () => res.destroy());
    stream.pipe(res);
  });
}

/* ------------------------------------------------------------------ */
/* History persistence                                                 */
/* ------------------------------------------------------------------ */

function loadHistory(file) {
  try {
    const arr = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!Array.isArray(arr)) return [];
    return arr
      .filter((m) => m && typeof m.id === 'string' && typeof m.text === 'string' && typeof m.name === 'string' && typeof m.ts === 'number')
      .map((m) => ({ id: m.id, userId: String(m.userId ?? ''), name: m.name, color: String(m.color ?? '#888888'), text: m.text, ts: m.ts }))
      .slice(-MAX_HISTORY);
  } catch { return []; }
}

/** Debounced atomic writer (tmp file + rename). */
function makeHistorySaver(file, getHistory, delayMs = 500) {
  let timer = null;
  const flush = () => {
    clearTimeout(timer); timer = null;
    try {
      fs.writeFileSync(file + '.tmp', JSON.stringify(getHistory()));
      fs.renameSync(file + '.tmp', file);
    } catch (e) { console.error('Could not save history:', e.message); }
  };
  const schedule = () => { if (!timer) { timer = setTimeout(flush, delayMs); timer.unref?.(); } };
  return { schedule, flush, pending: () => timer !== null };
}

/* ------------------------------------------------------------------ */
/* LAN addresses                                                       */
/* ------------------------------------------------------------------ */

function lanAddresses() {
  const out = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list || []) {
      if (a.family === 'IPv4' && !a.internal) out.push({ name, address: a.address });
    }
  }
  return out;
}

/* ------------------------------------------------------------------ */
/* The server                                                          */
/* ------------------------------------------------------------------ */

export function createChatServer({
  port = 8080,
  roomName = 'LAN Chat',
  publicDir = path.resolve(HERE, '..', 'public'),
  historyFile = path.join(HERE, 'history.json'),
  allowedOrigins = [],
} = {}) {
  publicDir = path.resolve(publicDir);
  const hub = new HubCore({ roomName, history: loadHistory(historyFile), onHistoryChange: () => saver.schedule() });
  const saver = makeHistorySaver(historyFile, () => hub.history);
  const clients = new Set(); // WsConnection

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/info') {
      const body = JSON.stringify({
        app: 'lan-chat', roomName, users: hub.users.length,
        addresses: lanAddresses().map((a) => `http://${a.address}:${server.address()?.port ?? port}`),
      });
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(body) });
      return res.end(req.method === 'HEAD' ? undefined : body);
    }
    if (url.pathname === '/ws') { // plain HTTP hit on the WebSocket endpoint
      res.writeHead(426, { 'Content-Type': 'text/plain', Upgrade: 'websocket' });
      return res.end('Upgrade Required');
    }
    if (url.pathname.startsWith('/api/')) {
      res.writeHead(404, { 'Content-Type': 'application/json' });
      return res.end('{"error":"not found"}');
    }
    serveStatic(req, res, publicDir, url.pathname);
  });

  server.on('upgrade', (req, socket) => {
    const reject = (code, text) => { socket.end(`HTTP/1.1 ${code} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); };
    socket.on('error', () => socket.destroy());
    const url = new URL(req.url, 'http://localhost');
    const key = req.headers['sec-websocket-key'];
    if (url.pathname !== '/ws') return reject(404, 'Not Found');
    if (req.method !== 'GET' || String(req.headers.upgrade).toLowerCase() !== 'websocket'
        || !/upgrade/i.test(req.headers.connection || '')
        || req.headers['sec-websocket-version'] !== '13'
        || typeof key !== 'string' || Buffer.from(key, 'base64').length !== 16) return reject(400, 'Bad Request');
    // Cross-site WebSocket hijacking guard: a browser-supplied Origin must be this
    // server itself (or explicitly allowed). Non-browser clients send no Origin.
    const origin = req.headers.origin;
    if (origin) {
      let originHost = null;
      try { originHost = new URL(origin).host; } catch { /* invalid origin */ }
      if (originHost !== req.headers.host && !allowedOrigins.includes(origin)) return reject(403, 'Forbidden');
    }
    if (clients.size >= MAX_CLIENTS) return reject(503, 'Service Unavailable');

    const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
      + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);

    const hubConn = { userId: null, send: (obj) => ws.sendText(JSON.stringify(obj)), close: () => ws.close(1000, 'replaced') };
    const ws = new WsConnection(socket, {
      onMessage(text) {
        let obj;
        try { obj = JSON.parse(text); } catch { return hubConn.send({ t: 'error', text: 'Invalid JSON' }); }
        hub.handle(hubConn, obj);
      },
      onClose() { clients.delete(ws); hub.drop(hubConn); },
    });
    clients.add(ws);
  });

  // Heartbeat: ping everyone, drop those silent for > 30 s.
  const beat = setInterval(() => {
    const t = Date.now();
    for (const ws of clients) {
      if (t - ws.lastSeen > SILENT_LIMIT_MS) ws.terminate();
      else ws.ping();
    }
  }, HEARTBEAT_MS);
  beat.unref();

  return {
    hub, server, saver,
    listen() {
      return new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, '0.0.0.0', () => { server.off('error', reject); resolve(server.address().port); });
      });
    },
    close() {
      clearInterval(beat);
      saver.flush();
      for (const ws of clients) ws.close(1001, 'server shutting down');
      return new Promise((r) => { server.close(() => r()); server.closeIdleConnections?.(); setTimeout(r, 500).unref(); });
    },
  };
}

/* ------------------------------------------------------------------ */
/* CLI entry                                                           */
/* ------------------------------------------------------------------ */

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = process.env.PORT !== undefined ? Number(process.env.PORT) : 8080;
  const app = createChatServer({
    port,
    roomName: process.env.ROOM_NAME || 'LAN Chat',
    historyFile: process.env.HISTORY_FILE || path.join(HERE, 'history.json'),
    allowedOrigins: (process.env.ALLOWED_ORIGINS || '').split(',').map((s) => s.trim()).filter(Boolean),
  });
  app.listen().then((actual) => {
    console.log(`\nLAN Chat "${process.env.ROOM_NAME || 'LAN Chat'}" is running.\n`);
    console.log(`  This computer:  http://localhost:${actual}`);
    const addrs = lanAddresses();
    if (addrs.length === 0) console.log('  (no LAN IPv4 address found - are you connected to WiFi?)');
    for (const a of addrs) console.log(`  Open http://${a.address}:${actual} on other devices   (${a.name})`);
    console.log('\nPress Ctrl+C to stop.\n');
  }).catch((e) => {
    console.error(e.code === 'EADDRINUSE' ? `Port ${port} is already in use. Try: PORT=${port + 1} node server.js` : e);
    process.exit(1);
  });
  const stop = () => { app.close().then(() => process.exit(0)); };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
