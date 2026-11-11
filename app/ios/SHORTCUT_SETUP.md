# iOS "Process Bank SMS" — Shortcut & Share Extension Setup

This guide wires the **fully implemented** iOS capture path so a bank SMS can reach
Mali's existing parsing pipeline (`ParserEngine` → `AddTransactionUseCase`) two ways:

1. **App Intent / Shortcut** — an action named **"Process Bank SMS"** that takes the
   raw SMS text plus optional metadata and stores it in Mali's App Group queue
   without opening the Flutter UI whenever iOS allows background execution.
2. **Share Extension** — share any selected text into Mali from the share sheet.

Both write to a shared **App Group** FIFO queue. If Mali is already running, the
native layer posts a lightweight notification to Flutter that pending messages
exist. When Mali opens, resumes, or receives that native callback, Flutter drains
the queue and runs the normal parsing/confirm flow.

> iOS cannot read SMS automatically (no API for it). This Shortcut + Share Extension
> approach is the supported way to feed bank messages in. Pair it with a Personal
> Automation (below) for a near-automatic experience.

---

## 0. What's already in the repo

| File | Target | Purpose |
| --- | --- | --- |
| `ios/Runner/AppDelegate.swift` | Runner | Method channel `money_companion/native_capture`; handles `consumePendingSharedMessages`. |
| `ios/Runner/SharedCaptureStore.swift` | Runner | FIFO queue in the App Group. |
| `ios/BankMessageShortcuts/BankMessageShortcuts.swift` | **BankMessageShortcuts** (App Intents ext.) | `PostBankStatusIntent`, capture service, dependency injection seam, and `AppShortcutsProvider`. |
| `ios/BankMessageShortcuts/SharedCaptureStore.swift` | BankMessageShortcuts | Identical copy of the queue with structured payloads, pending status, locale, received time, and pending-queue dedupe. |
| `ios/BankMessageShortcuts/Localizable.xcstrings` | BankMessageShortcuts | English + Arabic App Intent localization. |
| `ios/ShareBankMessage/ShareViewController.swift` | **ShareBankMessage** (Share ext.) | Enqueues shared text. |
| `ios/ShareBankMessage/SharedCaptureStore.swift` | ShareBankMessage | Identical copy of the queue. |

The three `SharedCaptureStore.swift` copies are byte-identical on purpose — Swift
targets don't share source automatically. If you change one, change all three.

Flutter side: `NativeCaptureBridge.consumePendingSharedMessages()` and
`AppShell._consumeSharedInput()` already drain the queue on launch and on resume.

---

## 1. App Group (required, do this first)

The App Group identifier is hard-coded in all three stores:

```
group.com.youssefsafwat.mali
```

> If you change the app's bundle ID away from `com.youssefsafwat.mali`, update
> `appGroupIdentifier` in **all three** `SharedCaptureStore.swift` files to match.

1. Apple Developer portal → **Certificates, Identifiers & Profiles → Identifiers**.
2. Create an **App Group**: `group.com.youssefsafwat.mali`.
3. Enable it for the App ID of **each** of the three targets (app + 2 extensions).

In Xcode, for **Runner**, **BankMessageShortcuts**, and **ShareBankMessage**:
- Target → **Signing & Capabilities → + Capability → App Groups**.
- Tick `group.com.youssefsafwat.mali`.

---

## 2. Add the two extension targets in Xcode

> The `.swift` source files exist in the repo, but the Xcode **targets** must be
> created once (the `.xcodeproj` isn't generated from the folder layout).

### 2a. App Intents extension — `BankMessageShortcuts`
1. `open ios/Runner.xcworkspace`.
2. **File → New → Target… → App Intents Extension** (or "Extension" → App Intents).
3. Product name: **BankMessageShortcuts**. Embed in **Runner**.
4. Delete the auto-generated sample `.swift` files for that target.
5. Add the existing files to the target (right-click → *Add Files to "Runner"*, or
   drag from `ios/BankMessageShortcuts/`): `BankMessageShortcuts.swift` and
   `SharedCaptureStore.swift`. Confirm **Target Membership = BankMessageShortcuts**.
6. Deployment target: **iOS 16.0+** (the intent is `@available(iOS 16.0, *)`).

### 2b. Share extension — `ShareBankMessage`
1. **File → New → Target… → Share Extension**. Product name: **ShareBankMessage**.
2. Delete the generated `ShareViewController.swift` / storyboard sample logic and add
   the repo's `ios/ShareBankMessage/ShareViewController.swift` +
   `SharedCaptureStore.swift`. Confirm **Target Membership = ShareBankMessage**.
3. In that target's `Info.plist`, set `NSExtensionActivationRule` to accept text, e.g.:
   ```xml
   <key>NSExtensionActivationRule</key>
   <dict>
     <key>NSExtensionActivationSupportsText</key>
     <true/>
   </dict>
   ```

---

## 3. Signing

Each extension is its own binary and needs its own provisioning:
- Select each target → **Signing & Capabilities** → enable **Automatically manage
  signing** → pick your Team. Xcode creates `….BankMessageShortcuts` and
  `…ShareBankMessage` App IDs under the Runner bundle ID.
- All three targets must share the same **Team** and the **App Group** from step 1.

---

## 4. Build & install

On a Mac with Xcode:
```bash
cd app
flutter build ios --release        # or: flutter run -d <device>
```
From Windows you can't build iOS locally — use a cloud Mac (Codemagic / GitHub Actions
macOS runner) to produce the `.ipa`, then sideload with your usual tool.

