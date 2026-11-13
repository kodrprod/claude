# LAN Chat — Design Research

Audience: design drafter (design-system.md, mockup.html) and front-end coder (index.html, styles.css, app.js).
Primary device: iPad Safari / Home Screen PWA. Also phones and desktops. Offline LAN; no external fonts or assets.

---

## 1. Chat UI patterns

### 1.1 Bubbles vs flat list
| Pattern | Pros | Cons | Fit |
|---|---|---|---|
| Bubbles, own right / others left | Instantly scannable who-said-what; familiar | Wastes width on iPad landscape; long messages look heavy | Good for small groups, 2-8 people |
| Flat list (Slack/IRC style, all left) | Dense, great on wide screens, easy to read history | Own messages less distinct | Good for desktop and large groups |

**Recommendation:** bubbles, but with a **max-width cap** (`min(34rem, 78%)`) so they never stretch on iPad landscape. Own messages right-aligned with the accent fill; others left-aligned on a neutral surface. This is a general convention, not any one app's look. Use a flat-list density option only if time allows (not required).

### 1.2 Grouping consecutive messages
- Group by `userId` when the gap between messages is **< 5 min** and no system message intervenes.
- First message in a group shows the sender name (others only; never for own) and the avatar; later messages are tight (2px gap vs 10px between groups).
- Corner radii: full radius on all corners for a single message; for a group, flatten the corner on the sender's side for middle/last messages (e.g. 18px, with 6px on the inner side). Keeps grouping visible without extra chrome.
- Avatar shows on the **last** message of a group (bottom-aligned) or first; pick one and be consistent. Recommended: first (aligns with the name line, simpler to render in append-only order).

### 1.3 Timestamps
- Show a centered **day/time divider** when gap > 30 min or the day changes ("Today 14:05", "Yesterday", weekday + time, else date).
- Per-message exact time: small (11-12px) muted text under the last bubble of a group, or on tap/long-press. Do not repeat on every bubble.
- Use `<time datetime>` and `Intl.DateTimeFormat(undefined, {hour:'numeric', minute:'2-digit'})` so 12/24h follows locale.
- Note: `ts` is the host clock; display it as-is, never compare with local time for ordering.

### 1.4 Own vs others
- Own: right, accent fill, on-accent text, no name, no avatar.
- Others: left, surface fill, name colored by user color (see contrast caveat 4.1), avatar.
- Pending (sent, not yet echoed by `cid`): own bubble at 60% opacity; failed: red "Not sent, tap to retry".

### 1.5 Avatars / initials
- 32px circle (36px on wide), initials 1-2 chars uppercase, bold 13-14px.
- Background = the server-assigned `User.color`; text color computed (white or near-black) for >= 4.5:1. Because the server palette is fixed, **the design should specify the palette** the server uses (see 5.x) so contrast is guaranteed. Recommend an 8-color palette tuned for white initials in both themes (listed in the chosen direction).
- Never rely on color alone: initials plus name text always present.

### 1.6 System messages
- Centered, muted, small (13px) pill or plain text, no bubble: "Anna joined", "Ben left".
- Collapse bursts: 3+ joins/leaves within 10 s become "Anna, Ben and 2 others joined".
- Announce politely via aria-live (see section 4).

