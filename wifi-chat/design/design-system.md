# LAN Chat — Design System ("Harbor")

Handoff spec for the front-end coder. Visual reference: `design/mockup.html` (open it, toggle light/dark, use the tabs). Tokens below are the single source of truth; the mockup uses the identical block. Calm teal on warm paper; system fonts only; no external assets.

Rules of thumb: design by container width (600 / 900), text >= 12px, inputs >= 16px, targets >= 44px, never color alone, never show protocol words (no "SDP", "ICE", "offer", "answer", "peer", "WebRTC" in UI text).

---

## 1. Tokens (paste into `styles.css`)

```css
:root {
  color-scheme: light dark;

  /* color: light */
  --bg: #F5F2EC;          --surface: #FFFFFF;      --surface-2: #ECE8E0;
  --border: #DAD4C8;      --text: #1C2024;         --text-muted: #5A6068;
  --accent: #0B6E75;      --on-accent: #FFFFFF;    --accent-soft: #D5ECEC;
  --success: #1F7A45;     --warning: #8A5A00;      --danger: #B3261E;
  --success-soft: #DDF0E4; --warning-soft: #F8EBCF; --danger-soft: #F9DEDC;
  --focus: #0B6E75;       --scrim: rgb(20 22 26 / .45);
  --shadow-sheet: 0 8px 24px rgb(0 0 0 / .18);
  --shadow-pop: 0 4px 14px rgb(0 0 0 / .14);

  /* user palette (server assigns; avatar fill, white initials >= 4.5:1, same in both themes) */
  --u1: #C2410C; --u2: #0E7490; --u3: #7C3AED; --u4: #B4236B;
  --u5: #15803D; --u6: #1D4ED8; --u7: #A16207; --u8: #BE123C;

  /* type */
  --font: ui-rounded, -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, system-ui, sans-serif;
  --mono: ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace;
  --fs-xs: .75rem;   /* 12  time, badges, counter */
  --fs-sm: .875rem;  /* 14  captions, names, system msgs */
  --fs-md: 1rem;     /* 16  UI text, inputs, buttons */
  --fs-msg: 1.0625rem; /* 17 message text */
  --fs-lg: 1.25rem;  /* 20  screen titles, header room name */
  --fs-xl: 1.75rem;  /* 28  start-screen title */
  --lh-body: 1.4;    --lh-head: 1.2;
  --fw-regular: 400; --fw-semi: 600; --fw-bold: 700;

  /* spacing (4px base) */
  --s1: 4px; --s2: 8px; --s3: 12px; --s4: 16px; --s5: 24px; --s6: 32px; --s7: 48px;
  --gap-in-group: 2px; --gap-between-groups: 12px;
  --gutter: 16px;                 /* 20px at >= 600 */

  /* radii */
  --r-bubble: 18px; --r-bubble-tight: 6px; --r-card: 12px; --r-sheet: 20px; --r-pill: 999px;

  /* motion */
  --dur-fast: 120ms; --dur: 180ms; --dur-sheet: 250ms;
  --ease: cubic-bezier(.2, .7, .2, 1);

  /* z-index */
  --z-pill: 20; --z-banner: 30; --z-header: 40; --z-sheet: 60; --z-toast: 80;

  /* layout */
  --sidebar-w: 280px;   --col-max: 760px;   --card-max: 480px;
  --bubble-max: min(34rem, 78%);
  --tap: 44px;          --tap-primary: 52px;
  --sat: env(safe-area-inset-top);    --sar: env(safe-area-inset-right);
  --sab: env(safe-area-inset-bottom); --sal: env(safe-area-inset-left);
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #12151A;        --surface: #1B2027;      --surface-2: #262C35;
    --border: #333A45;    --text: #E8EBEF;         --text-muted: #A3ABB6;
    --accent: #2BB5BD;    --on-accent: #06191B;    --accent-soft: #17383B;
    --success: #5CCB8A;   --warning: #F0B35A;      --danger: #FF8A80;
    --success-soft: #1A3326; --warning-soft: #3A2D12; --danger-soft: #3F1F1D;
    --focus: #7FD8DE;     --scrim: rgb(0 0 0 / .6);
    --shadow-sheet: 0 8px 24px rgb(0 0 0 / .5);
    --shadow-pop: 0 4px 14px rgb(0 0 0 / .45);
  }
}
/* manual override (optional toggle; persist in localStorage inside try/catch) */
:root[data-theme="dark"] { /* same values as the dark block above */ }

@media (min-width: 600px) { :root { --gutter: 20px; } }

@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: .01ms !important; animation-iteration-count: 1 !important;
    transition-duration: .01ms !important; scroll-behavior: auto !important; }
}
```

