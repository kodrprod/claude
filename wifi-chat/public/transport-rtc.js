// transport-rtc.js - Mode B transports: a browser tab hosts, guests join over WebRTC
// DataChannels, no signalling server. Pairing codes are exchanged out-of-band.
//
//   const host = createRtcHost({ name, roomName });
//   host.on(...); await host.connect();            // joins the host itself to its own room
//   const invite = await host.createInvite();      // give to ONE guest
//   await host.acceptReply(replyCodeFromGuest);
//   // extra event: 'peers' { pending, connected }
//
//   const guest = createRtcGuest({ name });
//   guest.on(...);
//   const reply = await guest.acceptInvite(invite); // give back to the host
//   // 'welcome' fires once the channel is open and the host answered our hello
//
// Both implement the standard Transport interface (send, setTyping, close, selfId, on/off).
// Non-trickle ICE with iceServers: [] => only LAN host candidates, which is all we need.

import {
  Emitter, HubCore, Msg, WireReader, chunkWire, encodeCode, decodeCode, uid, wireToEvents,
} from './protocol.js';

const ICE_WAIT_MS = 3000;       // give up waiting for gathering to finish after this
const PING_MS = 15_000;
const DEAD_MS = 45_000;         // channel silent this long => peer is gone
const INVITE_TTL_MS = 10 * 60_000;
const DISCONNECT_GRACE_MS = 8000;
const CODE_VERSION = 1;

function newPeerConnection() {
  return new RTCPeerConnection({ iceServers: [] });
}

/** Resolve when ICE gathering is complete (or after the timeout, with whatever we have). */
function waitForIce(pc, timeoutMs = ICE_WAIT_MS) {
  return new Promise((resolve) => {
    let timer = null;
    function done() {
      clearTimeout(timer);
      pc.removeEventListener('icegatheringstatechange', onState);
      pc.removeEventListener('icecandidate', onCand);
      resolve();
    }
    function onState() { if (pc.iceGatheringState === 'complete') done(); }
    function onCand(e) { if (!e.candidate) done(); } // end-of-candidates marker
    if (pc.iceGatheringState === 'complete') return resolve();
    pc.addEventListener('icegatheringstatechange', onState);
    pc.addEventListener('icecandidate', onCand);
    timer = setTimeout(done, timeoutMs);
  });
}

/** Local SDP after gathering; throws a friendly error if no candidate was found. */
function finishedSdp(pc) {
  const sdp = pc.localDescription?.sdp || '';
  if (!/^a=candidate:/m.test(sdp)) {
    throw new Error('No network address found for pairing. Make sure this device is connected to WiFi.');
  }
  return sdp;
}

/** Normalised connection state across browsers. */
function pcState(pc) { return pc.connectionState || pc.iceConnectionState; }

/** Send a wire object over a DataChannel (chunked when big). */
function dcSend(dc, obj) {
  if (!dc || dc.readyState !== 'open') return;
  for (const part of chunkWire(JSON.stringify(obj))) dc.send(part);
}

/* ------------------------------------------------------------------ */
/* Host                                                                */
/* ------------------------------------------------------------------ */

export class RtcHost extends Emitter {
  constructor({ name = 'Host', roomName = 'LAN Chat' } = {}) {
    super();
    this.name = name;
    this.roomName = roomName;
    this.selfId = null;
    this.hub = new HubCore({ roomName });
    this.peers = new Map(); // pairId -> peer
    this.started = false;
    this.closed = false;
    // The host is a participant: a local conn whose "send" turns wire messages into events.
    this.local = {
      isHost: true, userId: null,
      send: (o) => { if (o.t === 'welcome') this.selfId = o.selfId; wireToEvents(this, o); },
    };
    this.sweep = setInterval(() => this._sweep(), 10_000);
  }

  /** Joins the host to its own room. Idempotent. Safe to call before or after createInvite(). */
  async connect({ name } = {}) {
    if (name) this.name = name;
    if (this.started) return;
    this.started = true;
    this.emit('status', { state: 'connected' });
    this.hub.handle(this.local, Msg.hello(this.name)); // -> 'welcome' + presence
    this._emitPeers();
  }

