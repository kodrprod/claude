# LAN Chat

A simple group chat over your local WiFi. One device hosts, everyone else joins.
It's a web app, so it runs in Safari on iPad/iPhone, Chrome or Firefox, and it can be
added to the Home Screen. No accounts, and no internet needed for the chat itself.

## Two ways to host

### 1. Browser-host mode (works from an iPad, nothing to install)

The host is just a browser tab. Guests pair with it once by swapping two codes.

1. Open the app on the host device and tap **Host a chat on this device**.
2. Tap **Add another person**. You get an **invite** (QR code + text).
3. On the guest device, open the same app → **Join a chat** → paste the invite
   (or scan the QR with the Camera app, if the app is served from a normal URL).
4. The guest gets a **reply** code. Send it back (Copy, Share → AirDrop, or QR) and
   paste it on the host under **Step 2**.
5. Repeat step 2–4 for each person. Messages flow device-to-device over WiFi
   (WebRTC); the host relays them to everyone.

Keep the host tab open and the screen on. If it closes, the chat ends.

### 2. Server mode (a computer, Raspberry Pi, or Android/Termux hosts)

Needs Node.js 18 or newer. There are no dependencies to install.

```sh
cd wifi-chat
node server/server.js          # or: npm start
```

It prints addresses like `http://192.168.1.23:8080`. Open that on every device
on the same WiFi (including the host itself), type a name, chat. Guests join just by
opening the address. Reconnects are automatic, and the last 200 messages are kept
(and survive restarts in `server/history.json`).

Options (environment variables): `PORT` (default 8080), `ROOM_NAME`
(default "LAN Chat"), `HISTORY_FILE`, `ALLOWED_ORIGINS`.

## Project layout

```
SPEC.md                 architecture + wire protocol (the contract)
design/                 research.md, design-system.md, mockup.html
server/server.js        zero-dependency HTTP + WebSocket server
public/                 the web app (no build step, plain ES modules)
  app.js                UI and state
  protocol.js           shared message rules (used by browser AND server)
  transport-ws.js       client for server mode
  transport-rtc.js      browser-host mode (WebRTC host + guest)
  sw.js, manifest       offline/PWA bits
  vendor/               QR code generator (MIT), bundled so it works offline
```

## Notes and limits

- Every device must be on the same WiFi network. Some guest or hotel networks block
  device-to-device traffic ("client isolation"), and then neither mode works.
- Browser-host mode: each invite is for one person and is valid for about 10 minutes.
  If the host's tab is killed abruptly, guests may need up to 45 s to notice.
- Messages are kept in memory on the host (and on disk in server mode). There is no
  end-to-end encryption, so treat it like talking out loud in the room. WebRTC links are
  encrypted in transit; server mode uses plain HTTP on your LAN.
- Opening `index.html` directly as a file doesn't work, because browsers block modules
  on `file://`. Serve it over http(s): the Node server, any static host, or GitHub Pages.

## Built by

A small agent team: design research → design drafting → backend coder and
front-end coder in parallel, with an orchestrating manager doing the spec,
reviews and end-to-end testing.