Breakpoints (by width of the app root): `< 600` single column, phone; `600–899` single column, wider gutters; `>= 900` two panes (sidebar 280px + chat; message column max 760px, centered). Never assume orientation.

Name/initial colors: avatar fill = `var(--user)` (validate `/^#[0-9a-f]{6}$/i`, set via `style.setProperty`), initials always `#fff`. Sender-name text is NOT the raw color: `color: color-mix(in oklab, var(--user) 55%, var(--text))`. Fallback if color-mix unsupported: `var(--text)`.

---

## 2. Components

Common: `font-family: var(--font)`, `-webkit-tap-highlight-color: transparent`, buttons `touch-action: manipulation`, `:focus-visible { outline: 3px solid var(--focus); outline-offset: 2px }` everywhere, hover only inside `@media (hover: hover)`, active = `filter: brightness(.94)` / scale .98.

**App shell.** `height: 100dvh` grid `auto auto 1fr auto` (header, banner slot, messages, composer). Only the message list scrolls. Composer is in flow (never `position: fixed`). Wide: `grid-template-columns: var(--sidebar-w) 1fr`, sidebar spans all rows.

**App header.** Height 56px + `max(0px, var(--sat))` top padding; side padding `max(var(--gutter), var(--sal/--sar))`; bg `--surface`, bottom border `--border`. Left: room name (`--fs-lg`, 700, ellipsis) over status line (dot 8px + text, `--fs-sm` 14, muted). Status: connected = `--success` dot + "Connected"; connecting/reconnecting = `--warning` dot pulsing + "Reconnecting…"; disconnected = `--danger` dot + "Offline". Right: People button (44px tall pill: facepile of up to 3 avatars 24px overlapped -8px + "4 online"; hidden at >= 900 because sidebar shows people). Host mode adds a ghost "Add person" icon button (44x44).

**Avatar.** 32px circle (36px at >= 900), bold 13px initials (1–2 chars, uppercase), `--user` fill, white text. `aria-hidden="true"` (name is always in text). Sizes: 24 (facepile), 32, 40 (sheet rows).