### 1.7 Typing indicator
- Appears just above the composer (inside the scroll region's bottom, not shifting the composer): "Anna is typing" with 3 animated dots; "Anna and Ben are typing"; 3+ -> "Several people are typing".
- Debounce: send `typing:true` on first keystroke, re-send at most every 3 s, send `false` on blur/send/2 s idle. Client auto-expires a remote typing flag after 5 s (dropped packets).
- Reserve its height (20px) permanently so the layout never jumps.
- Reduced motion: static "..." text, no animation.

### 1.8 Presence list
- Wide screens (>= 900px): persistent left or right sidebar, 260-300px. Rows: avatar, name, "Host" badge, "You" tag. Sort: you, host, then alphabetical.
- Narrow screens: header shows stacked avatar facepile + "4 online" button opening a sheet (bottom sheet on phone, popover on tablet).
- Presence is "currently connected"; there is no away state in the protocol, so do not invent one.

### 1.9 Empty states and status
- Empty room: friendly illustration-free text, e.g. "You are the first one here. Say hello, or share the address so others can join." Show the join address / invite action inline for the host.
- Connection banner (from `status` event): slim bar under header: "Reconnecting..." (amber), "Disconnected. Retrying" (red), hidden when connected. Composer stays enabled and queues? No: **disable send** while disconnected and keep the draft.
- Scroll behavior: auto-stick to bottom only if the user is within ~80px of the bottom; otherwise show a floating "New messages" pill (with count) that scrolls down on tap.

---

## 2. iPad / iOS Safari specifics

### 2.1 Head tags (PWA, standalone)
```html
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
<meta name="theme-color" content="#F6F4EF" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#14161A" media="(prefers-color-scheme: dark)">
<meta name="color-scheme" content="light dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="LAN Chat">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">   <!-- 180x180 PNG -->
<link rel="manifest" href="manifest.webmanifest">
```
- **Do not** put `maximum-scale=1` / `user-scalable=no`: it hurts accessibility and iOS ignores it for pinch anyway.
- iOS ignores manifest icons; it needs a **PNG** `apple-touch-icon` (180x180; also fine to add 167x167 for iPad Pro). SVG is not accepted there. Since the spec lists only `icon.svg`, the coder should add a generated PNG (flag to coordinator) or accept a generic screenshot icon.
- `black-translucent` + `viewport-fit=cover` makes content extend under the status bar: pad the header with `env(safe-area-inset-top)`. Status bar text is white, so the header background must be dark-enough in light mode too, OR use `default` (dark text on page background) and keep the light header. Safer pick for a light/dark app: **`default`** is unreliable in dark mode on old iOS; recommend `black-translucent` and a header surface that passes contrast with white status text in both themes (dark teal/ink header in light mode). Test on device.
- Manifest: `display: "standalone"`, `background_color` matching surface, `theme_color`, `start_url: "./"`, `scope: "./"`, icons any + maskable.

### 2.2 Safe-area insets
```css
:root { --sat: env(safe-area-inset-top); --sar: env(safe-area-inset-right);
        --sab: env(safe-area-inset-bottom); --sal: env(safe-area-inset-left); }
.header   { padding: max(8px, var(--sat)) max(16px, var(--sar)) 8px max(16px, var(--sal)); }
.composer { padding: 8px max(12px, var(--sar)) max(8px, var(--sab)) max(12px, var(--sal)); }
```
Landscape iPad/iPhone has left/right insets (notch/rounded corners); apply them to header, message list gutters, composer and sidebar.

### 2.3 On-screen keyboard and viewport
Facts (from the sources): iOS Safari shrinks/shifts the **visual** viewport but not the layout viewport; `interactive-widget=resizes-content` and `dvh` are not reliably honored on iOS Safari, and in standalone PWA the viewport can stay shrunk after the keyboard closes (known bug). Plan for all of it:
1. Layout root: `height: 100dvh` (fallback `100vh`) as a CSS grid: `grid-template-rows: auto 1fr auto` (header, messages, composer). The **messages area scrolls; body does not** (`overflow: hidden` on html/body, `overscroll-behavior: none`).
2. Composer is in the grid flow, **not `position: fixed`** (fixed + keyboard is the classic iOS breakage).
3. JS fallback: on `visualViewport` `resize` and `scroll`, set `--vvh = visualViewport.height + 'px'` and `--vvt = visualViewport.offsetTop` and size the root `height: var(--vvh, 100dvh)`; then `window.scrollTo(0,0)` to cancel iOS's body shift. After the keyboard closes (`blur`/`focusout`), re-sync after ~100 ms to recover from the stuck-shrunk bug.
4. After resize, if the user was at the bottom, scroll the list to bottom (keep the latest message visible above the keyboard).
5. Do not call `focus()` programmatically on page load on iPad (it pops the keyboard and shoves layout); only after an explicit tap (e.g. after Join).
6. Hardware keyboard on iPad: Enter sends, Shift+Enter newline. On software keyboard keep the return key as newline? Recommend: `enterkeyhint="send"` and Enter sends on both; long messages still possible via Shift+Enter. Provide a visible Send button regardless.

### 2.4 Touch and input
- Minimum **44x44 pt** targets (Apple HIG); recommended 48px for primary actions. Spacing >= 8px between adjacent targets.
- **Input font-size >= 16px** on every `input`/`textarea`/`select`, otherwise iOS zooms on focus. Do not rely on disabling zoom.
- Composer: auto-growing `<textarea rows=1>` up to ~5 lines (max-height 9rem), then scrolls; `autocapitalize="sentences"`, `enterkeyhint="send"`, `autocomplete="off"`, `autocorrect="on"`.
- Name field: `autocapitalize="words"`, `maxlength=24`, `autocomplete="nickname"`.
- Code fields: `autocapitalize="off" autocorrect="off" spellcheck="false" inputmode="text"`; use `<textarea>` (codes are long, monospace, wrap with `word-break: break-all`).
- Disable the grey tap flash and callout where it hurts: `-webkit-tap-highlight-color: transparent`; keep `-webkit-touch-callout` default on message text so users can copy. `user-select: text` on bubbles, `none` on chrome/buttons.
- Use `touch-action: manipulation` on buttons to remove the double-tap delay.
- `:hover` styles only inside `@media (hover: hover)`; use `:active` for touch feedback.
- Rubber-band: `-webkit-overflow-scrolling: touch` is default now; use `overscroll-behavior-y: contain` on the message list.

### 2.5 Widths: Split View, Slide Over, Stage Manager, rotation
Design **by container width, not device**. Breakpoints (CSS `@media (min-width)` or container queries on the app root):
| Width | Layout |
|---|---|
| < 600px (phone, Slide Over ~320-375, narrow split) | single column; people list in a sheet |
| 600-899px (iPad portrait, 1/2 split) | single column, wider gutters, bubbles max 78%; people in a popover/sheet |
| >= 900px (iPad landscape, desktop) | two panes: sidebar 280px + chat; content column max ~760px centered inside chat pane |
- Stage Manager and Split View can resize live: **no JS width assumptions**, no orientation lock, test at 320, 375, 507, 678, 744, 1024, 1366 px widths.
- Cap line length ~ 70ch for readability in the pane; center the message column on very wide screens.

### 2.6 Dark mode
- `color-scheme: light dark` and CSS custom properties switched with `@media (prefers-color-scheme: dark)`. Optionally a manual Light/Dark/Auto toggle stored in `localStorage` via `data-theme` on `<html>` (wrap storage in try/catch).
- Dark surfaces should be **not pure black** (#14161A-ish) with lifted elevation; avoid pure white text (use ~ #E9ECEF) to reduce halation. Reduce accent saturation slightly in dark.
- Update `theme-color` meta for both schemes (see 2.1).

### 2.7 Misc iOS details
- Standalone mode has no URL bar and no back button: include in-app navigation (Leave room, Settings) and never rely on browser history.
- `100vh` includes the dynamic toolbar in Safari: use `dvh`.
- Disable text-size inflation in landscape: `-webkit-text-size-adjust: 100%`.
- Fonts: system only (see 5). `font-variant-numeric: tabular-nums` for times.
- Add to Home Screen is manual on iOS (Share -> Add to Home Screen); show a dismissible hint only when `navigator.standalone === false` and UA is iOS Safari.
- WebRTC and camera for QR scanning in a PWA: iOS standalone supports `getUserMedia` in current versions, but a camera scan UI is optional; the system Camera app can scan a QR and open nothing useful (the payload is not a URL unless wrapped), see 3.4.

---

## 3. Onboarding / pairing UX

### 3.1 Start screen (static / no server)
Two large cards, equal weight, 88px+ tall, each with an icon, title, one-line description:
- **Host a chat** — "Use this device as the room. Others connect to you."
- **Join a chat** — "Someone is already hosting. Enter their code."
Below, a quiet text link: "Have a computer on your network? Run the server instead" -> expands a 3-line how-to (`node server/server.js`, open the printed address).

### 3.2 Server-mode join screen
Minimal and quick (should take under 5 seconds):
- Room name as title (from `/api/info`), small caption "N online" if cheaply available.
- One field: "Your name", prefilled from `localStorage` if present, autofocus on non-touch only, `maxlength 24`.
- One primary button "Join chat" (full width on phone, 280px on wide). Enter key submits.
- Inline validation under the field ("Pick a name, up to 24 characters"); the host may rename duplicates, so show "You will appear as Anna 2" after join as a system message.
- Remember name; on return visit show "Continue as Anna" + small "Change name".

### 3.3 Browser-host pairing: make a 2-step code exchange feel simple
The technical flow is: host makes invite -> guest pastes, gets reply -> host pastes reply. Humans should see **one linear conversation with two clearly labelled steps per side**, and the same visual language on both devices.

**Principles**
1. Use **plain words**: "invite code" and "reply code" are fine, but pair each with a verb and a direction: "Send this to your guest", "Paste your guest's reply here". Avoid "SDP/offer/answer".
2. **Stepper** at top: `1 Send invite  -  2 Get reply  -  3 Connected`. Current step filled, done steps with a check; text "Step 1 of 2" visible (not just dots). Announce step changes to screen readers.
3. One primary action per step, huge: **Copy code** (full width, 56px) and **Share...** (`navigator.share`) next to it; Share is shown only when `navigator.share` exists (iPad always). Copy button changes to "Copied" with a check for 2 s (and `aria-live` message).
4. The code itself is shown **collapsed**: a read-only monospace box 3 lines tall with fade-out and "Show full code" toggle; users rarely need to read it. Show length ("1.2 KB") for confidence. Select-all on tap.
5. **QR + text fallback** side by side on wide screens, stacked on narrow: QR on top (min 220px, high-contrast black on white even in dark mode, quiet zone 4 modules), text/copy below under "Or send as text". If the code is too big for a reliable QR (rough guide: > ~1000 chars), hide the QR and say why ("Code too long for QR, use Copy or Share") instead of rendering an unscannable one. Tell the coder to check `qrcode-generator` capacity at error level L.
6. **Paste field** on the receiving side: big textarea with a "Paste from clipboard" button (`navigator.clipboard.readText()`, needs user gesture; may prompt on iOS). Auto-detect: if the user pastes a string starting `LC1.`, enable the primary button and show a green check ("Looks like a valid code"). If they paste surrounding text (e.g. a message with the code in it), extract the `LC1.` token with a regex rather than failing. Strip whitespace/newlines (chat apps wrap lines).
7. **Progress feedback during async work**: "Preparing invite..." (ICE gathering can take 1-3 s; show a spinner on the button, not a blank screen). Then "Waiting for Anna's reply..." with a live pulse. On success a celebratory but quiet "Anna joined" toast.
8. **Time-limited codes**: tell the host how long the invite stays valid (WebRTC consent timeouts make slow exchanges fail). Show a soft countdown/age ("Created 40 s ago") and a "Make a new invite" button; if connection fails show a clear retry path that keeps the guest's name.
9. **Host multi-guest**: after one guest connects, offer "Add another person" returning to step 1 with a fresh invite; list pending/connected peers with status chips (`peers` event). The host's chat is usable in the background so the host can leave the dialog.
10. Errors in human language: "That code does not look right. Make sure you copied all of it" / "This invite was already used, ask for a new one" / "Could not connect. Are you both on the same WiFi?".

**Guest screen (join with code)**
```
Step 1 of 2 — Paste the invite
  [textarea]  [Paste from clipboard]   [Scan QR] (if camera available)
  Your name [______]
  [Continue]
Step 2 of 2 — Send your reply to the host
  [Copy reply code] [Share...]   QR (optional)
  "Waiting for the host to accept..."  (auto-advances to chat on open)
```
**Host screen (add a person)**
```
Step 1 of 2 — Send this invite to your guest
  [Copy invite] [Share...]   QR
  [Next: I have their reply]
Step 2 of 2 — Paste their reply
  [textarea] [Paste from clipboard]   [Connect]
  "Connecting to Anna..." -> "Anna joined"
```
Both screens: a "Cancel" and a short "How does this work?" disclosure (3 sentences; mentions same WiFi, no internet needed).

### 3.4 QR notes
- Scanning in-app needs `getUserMedia` and a decoder (`BarcodeDetector` is not on iOS Safari; would need a JS lib). Treat scanning as an **optional enhancement**; the QR is still valuable because another phone can scan it with the system camera and copy text. Wrap the code in nothing (no URL), or if desired `https://...#LC1.xxx` is not possible offline, so text is fine.
- Never let QR be the only path; always show copy/paste + Share.

### 3.5 Host status indicators
Header chip for the host: "Hosting - 3 connected" (opens manage dialog: add person, list peers, end chat). Warn on host: "If you close this tab or lock the iPad, the chat ends for everyone" (iOS suspends background tabs/PWA). Consider keeping the screen awake via `navigator.wakeLock` when available.

---

## 4. Accessibility

### 4.1 Contrast
- Body text >= 4.5:1; large text (>= 18.66px bold / 24px) and UI component borders/icons >= 3:1 (WCAG 2.1 AA, 1.4.3 / 1.4.11).
- Secondary/muted text (timestamps, captions) must still be >= 4.5:1; the usual mistake is a light grey 11px time at 3:1. Use >= 12px and >= 4.5:1.
- Server-assigned user colors are used for (a) avatar fills with white/dark initials, (b) sender name text. Name text on a surface needs 4.5:1, which a mid-tone avatar color often fails. **Rule:** use the color for avatar fill and a small color dot; render the name in `--text` (or in a darkened/lightened variant `color-mix(in oklab, var(--user) 55%, var(--text))`), never raw.
- Focus ring: 2-3px, offset 2px, >= 3:1 against adjacent colors, visible in both themes; never `outline: none` without replacement. Use `:focus-visible`.

### 4.2 Screen readers / live regions
- Message list: `role="log"` with implicit `aria-live="polite"` and `aria-relevant="additions"`; do **not** also wrap it in `aria-atomic`. Give it `aria-label="Messages"`. Each message as `<li>` with visually-hidden prefix like "Anna, 14:05:" (or `aria-label`), so group-collapsed names are still read.
- Own sent messages should not be announced (set `aria-hidden` on echoes or skip live announcement) to avoid noise; announcing "Sent" is optional.
- System messages ("Anna joined"): include in the log (polite). Connection status banner: `role="status"`. Errors that block (invalid code): `role="alert"` once.
- Typing indicator: **not** live (too chatty); `aria-hidden` or a separate polite region that only announces after a debounce. Recommend: not announced.
- Throttle: if > 5 messages arrive in 1 s (history load), render without announcing (insert before enabling live region, or load history into a non-live container then switch).
- Stepper: `<ol>` with `aria-current="step"`; announce "Step 2 of 2" in a visually-hidden polite region when advancing.
- Copy buttons: update visible text and a polite status ("Invite code copied").
- Landmarks: `<header>`, `<main>` (messages), `<aside aria-label="People">`, `<form>` composer with `<label>` (visually hidden is fine: "Message").

### 4.3 Focus management
- After Join: move focus to the composer (only on user-initiated join; on iPad this opens the keyboard, which is expected).
- After Send: keep focus in the composer (do not blur, otherwise the keyboard collapses on every message); on touch devices prefer `pointerdown` + `preventDefault()` on the Send button so the textarea does not lose focus.
- Dialogs/sheets (people, host manager): use `<dialog>` or `role="dialog" aria-modal="true"`, trap focus, close on Esc, return focus to the opener. Background `inert`.
- Skip link not needed (tiny app) but tab order must be header -> people -> messages -> composer.
- Keyboard: Enter sends, Shift+Enter newline, Esc closes sheets, all buttons reachable.

### 4.4 Motion and other
- `@media (prefers-reduced-motion: reduce)`: remove typing-dot animation, slide-ins, smooth scroll (`scroll-behavior:auto`), pulse animations; keep opacity cross-fades <= 150 ms at most.
- Default motion budget: 150-200 ms ease-out for message appear (translateY 6px + fade), 250 ms for sheets.
- Respect text scaling: size in `rem`, no fixed heights on bubbles; layout survives 200% zoom and Dynamic Type via `font: -apple-system-body` is not needed; plain rem is enough.
- Do not convey state by color alone (connected = dot + text; errors = icon + text).
- `lang` attribute on `<html>`; `dir` follow UI (messages may contain RTL: set `dir="auto"` on each message text).
- Target size: 44px; spacing between bubble actions.

---

## 5. Visual direction options

Shared system-font stack (no downloads):
```
--font: ui-rounded, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, system-ui, sans-serif;
--mono: ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
```
`ui-rounded` renders SF Rounded on Safari (friendly); other browsers fall back gracefully. Scale: 12 / 14 / 16 / 17 (messages) / 20 / 28; line-height 1.4 body, 1.2 headings; weights 400 / 600 / 700.

### Option A — "Harbor" (calm teal, warm paper) — RECOMMENDED
Mood: calm, friendly, a shared room at home; warm neutrals and a single saturated teal. Soft but not childish.
| Token | Light | Dark |
|---|---|---|
| `--bg` | `#F5F2EC` | `#12151A` |
| `--surface` (header, sidebar, composer) | `#FFFFFF` | `#1B2027` |
| `--surface-2` (others' bubbles, inputs) | `#ECE8E0` | `#262C35` |
| `--border` | `#DAD4C8` | `#333A45` |
| `--text` | `#1C2024` | `#E8EBEF` |
| `--text-muted` | `#5A6068` (6.4:1 on bg) | `#A3ABB6` (7:1 on bg) |
| `--accent` (own bubble, primary btn) | `#0B6E75` | `#2BB5BD` |
| `--on-accent` | `#FFFFFF` | `#06191B` |
| `--accent-soft` (chips, selected row) | `#D5ECEC` | `#17383B` |
| `--success` | `#1F7A45` | `#5CCB8A` |
| `--warning` | `#8A5A00` | `#F0B35A` |
| `--danger` | `#B3261E` | `#FF8A80` |
| `--focus` | `#0B6E75` ring + white gap | `#7FD8DE` |

Contrast checks (approx): `#FFFFFF` on `#0B6E75` ≈ 5.9:1; `#1C2024` on `#F5F2EC` ≈ 14:1; `#06191B` on `#2BB5BD` ≈ 8:1. Header in light mode uses `--surface` (status bar white text issue: set status bar style per 2.1 and test; fallback give header an `#0B6E75` band? Option: header `--surface` and use `default` status style).
Shape: radius 18px bubbles (6px on the grouped inner corner), 12px cards/inputs, 999px chips and composer pill; borders 1px subtle, shadows only on sheets (`0 8px 24px rgb(0 0 0 / .18)`).
Spacing: 4px base: 4 / 8 / 12 / 16 / 24 / 32; message gap in group 2px, between groups 12px; gutters 16px (20px >= 600px).
User color palette (8, for avatar fills with **white** initials, >= 4.5:1; same in both themes, dark mode uses `filter: saturate(.9)` optional):
`#C2410C` orange, `#0E7490` cyan, `#7C3AED` violet, `#B4236B` magenta, `#15803D` green, `#1D4ED8` blue, `#A16207` ochre, `#BE123C` crimson.
(Tell the server agent this palette; Spec says server assigns from a fixed palette.)

### Option B — "Slate Signal" (neutral graphite, electric indigo)
Mood: efficient, tool-like, good for desktop and larger groups; flat-list friendly.
- Light: bg `#F4F5F7`, surface `#FFFFFF`, surface-2 `#E7E9EE`, text `#14171C`, muted `#5B6270`, accent `#4338CA` (on `#FFFFFF` 8:1), border `#D5D9E0`.
- Dark: bg `#0F1115`, surface `#171A20`, surface-2 `#222630`, text `#E9ECF2`, muted `#9AA3B2`, accent `#8B8CF8` with on-accent `#0F1020`, border `#2D3340`.
- Radius 10px (bubbles 12px), tighter spacing (3/6/10/14/20), 15px message text. More "pro", less warm; the indigo is close to many existing tools.

### Option C — "Sunroom" (playful, coral and sand, rounded)
Mood: family/party; big radii, chunky buttons, expressive avatars.
- Light: bg `#FFF8F0`, surface `#FFFFFF`, surface-2 `#F7E9DA`, text `#2B2118`, muted `#6E5C4B`, accent `#C2410C` (white text 5.2:1), border `#EBD9C6`.
- Dark: bg `#1A1411`, surface `#241C17`, surface-2 `#33271F`, text `#F6EBDD`, muted `#BBA48C`, accent `#FF9560` with on-accent `#2A1204`, border `#45352A`.
- Radius 22px bubbles, 16px cards; 17px text. Risk: orange accent collides with the "warning" semantic and with one of the user colors; less sober for office use.

### Recommendation: Option A "Harbor"
Rationale: (1) teal is distinct from blue/green messenger conventions yet reads as "connected/safe"; (2) warm paper light theme is gentle on a tablet used in a living room, dark theme is a true low-glare charcoal; (3) text/accent pairs pass AA comfortably, leaving room for the user-color palette; (4) the single accent keeps UI quiet so avatar colors carry identity; (5) rounded system font + 18px bubbles feel friendly without copying any specific app. Own bubble = teal with white text; others = warm grey surface-2.

---

## 6. Do / Don't rules

### For the design drafter
- DO design in both light and dark simultaneously; show tokens as CSS custom properties with names exactly as in 5 (`--bg --surface --surface-2 --border --text --text-muted --accent --on-accent --accent-soft --success --warning --danger`).
- DO specify the 8-color user palette, bubble group corner rules, and the min/max widths of the message column.
- DO include screens: start, server join, host-pairing step 1/2, guest-pairing step 1/2, empty room, chat (phone portrait), chat (iPad landscape with sidebar), people sheet, reconnecting banner, error state for bad code.
- DO show the stepper with explicit "Step 1 of 2" text and large Copy/Share buttons.
- DO annotate touch targets (>= 44px) and safe-area padding.
- DON'T clone iMessage/WhatsApp/Slack visuals (no tails, no green bubbles, no read-receipt ticks).
- DON'T use color alone for state; DON'T put text smaller than 12px; DON'T design a hover-only affordance.
- DON'T show cryptic protocol words (SDP, ICE, offer, answer) to users.

### For the front-end coder
- DO use `100dvh` grid layout with only the message list scrolling; composer in flow (not fixed); add the `visualViewport` fallback and re-sync after blur.
- DO set input/textarea `font-size: 16px` minimum; `enterkeyhint="send"`; keep focus on composer after send.
- DO use `env(safe-area-inset-*)`, `viewport-fit=cover`, apple meta tags, PNG `apple-touch-icon` 180px.
- DO use `textContent` for message text; `white-space: pre-wrap; overflow-wrap: anywhere` on bubbles; `dir="auto"`.
- DO implement `role="log"` list, `:focus-visible` rings, `prefers-reduced-motion`, `prefers-color-scheme`.
- DO stick to bottom only when near bottom; show "New messages" pill otherwise.
- DO wrap `localStorage`/`clipboard`/`share` calls in try/catch with fallbacks (select-all text, manual copy).
- DO extract `LC1.` tokens from pasted text, strip whitespace.
- DO feature-detect `navigator.share`, `CompressionStream`, QR lib; app works without them.
- DON'T use `position: fixed` for the composer, `100vh`, `maximum-scale`, or `user-scalable=no`.
- DON'T focus inputs on page load on touch devices.
- DON'T load web fonts or external CSS (offline LAN); only the optional QR script, with graceful absence.
- DON'T announce typing indicators or your own messages via aria-live.
- DON'T assume orientation or device; use container/viewport width breakpoints (600 / 900).
- DON'T trust `User.color`/`name` for markup; apply color via `style.setProperty('--user', hex)` after validating `/^#[0-9a-f]{6}$/i`.

---

## Sources
- iOS keyboard/viewport: [Fixing the iOS standalone PWA keyboard bug](https://dev.to/cederhook/fixing-the-ios-standalone-pwa-keyboard-bug-that-shrinks-your-viewport-for-good-63d), [Fix mobile keyboard overlap with visualViewport](https://dev.to/franciscomoretti/fix-mobile-keyboard-overlap-with-visualviewport-3a4a), [The Layout Maestro: Virtual Keyboard API](https://ishadeed.com/article/virtual-keyboard-api/), [Why CSS dvh ignores the mobile keyboard](https://dev.to/rl0425/why-css-dvh-ignores-the-mobile-keyboard-and-how-to-fix-it-31ao), [CSSWG issue 10464 (interactive-widget)](https://github.com/w3c/csswg-drafts/issues/10464), [Apple Developer Forums: Safari keyboard shifts viewport](https://developer.apple.com/forums/thread/824765)
- PWA on iOS: [web.dev PWA enhancements](https://web.dev/learn/pwa/enhancements), [Make Your PWAs Look Handsome on iOS](https://itnext.io/make-your-pwas-look-handsome-on-ios-fd8fdfcd5777), [Designing Native-Like PWAs for iOS](https://medium.com/appscope/1b3cdda1d0e8), [Changing the iOS status bar of your PWA](https://medium.com/appscope/changing-the-ios-status-bar-of-your-progressive-web-app-9fc8fbe8e6ab), [WebKit bug 236445](https://bugs.webkit.org/show_bug.cgi?id=236445), [Getting Save to Home Screen to kinda work on iOS](https://naildrivin5.com/blog/2023/08/24/braindump-of-pwa-on-ios.html)
- Manual WebRTC pairing: [Quick & dirty WebRTC manual signaling](https://peterchrjoergensen.pages.dev/blog/quick-dirty-webrtc-manual-signaling/), [Connect two WebRTC peers with manual signaling](https://dev.to/leoluo/connect-two-webrtc-peers-with-manual-signaling-1o2h), [serverless-webrtc-qrcode](https://www.github.com/fta2012/serverless-webrtc-qrcode), [w3c/webrtc-pc issue 2945 (consent timeouts)](https://github.com/w3c/webrtc-pc/issues/2945)
- General guidance relied on from knowledge (not re-fetched): WCAG 2.1 SC 1.4.3, 1.4.11, 2.4.7, 2.5.5 and ARIA `log` role (W3C); Apple Human Interface Guidelines (44pt minimum touch target); MDN on `env()`, `visualViewport`, `prefers-reduced-motion`, `Navigator.share`.
- Caveat: iOS status-bar and keyboard behavior varies by iOS version and sources are 2018-2025 blog posts; verify on a real iPad.