---

## 5. Using it

### As a Shortcut (manual)
- Open **Shortcuts → +** → search the action **"Process Bank SMS"**.
- Pass it text through **SMS Text**. In a Message automation, set **SMS Text**
  to **Shortcut Input**.
- Run it → the payload is stored silently when iOS allows it. Mali processes it
  when the app is available.

### Near-automatic (Personal Automation)
- Shortcuts app → **Automation → + → Message** → *Message Contains* the bank's name,
  or *When I get a message from* the bank's short code.
- Action: **Process Bank SMS**, **SMS Text** = *Shortcut Input* (the message text).
  Optional fields such as sender, received date, and locale can be left empty.
- Final shape should be: **Receive messages as input** → **Process Bank SMS**.
- Turn **Run Immediately** on. If Shortcuts shows **Notify When Run**, turn it
  off. Open the **Process Bank SMS** action details and turn **Show When Run**
  off if it appears.

### Preconfigured per-keyword shortcuts
Since iOS 26 a shared shortcut can carry its own Message trigger, so one link
per keyword ("Message contains EGP", "… جم", "… USD", …) installs with the
keyword already set. The published **QIRSH** link is the EGP one.

- Build the variants (macOS, signed in to iCloud), from `app/`:
  `python3 tools/shortcuts/build_qirsh_shortcuts.py` → signed files in
  `build/qirsh_shortcuts/`. Each one differs from `tools/shortcuts/qirsh_template.plist`
  only in the trigger keyword and UUIDs; the Process Bank SMS call is identical.
- Publishing is manual: open each `Qirsh <keyword>.shortcut`, add it, then
  **Share → Copy iCloud Link**. Install the link on a phone and confirm the
  trigger shows the right keyword before using it.
- Only then add the link as `installUrl` in `qirshShortcutKeywords`
  (`lib/features/onboarding/shortcut_setup_actions.dart`). A keyword without a
  link keeps the shared QIRSH template plus the edit-the-filter step.
- iOS still requires the user to open the automation, turn it on and turn
  **Confirm Before Run** off; no API can do this or read it back. The app
  records only a fresh connection test (probe) and the user's own confirmation.
- Use one keyword per currency: two automations matching one SMS (for example
  "جم" and "جنيه") each send it, and Qirsh shows the second as a possible duplicate.

### Share sheet
- In Messages, long-press the bank SMS → **Share** (or select text → Share) → **Mali**.
- Mali opens and processes it.

---

## 6. How the data flows

```
Shortcut "Process Bank SMS"            Share sheet → Mali
        │  (message, sender?)                │  (selected text)
        ▼                                    ▼
PostBankStatusIntent.perform()      ShareViewController.didSelectPost()
        │                                    │
        └──────────► SharedCaptureStore.enqueue(text:sender:) ◄────────┘
                              │  (App Group UserDefaults, FIFO queue)
                              ▼
        App launch / resume → AppDelegate channel
        "consumePendingSharedMessages" → JSON array
                              ▼
        NativeCaptureBridge.consumePendingSharedMessages()
                              ▼
        AppShell._consumeSharedInput() loops each message →
        CapturedMessageProcessor.process(rawMessage, senderId, receivedAt) →
        ParserEngine + AddTransactionUseCase → confirm sheet
```

The queue is cleared atomically when consumed (`consumePendingPayloadsJSON()` removes
the key), and a legacy single-string key is migrated in for backwards compatibility.

---

## 7. Troubleshooting

- **Nothing happens on open** — App Group not enabled on all 3 targets, or the
  identifier differs from `group.com.youssefsafwat.mali`.
- **Action missing in Shortcuts** — the App Intents extension didn't build/embed, or
  the device is below iOS 16. Reinstall the app; iOS indexes intents on install.
- **Share sheet doesn't show Mali** — `NSExtensionActivationRule` doesn't accept text.
- **Multiple messages lost** — make sure all three `SharedCaptureStore.swift` are the
  current FIFO version (`queueKey = "pending_bank_messages_v2"`), not an old copy.

---

## 8. Requirements summary

- **Apple Developer Program** account (paid) — required to sign app extensions.
- **Xcode on macOS** to create the two extension targets once and to build.
- **iOS 16.0+** for App Intents (Share Extension works on older iOS too).
- One **App Group**: `group.com.youssefsafwat.mali`, enabled on Runner +
  both extensions, all on the same Team.