**Message group / bubble.**
- Row: `max-width: var(--col-max)` centered, padding-inline `var(--gutter)`. Others: avatar column (32px + 8px gap) then content; avatar on the FIRST message of a group; later messages keep the 40px indent.
- Bubble: padding 8px 14px, `--fs-msg`, line-height 1.4, `max-width: var(--bubble-max)`, `white-space: pre-wrap; overflow-wrap: anywhere`, `dir="auto"`, `user-select: text`.
- Others: bg `--surface-2`, text `--text`. Own: bg `--accent`, text `--on-accent`, right-aligned, no name/avatar.
- Group rule (same user, gap < 5 min, no system msg between): gap in group 2px, between groups 12px.
- Corners (radius 18px; "tight" = 6px on the sender's side):
  | position | others (left) | own (right) |
  |---|---|---|
  | single | 18 all | 18 all |
  | first | bottom-left 6 | bottom-right 6 |
  | middle | top-left 6, bottom-left 6 | top-right 6, bottom-right 6 |
  | last | top-left 6 | top-right 6 |
- Sender name: shown above the first bubble of a group (others only), `--fs-sm`, 600, mixed user color (above), margin-left 4px.
- Time: `<time>` `--fs-xs`, `--text-muted`, tabular-nums, below the LAST bubble of a group, aligned to the bubble side.
- States: pending = 60% opacity; failed = bubble with 1px `--danger` outline + line below "Not sent. Tap to try again." (danger text with alert icon, whole row is a button).
- Appear animation: opacity 0→1 + translateY(6px→0), `--dur` `--ease`.

**Time divider.** Centered text `--fs-xs` 600 muted, with hairline rules each side (`--border`); shown when gap > 30 min or day changes. Copy: "Today 14:05", "Yesterday 21:40", "Mon 09:12", "12 Oct 18:30".

**System message.** Centered, `--fs-sm`, muted, no bubble, optional 6px dot. Bursts collapse ("Anna, Ben and 2 others joined"). Copy: "Maya joined", "Theo left", "You are now Sam 2".

**Typing indicator.** Fixed 24px-high slot at the bottom of the message region (height always reserved). 3 dots 6px, `--text-muted`, staggered bounce 1s infinite; text `--fs-sm` muted: "Priya is typing", "Priya and Theo are typing", "Several people are typing". Reduced motion: static "…". `aria-hidden="true"` (not announced).

**Composer.** Bar bg `--surface`, top border, padding `8px max(12px, var(--sar)) max(8px, var(--sab)) max(12px, var(--sal))`. Inner pill: flex, bg `--surface-2`, radius 22px, 1px border; `<textarea rows=1>` flex 1, 16px+ font (`--fs-msg`), padding 11px 14px, auto-grow 1–5 lines (max-height 9rem then scroll), transparent bg, no own border; focus-within pill gets 2px `--accent` border + focus ring. Send: 44px circle, `--accent` / `--on-accent`, arrow icon, margin 4px inside pill; disabled (empty or offline) = `--surface-2` bg with `--border` outline, `--text-muted` icon, `aria-disabled`. Counter: appears at >= 1800 chars, `--fs-xs`, right-aligned above pill: "1,912 / 2000"; >= 2000 turns `--danger` + "Message is too long"; send disabled when > 2000. Offline: textarea stays editable (draft kept), placeholder "Waiting to reconnect…", send disabled. Placeholder "Message".

**"New messages" pill.** Absolute, centered, 12px above the composer, z `--z-pill`. 40px tall (hit area padded to 44), radius pill, bg `--accent`, `--on-accent`, `--fs-sm` 600, shadow-pop, down-arrow icon. Text "2 new messages" / "1 new message". Shown only when scrolled up > 80px.

**Reconnecting banner.** Slim row under header, `role="status"`, 40px, `--fs-sm`, icon + text. Reconnecting: `--warning-soft` bg, `--warning` text, spinner. Offline: `--danger-soft` bg, `--danger` text. Copy below. Slides down `--dur`.

**People list row (sidebar / sheet).** Min height 56px, padding 8px 16px, avatar 40, name (`--fs-md`, 600, ellipsis), right-side chips. Chips: "Host" (`--accent-soft` bg, `--accent` text, `--fs-xs` 700, radius pill, 4px 8px) and "You" (outlined `--border`, muted). Sort: you, host, then A–Z. Rows stay neutral; only the chips mark host and you. Sidebar: width 280, bg `--surface`, right border, header "People · 4" (`--fs-sm` 700 muted). Sheet: bottom sheet on < 600 (radius top 20, grabber, max-height 80dvh, scrim), popover card 340px top-right on 600–899; `role="dialog" aria-modal="true" aria-labelledby`. Host footer in sheet/sidebar: secondary button "Add another person".

**Buttons.** Height `--tap-primary` 52 (primary) / 44 (secondary, ghost), padding-inline 20px, radius 12px, `--fs-md`, 600, icon 20px + 8px gap.
- Primary: bg `--accent`, text `--on-accent`. Secondary: bg `--surface`, 1px `--border`, text `--text`. Ghost: transparent, text `--accent`. Danger (rare, "End chat"): text `--danger`, ghost style.
- Disabled: 45% opacity, no pointer events, `aria-disabled`. Loading: spinner replaces icon, label stays ("Preparing…"), width unchanged.
- Full width in cards on phone; on wide, card max `--card-max`.

**Text field.** Label above (`--fs-sm`, 600), input 52px tall, 16px font, bg `--surface`, 1px `--border`, radius 12px, padding 0 14px. Focus: border `--accent` + 3px focus ring. Error: border `--danger`, message below with alert icon in `--danger` (`role="alert"` once). Helper text `--fs-sm` muted. Code textarea: `--mono` 14px (font-size stays >= 16px if editable on iOS: use 16px), 4 rows, `word-break: break-all`, `autocapitalize=off autocorrect=off spellcheck=false`. "Looks like a valid code" success line with check in `--success`.

**Code box (invite/reply code).** Read-only monospace panel: bg `--surface-2`, 1px border, radius 12px, padding 12px, 3 lines tall (`max-height: 4.5em`, overflow hidden) with bottom fade to bg; toggle "Show full code" / "Hide code" (ghost, 44px); caption right "1.2 KB". Tap selects all. Below: row `[Copy code (primary, flex 1)] [Share… (secondary)]`; Share only if `navigator.share`. Copy → label "Copied" + check for 2s, `aria-live="polite"` status "Code copied". QR: white 220px+ square, 16px white quiet zone, radius 12 (white even in dark mode), above "Or send as text"; if code too long: hide QR, show muted note "This code is too long for a QR picture. Use Copy or Share." On >= 600 QR and text sit side by side.

**Stepper.** Header row of card: text "Step 1 of 2" (`--fs-sm`, 700, `--accent`) + title below (`--fs-lg`). Beneath, a 2-segment bar (6px high, radius pill; done/current = `--accent`, upcoming = `--border`), `<ol>` with `aria-current="step"`. Do not rely on the bar alone.

**Toast.** Bottom-center above composer (`bottom: 72px + safe`), max-width 90vw/360px, bg `--text` / text `--bg` (inverted), radius 12, padding 12px 16px, `--fs-sm`, icon left, shadow-pop; `role="status"`, auto-dismiss 3s (5s for errors, with dismiss), slide-up `--dur`. Copy: "Maya joined", "Code copied", "Could not copy. Select the code and copy it by hand."

**Error message (inline).** Row: alert icon + text, `--danger` text on `--danger-soft` bg, radius 12, padding 12px, `--fs-sm`; includes a recovery action button (ghost) where one exists. Info/success/warning variants swap the soft color pair.

**Info note.** "How does this work?" is a `<details>`; summary 44px high, ghost style; body `--fs-sm` muted.

---

## 3. Screens and copy

All copy is final unless a string is marked {var}.

### 3.1 Start screen (browser-host mode, no server)
- Title (`--fs-xl`): **LAN Chat** — subtitle: "Chat with people on the same WiFi. No internet or accounts needed."
- Card 1 (88px+ tall, icon, title, line): **Host a chat on this device** / "This device becomes the room. Others connect to you."
- Card 2: **Join a chat** / "Someone is already hosting. You will paste their invite."
- Hint (quiet, `<details>`): "Have a computer? Run server mode" → body "Run `node server/server.js` on any computer on your WiFi, then open the address it prints on every device. Guests just type their name."
- Footer note: "Works on the same WiFi only."

### 3.2 Name screen (server mode, also first step of host/join)
- Title: room name from the server (e.g. "Cedar Street Chat"); caption "{n} online" if known.
- Field: label "Your name", placeholder "e.g. Sam", helper "Up to 24 characters."
- Primary: **Join chat** (host-mode variant: **Continue**). Return visit: "Continue as {name}" primary + ghost "Change name".
- Error: "Pick a name, up to 24 characters."
- Host start also asks "Room name" (default "{name}'s chat"), then goes to Host pairing.

### 3.3 Host pairing (2 steps; guest-by-guest)
- Step 1 of 2, title **Send this invite to {guest or "your guest"}**: Preparing state: button "Preparing invite…" with spinner. Ready: code box + **Copy invite** + **Share…** + QR. Caption "Valid for about 5 minutes. Created {n} s ago." Primary at bottom: **Next: I have their reply**. Ghost: **Cancel**. Disclosure "How does this work?": "Send this invite to the other person (message, AirDrop or QR). They open LAN Chat, choose Join a chat and paste it. They send you a reply code back. Everyone must be on the same WiFi. No internet needed."
- Step 2 of 2, title **Paste their reply**: textarea + ghost **Paste from clipboard**. On valid: "Looks like a valid code" and primary **Connect** enables. Connecting: "Connecting…" spinner. Success: toast "{name} joined" and card "{name} is connected." with primary **Back to chat** and secondary **Add another person** (returns to step 1 with a fresh invite).
- Errors: "That code does not look right. Make sure you copied all of it." / "This reply was already used. Ask them for a new one." / "Could not connect. Are you both on the same WiFi?" with **Make a new invite**.
- Host warning (chat header banner, dismissible, host mode only): "You are hosting. If you close this tab or lock the screen, the chat ends for everyone."
- Host status line in header: "Hosting · 3 connected".

### 3.4 Guest pairing
- Step 1 of 2, title **Paste the invite**: textarea, **Paste from clipboard**, name field (if not yet entered), primary **Continue**. Preparing: "Preparing reply…".
- Step 2 of 2, title **Send your reply to {host name or "the host"}**: code box + **Copy reply** + **Share…** + QR. Status: pulsing dot + "Waiting for the host to accept…". Ghost **Cancel**. Auto-advances to Chat on connect; toast "You joined {room}".
- Errors: same strings as host, plus "This invite has expired. Ask for a new one." and "Could not connect. Are you both on the same WiFi?" with **Try again** (keeps the name).

### 3.5 Chat
- Header: room name, status, People button "{n} online" (< 900). Phone portrait: single column. iPad landscape (>= 900): sidebar 280 + message column.
- Composer placeholder "Message". Send button `aria-label="Send"`.
- Empty room: centered, icon, **You're the first one here**, "Say hello, or invite someone to join." Host: primary **Add a person**; server mode: shows address "Open http://192.168.1.23:8080 on another device" in a copyable code row.
- Loading history: skeleton not needed; render instantly.
- Banners: reconnecting "Reconnecting… You can keep typing; sending resumes when you are back." (messages are not queued). Offline: "You are offline. Trying again every few seconds." with ghost **Retry now**. Host closed: card "The host ended the chat." + primary **Back to start**.
- Error toast on rejected send: "Message not sent. {reason}" (e.g. "Messages can be up to 2000 characters.").

---

## 4. Interaction, accessibility, platform

- **Keyboard:** Enter sends, Shift+Enter newline (both hardware and software keyboard; `enterkeyhint="send"`); Esc closes sheets/details; Tab order header, people, messages, composer. Send via `pointerdown` + `preventDefault()` so focus and the iPad keyboard stay put.
- **Focus:** after Join/Continue move focus to composer (user-initiated only; never autofocus on load for touch). Dialogs trap focus, restore it to the opener on close, set background `inert`. Step change moves focus to the new step's heading (`tabindex="-1"`) and announces "Step 2 of 2" in a visually hidden `aria-live="polite"` region.
- **ARIA:** header `<header>`, messages `<main>` containing `<ol role="log" aria-label="Messages">` (polite, additions), each `<li>` begins with visually hidden "{name}, {time}:" (own: no announce). Sidebar `<aside aria-label="People">`. Composer `<form>` with hidden `<label>` "Message". Status banner `role="status"`; blocking errors `role="alert"` (once). Typing indicator not announced. Stepper `<ol>` with `aria-current="step"`. Icon-only buttons need `aria-label`. Load history before enabling the live region so it is not read out.
- **Scroll:** stick to bottom only within 80px; else show "New messages" pill. `overscroll-behavior-y: contain` on the list.
- **Reduced motion:** no bounce/pulse/slide; only <=150ms opacity fades; typing text static.
- **Safe areas / viewport:** `viewport-fit=cover`; header, composer, sidebar, list gutters use `env(safe-area-inset-*)` (see tokens); `html,body{overflow:hidden;overscroll-behavior:none}`; add the `visualViewport` resize fallback (`--vvh`) from research.md section 2.3; text size `-webkit-text-size-adjust:100%`.
- **Targets:** every tappable thing >= 44x44 (visible element may be smaller, pad the hit area); 8px minimum between adjacent targets; primary actions 52px.
- **Color:** state is dot/icon + text, never color alone. Contrast checked for every token pair listed; do not introduce new greys.
- **Theme:** follow system; optional manual Light/Dark/Auto toggle sets `data-theme` on `<html>`. Update `<meta name="theme-color">` for both schemes (#F5F2EC / #12151A).
- **Security:** message text via `textContent` only; user colors validated before use.
