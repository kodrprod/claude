# LAN Chat — Architecture Spec (shared contract for all agents)

A simple group chat over local WiFi. **One device is the host ("server")**, the
others join. Everything the user touches is a web app (works in iPad Safari,
installable to the Home Screen as a PWA). No internet, accounts or cloud needed.

## The iPad problem → two host modes

iPadOS cannot run a normal server process, so the app supports two ways to host.
The UI is identical; only the transport differs.

| Mode | Host device | How guests join | Transport |
|------|-------------|-----------------|-----------|
| **A. Server mode** | Any computer/Pi/Android-Termux/iPad-with-iSH running `node server/server.js` | Open `http://<host-ip>:8080` in a browser | WebSocket (`/ws`) to the Node server |
| **B. Browser-host mode** | Any browser tab (e.g. the iPad itself) | Pair once per guest by exchanging a pairing code (copy/paste, AirDrop, or QR) | WebRTC DataChannels; the host tab is the hub and relays messages |

In mode B there is no signaling server: the host creates an *invite code*
(compressed SDP offer), the guest pastes it and gets a *reply code* (compressed SDP
answer) to paste back on the host. Host candidates only (no STUN/TURN needed on a LAN).
ICE gathering must complete before a code is produced (non-trickle).

## File layout (all under `wifi-chat/`)

```
SPEC.md                    this file
README.md                  how to run (written last)
design/research.md         design research agent
design/design-system.md    design drafting agent (tokens, components, screens)
design/mockup.html         design drafting agent (static clickable mockup)
server/server.js           backend: zero-dependency Node ≥18 HTTP + WebSocket server
server/package.json        backend: "start": "node server.js" (no dependencies)
public/index.html          frontend: the single-page app (served by server, also standalone)
public/styles.css          frontend
public/app.js              frontend: UI, state, renders, talks to a Transport
public/transport-ws.js     backend: WebSocket transport (mode A, client side)
public/transport-rtc.js    backend: WebRTC host + guest transports (mode B)
public/protocol.js         backend: shared message helpers, code compression
public/manifest.webmanifest, public/icon.svg, public/sw.js   frontend: PWA bits
```

No build step, no npm dependencies, plain ES modules (`<script type="module">`).
Must work in current iPadOS Safari, Chrome, Firefox.

## Transport interface (frontend ⇄ backend contract)

Every transport is an object implementing:

```js
// all transports extend EventTarget-like emitter with: on(type, fn), off(type, fn)
transport.connect({ name })      // Promise<void>; resolves when joined
transport.send(text)             // send a chat message (string, ≤ 2000 chars)
transport.setTyping(bool)        // optional typing indicator
transport.close()
transport.selfId                 // string, assigned on join

// Events emitted (payload = the message object below):
'welcome'   { selfId, users: User[], history: ChatMsg[], roomName }
'message'   ChatMsg
'presence'  { users: User[] }                 // full list every time someone joins/leaves/renames
'typing'    { userId, name, typing: bool }
'system'    { text }                          // e.g. "Anna joined"
'status'    { state: 'connecting'|'connected'|'reconnecting'|'disconnected', detail? }
```

Types:
```js
User    = { id: string, name: string, color: string /* hex, server-assigned */, isHost: bool }
ChatMsg = { id: string, userId: string, name: string, color: string, text: string, ts: number /* ms epoch, host clock */ }
```

### Wire protocol (JSON, identical over WebSocket and DataChannel)

Client → host:
```
{ "t": "hello",  "name": "Anna" }
{ "t": "msg",    "text": "hi", "cid": "<client temp id>" }
{ "t": "typing", "typing": true }
{ "t": "ping" }
```
Host → client:
```
{ "t": "welcome",  "selfId", "users", "history", "roomName" }
{ "t": "msg",      ...ChatMsg, "cid"?  }   // cid echoed only to the sender
{ "t": "presence", "users" }
{ "t": "typing",   "userId", "name", "typing" }
{ "t": "system",   "text" }
{ "t": "pong" }
{ "t": "error",    "text" }
```

Host rules: keep last 200 messages in memory (server mode may also persist to
`server/history.json`); trim text, reject empty or > 2000 chars; names 1–24 chars,
de-duplicate by appending a number; assign each user a color from a fixed palette;
broadcast presence on join/leave; never trust client-sent ids/colors/timestamps.
Text is rendered with `textContent` only (no HTML injection).

### Transport selection in the app

`app.js` decides at startup:
- If the page is served over http(s) from the Node server (probe `GET /api/info`
  returns `{ app: "lan-chat", roomName, addresses: [...] }`), use **WebSocket**
  transport automatically → straight to "enter your name".
- Otherwise (opened as a standalone file / static hosting / GitHub Pages), show a
  start screen: **"Host a chat on this device"** or **"Join a chat"** (browser-host
  mode B), plus a hint on how to use server mode.

`transport-rtc.js` exports:
```js
createRtcHost({ name, roomName })   // returns transport; the host is also a chat participant
  host.createInvite()               // Promise<string inviteCode>  (one per guest)
  host.acceptReply(replyCode)       // Promise<void>
  // emits additionally 'peers' { pending: n, connected: n }
createRtcGuest({ name })
  guest.acceptInvite(inviteCode)    // Promise<string replyCode>
  // then emits 'welcome' once the channel opens
```
Codes are text safe to paste anywhere (base64url of deflate-compressed SDP via
`CompressionStream` when available, plain base64url otherwise), prefixed `LC1.`.
The app also renders a code as a QR image if a QR library loads (optional nicety,
e.g. `qrcode-generator` from cdnjs/jsdelivr) and offers a "Share" button
(`navigator.share`) so iPad users can AirDrop codes.

`transport-ws.js` exports `createWsTransport({ url })`, auto-reconnects with
backoff and re-sends `hello` with the same name.

## Server (`server/server.js`)

- Node ≥18, **zero dependencies**: implement the WebSocket handshake + framing
  (text frames, masking, ping/pong, close, fragmented frames, 64 KB max) by hand
  using `http` + `crypto`.
- Serves `../public` statically with correct MIME types; `GET /api/info`.
- `PORT` env (default 8080), `ROOM_NAME` env (default "LAN Chat"), binds `0.0.0.0`.
- On start prints every LAN IPv4 URL, e.g. `Open http://192.168.1.23:8080 on other devices`.
- Heartbeat: drop clients silent for 30 s.