  send(text) {
    if (!this.started) return null;
    const cid = uid(10);
    this.hub.handle(this.local, Msg.msg(String(text), cid));
    return cid;
  }

  setTyping(typing) { if (this.started) this.hub.handle(this.local, Msg.typing(typing)); }

  /** Create an offer for one guest. Resolves with the invite code ("LC1....").*/
  async createInvite() {
    if (this.closed) throw new Error('Host is closed');
    if (!this.started) await this.connect();
    const id = uid(6); // pairing id; the guest echoes it in its reply
    const pc = newPeerConnection();
    const peer = { id, pc, dc: null, state: 'pending', remoteSet: false, lastSeen: Date.now(), created: Date.now(), graceTimer: null, conn: null };
    this.peers.set(id, peer);
    try {
      peer.dc = pc.createDataChannel('chat', { ordered: true });
      this._wirePeer(peer);
      await pc.setLocalDescription(await pc.createOffer());
      await waitForIce(pc);
      const code = await encodeCode({ v: CODE_VERSION, k: 'offer', id, sdp: finishedSdp(pc) });
      this._emitPeers();
      return code;
    } catch (e) {
      this._closePeer(peer);
      throw e;
    }
  }

  /** Feed the guest's reply code back in. Matches it to the right pending invite. */
  async acceptReply(code) {
    const r = await decodeCode(code);
    if (!r || r.k !== 'answer' || typeof r.sdp !== 'string') throw new Error('This is not a reply code. Paste the code the guest got after joining.');
    const peer = this.peers.get(r.id);
    if (!peer || peer.remoteSet) throw new Error('This reply does not match an open invite (it may have expired or been used already). Create a new invite.');
    peer.remoteSet = true;
    try {
      await peer.pc.setRemoteDescription({ type: 'answer', sdp: r.sdp });
    } catch (e) {
      this._closePeer(peer);
      throw new Error('Could not use that reply code: ' + e.message);
    }
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.sweep);
    for (const p of [...this.peers.values()]) this._closePeer(p);
    this.hub.drop(this.local);
    this.emit('status', { state: 'disconnected' });
  }

  /* ---- internals ---- */

  _wirePeer(peer) {
    const { pc, dc } = peer;
    const conn = peer.conn = {
      userId: null,
      send: (o) => dcSend(peer.dc, o),
      close: () => this._closePeer(peer),
    };
    const reader = new WireReader((o) => this.hub.handle(conn, o));
    dc.onopen = () => { peer.state = 'connected'; peer.lastSeen = Date.now(); this._emitPeers(); };
    dc.onmessage = (ev) => {
      peer.lastSeen = Date.now();
      if (typeof ev.data === 'string' && ev.data.length <= 200_000) reader.feed(ev.data);
    };
    dc.onclose = () => this._closePeer(peer);
    const check = () => {
      const s = pcState(pc);
      clearTimeout(peer.graceTimer);
      if (s === 'failed' || s === 'closed') this._closePeer(peer);
      else if (s === 'disconnected') peer.graceTimer = setTimeout(() => this._closePeer(peer), DISCONNECT_GRACE_MS);
    };
    pc.onconnectionstatechange = check;
    pc.oniceconnectionstatechange = check;
  }

  _closePeer(peer) {
    if (!this.peers.delete(peer.id)) return;
    clearTimeout(peer.graceTimer);
    peer.dc && (peer.dc.onclose = peer.dc.onmessage = peer.dc.onopen = null);
    peer.pc.onconnectionstatechange = peer.pc.oniceconnectionstatechange = null;
    try { peer.pc.close(); } catch { /* ignore */ }
    this.hub.drop(peer.conn); // broadcasts leave + presence if they had joined
    this._emitPeers();
  }

  _sweep() {
    const t = Date.now();
    for (const p of [...this.peers.values()]) {
      if (p.state === 'pending' && t - p.created > INVITE_TTL_MS) this._closePeer(p);
      else if (p.state === 'connected' && t - p.lastSeen > DEAD_MS) this._closePeer(p);
    }
  }

  _emitPeers() {
    let pending = 0, connected = 0;
    for (const p of this.peers.values()) p.state === 'connected' ? connected++ : pending++;
    this.emit('peers', { pending, connected });
  }
}

