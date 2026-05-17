# APEX Messenger — iOS Setup Guide

## What you need

| Requirement | Where to get it |
|-------------|----------------|
| Mac running macOS 13+ | — |
| Xcode 15 or later | Mac App Store (free) |
| Apple ID | appleid.apple.com (free) |
| iPhone / iPad running iOS 16+ | For device testing |

You do **not** need a paid Apple Developer account to run the app on your own device via Xcode.

---

## Step 1 — Get the code

Clone or download this repository so you have the full folder locally.

```
git clone <your-repo-url>
```

The relevant folders are:

```
APEX/
├── Package.swift               ← the APEX protocol Swift Package
├── Sources/APEX/               ← all protocol code
└── iOS/
    └── APEXMessenger/
        └── Sources/            ← the iOS app source files
```

---

## Step 2 — Create the Xcode project

1. Open **Xcode** and choose **File → New → Project…**
2. Select **iOS → App** and click **Next**
3. Fill in:
   - **Product Name:** `APEXMessenger`
   - **Bundle Identifier:** `com.yourname.APEXMessenger` (anything you like)
   - **Interface:** SwiftUI
   - **Language:** Swift
4. Click **Next**, choose a location to save, click **Create**

---

## Step 3 — Add the APEX Swift Package

1. In Xcode, go to **File → Add Package Dependencies…**
2. Click **Add Local…** (bottom-left of the dialog)
3. Navigate to the root of this repo (the folder containing `Package.swift`) and click **Add Package**
4. In the "Add to Target" prompt, select **APEXMessenger** and click **Add Package**

The APEX library is now linked. You'll see it under **Package Dependencies** in the Xcode project navigator.

---

## Step 4 — Add the app source files

Delete the placeholder files Xcode generated:
- Right-click `ContentView.swift` → **Delete** → Move to Trash
- Right-click `APEXMessengerApp.swift` → **Delete** → Move to Trash

Now drag **all files** from `iOS/APEXMessenger/Sources/` into the Xcode project navigator,
dropping them onto the **APEXMessenger** group (the blue folder icon):

```
Sources/
├── APEXApp.swift
├── Models/Models.swift
├── Storage/AppStorage.swift
├── Networking/ServerClient.swift
├── ViewModels/AppViewModel.swift
└── Views/
    ├── IdentitySetupView.swift
    ├── ConversationListView.swift
    ├── ChatView.swift
    ├── NewConversationView.swift
    ├── SafetyNumberView.swift
    └── ProfileView.swift
```

When the dialog appears, make sure:
- ☑ **Copy items if needed** is checked
- ☑ Target **APEXMessenger** is checked

---

## Step 5 — Set the server URL

Open `Networking/ServerClient.swift` and replace the placeholder:

```swift
// Line 22 — change this to your server address
private let baseURL = URL(string: "https://YOUR_SERVER_URL")!
```

> **No server yet?** Skip this for now. The app will compile and run — send/receive
> will just fail gracefully. You can test everything locally using the
> simulator with the demo mode below.

---

## Step 6 — Build and run

1. Select your device or a simulator from the toolbar (e.g. **iPhone 16 Pro**)
2. Press **⌘ R** (or the ▶ play button)
3. First launch: Xcode will ask to trust your developer certificate on the device — follow the prompt on your iPhone under **Settings → General → VPN & Device Management**

The app will open on the **Create Identity** screen.

---

## Running without a server (demo mode)

To test the full encryption flow locally with two simulator windows:

1. In Xcode, hold **Option** and click the **Run** button → change **Scheme** to a second instance
2. Or use two different simulators and paste pre-key bundles manually via the **Profile → Share My Bundle** button

The full X3DH + Double Ratchet session will execute locally end-to-end.

---

## Deploying to TestFlight (share with others)

To distribute via TestFlight you need a **paid Apple Developer account** ($99/year):

1. Enrol at [developer.apple.com](https://developer.apple.com)
2. In Xcode → **Signing & Capabilities**, set your Team
3. **Product → Archive**
4. In Organizer, click **Distribute App → TestFlight**
5. Follow the upload wizard — testers get an invite link within minutes

---

## Minimum server API

If you want real messaging you need a server with five endpoints.
A minimal Node.js/Express reference implementation:

```js
// server.js — minimal APEX relay server
const express = require('express')
const app = express()
app.use(express.json({ limit: '2mb' }))

const bundles = {}   // serverID → { displayName, bundle }
const inboxes = {}   // serverID → [envelopeData, ...]

// Register / upload bundle
app.post('/register', (req, res) => {
  const { serverID, displayName, bundle } = req.body
  bundles[serverID] = { displayName, bundle }
  inboxes[serverID] = inboxes[serverID] || []
  res.sendStatus(200)
})

// Fetch a peer's bundle
app.get('/bundle/:id', (req, res) => {
  const b = bundles[req.params.id]
  if (!b) return res.status(404).json({ error: 'not found' })
  res.json({ serverID: req.params.id, displayName: b.displayName, bundleData: b.bundle })
})

// Deliver an envelope
app.post('/send', (req, res) => {
  const env = req.body  // raw envelope bytes sent as JSON
  const recipientID = env.recipientID
  inboxes[recipientID] = inboxes[recipientID] || []
  inboxes[recipientID].push(req.body)
  res.sendStatus(200)
})

// Fetch inbox (simple poll — use WebSockets/APNs for production)
app.get('/inbox/:id', (req, res) => {
  const msgs = inboxes[req.params.id] || []
  inboxes[req.params.id] = []   // clear after delivery
  res.json(msgs)
})

app.listen(3000, () => console.log('APEX relay listening on :3000'))
```

Run with:
```bash
npm install express
node server.js
```

For local testing on simulator, set the server URL to `http://localhost:3000`.
For real use, deploy behind HTTPS (Render, Railway, Fly.io all have free tiers).

---

## File reference

| File | Purpose |
|------|---------|
| `APEXApp.swift` | App entry point, root view routing |
| `Models/Models.swift` | Data types: Conversation, Message, StoredIdentity |
| `Storage/AppStorage.swift` | JSON persistence in Documents directory |
| `Networking/ServerClient.swift` | HTTP calls to relay server |
| `ViewModels/AppViewModel.swift` | All APEX protocol logic, session management |
| `Views/IdentitySetupView.swift` | First-launch key generation screen |
| `Views/ConversationListView.swift` | Chat list |
| `Views/ChatView.swift` | Individual chat + message bubbles |
| `Views/NewConversationView.swift` | Start a conversation by User ID |
| `Views/SafetyNumberView.swift` | Safety number verification |
| `Views/ProfileView.swift` | Your identity + key fingerprint |