/* ------------------------------------------------------------------ */
/* Guest                                                               */
/* ------------------------------------------------------------------ */

export class RtcGuest extends Emitter {
  constructor({ name = 'Guest' } = {}) {
    super();
    this.name = name;
    this.selfId = null;
    this.pc = null;
    this.dc = null;
    this.closed = false;
    this.lastRx = 0;
    this.pingTimer = null;
    this.graceTimer = null;
    this._typing = false;
    this.reader = new WireReader((o) => {
      if (o.t === 'welcome') {
        this.selfId = o.selfId;
        this.emit('status', { state: 'connected' });
      }
      wireToEvents(this, o);
    });
  }

  /** Records the name. Joining actually happens via acceptInvite() -> 'welcome'. */
  async connect({ name } = {}) { if (name) this.name = name; }

  /** Consume the host's invite code, resolve with the reply code to hand back. */
  async acceptInvite(code) {
    if (this.closed) throw new Error('Closed');
    const o = await decodeCode(code);
    if (!o || o.k !== 'offer' || typeof o.sdp !== 'string' || !o.id) throw new Error('This is not an invite code. Paste the code the host gave you.');
    this._teardownPeer();
    this.emit('status', { state: 'connecting' });
    const pc = this.pc = newPeerConnection();
    pc.ondatachannel = (e) => this._wireChannel(e.channel);
    const check = () => {
      const s = pcState(pc);
      clearTimeout(this.graceTimer);
      if (s === 'failed' || s === 'closed') this._lost();
      else if (s === 'disconnected') this.graceTimer = setTimeout(() => this._lost(), DISCONNECT_GRACE_MS);
    };
    pc.onconnectionstatechange = check;
    pc.oniceconnectionstatechange = check;
    try {
      await pc.setRemoteDescription({ type: 'offer', sdp: o.sdp });
      await pc.setLocalDescription(await pc.createAnswer());
      await waitForIce(pc);
      return await encodeCode({ v: CODE_VERSION, k: 'answer', id: o.id, sdp: finishedSdp(pc) });
    } catch (e) {
      this._teardownPeer();
      this.emit('status', { state: 'disconnected', detail: e.message });
      throw e;
    }
  }

  send(text) {
    if (!this.dc || this.dc.readyState !== 'open' || !this.selfId) {
      this.emit('system', { text: 'Not connected - message not sent', error: true });
      return null;
    }
    const cid = uid(10);
    dcSend(this.dc, Msg.msg(String(text), cid));
    return cid;
  }

  setTyping(typing) {
    typing = !!typing;
    if (typing === this._typing) return;
    this._typing = typing;
    if (this.selfId) dcSend(this.dc, Msg.typing(typing));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this._teardownPeer();
    this.selfId = null;
    this.emit('status', { state: 'disconnected' });
  }

  /* ---- internals ---- */

  _wireChannel(dc) {
    this.dc = dc;
    dc.onopen = () => {
      this.lastRx = Date.now();
      dcSend(dc, Msg.hello(this.name));
      this.pingTimer = setInterval(() => {
        if (Date.now() - this.lastRx > DEAD_MS) return this._lost();
        dcSend(dc, Msg.ping());
      }, PING_MS);
    };
    dc.onmessage = (ev) => {
      this.lastRx = Date.now();
      if (typeof ev.data === 'string') this.reader.feed(ev.data);
    };
    dc.onclose = () => this._lost();
  }

  _teardownPeer() {
    clearInterval(this.pingTimer); clearTimeout(this.graceTimer);
    this.pingTimer = this.graceTimer = null;
    if (this.dc) this.dc.onclose = this.dc.onmessage = this.dc.onopen = null;
    if (this.pc) this.pc.onconnectionstatechange = this.pc.oniceconnectionstatechange = null;
    try { this.pc?.close(); } catch { /* ignore */ }
    this.pc = this.dc = null;
  }

  _lost() {
    if (this.closed || !this.pc) return;
    this._teardownPeer();
    this.selfId = null;
    this.emit('status', { state: 'disconnected', detail: 'Lost connection to the host' });
  }
}

export function createRtcHost(opts) { return new RtcHost(opts); }
export function createRtcGuest(opts) { return new RtcGuest(opts); }
