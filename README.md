# Brownmellon

Voice-first AI assistant on Ray-Ban Meta Gen 2 glasses + companion iOS app, for adults 60+. See `PRD.md` for the full spec, and `.lavish/index.html` for platform feasibility research (DAT capabilities, battery data, legal risk).

This is the **unified project** — one Xcode project, one Vercel backend, all three workstreams' code living side by side under a single layout. Each workstream started in its own git worktree (see PRD § Parallel workstreams); this integration pass reconciled them onto `main` so anyone can build the whole app and pick up any feature from here.

## Status by feature

| # | Feature | Workstream | Status |
|---|---|---|---|
| 1 | Voice scheduling/reminders | A — Voice & Calendar | Real backend (`api/parse-intent.ts`) + coordinator/wake-word logic, unit-tested. Manual "try it" field stands in for a mic on Simulator (`SchedulingView`). |
| 2 | Daily briefing | A | Same coordinator as #1. |
| 3 | Appointment-card scanning | B — Vision & Documents | Real backend + full iOS flow, verified building and launching on Simulator. |
| 4 | "Read this to me" | B | Same backend endpoint as #3, different mode. |
| 5 | Advertisement scam detection (OCR-only) | C — Safety & Emergency | **New scaffold added in this pass** — real backend (`api/scam-check.ts`) + manual-trigger UI, same shape as #3/#4. Not yet voice-triggered or hardware-tested. |
| 6 | Emergency contact | C | **New scaffold added in this pass** — caregiver setup screen, Keychain-backed contact storage, `tel:` call placement. The PRD's dedicated always-on trigger phrase (bypassing the general NLU pipeline) is real device/DAT work and is **not implemented** — see `EmergencyCallService.swift`. |

Nothing talks to the real glasses yet (Meta DAT wrapper doesn't exist) or the real Google Calendar (needs a Google Cloud OAuth client ID — one-time setup, PRD § Deployment). Everything runs against mocks that are real enough to demo and test on Simulator with zero hardware — see "What's mocked" below.

## Layout

```
backend/                       One Vercel project, one endpoint per feature area
  api/ocr.ts                     Features 3–4 (Gemini)
  api/parse-intent.ts            Features 1–2 (Claude)
  api/scam-check.ts              Feature 5 (Gemini)
ios/
  project.yml                    XcodeGen source of truth — regenerate after any edit
  Brownmellon/
    App/BrownmellonApp.swift     Wires mocks to every feature's entry view
    Core/                        Shared protocols + real/mock implementations
      Interfaces.swift             GlassesSession, CalendarService, SecureLocalStore
      GoogleCalendarService.swift  Real, not wired up (needs OAuth client ID)
      KeychainSecureLocalStore.swift  Real, used by Setup
      Mocks/                      MockGlassesSession, MockCalendarService, MockSecureLocalStore
    Features/
      Scheduling/                 Features 1–2 (Workstream A)
      Vision/                     Features 3–4 (Workstream B)
      Safety/                     Feature 5 (Workstream C)
      Setup/                      Feature 6 (Workstream C)
  BrownmellonTests/              WakeWordDetectorTests
```

**Adding a feature or picking one up:** put backend logic in its own `backend/api/*.ts` file (stateless, one inference call in, structured JSON out — copy `ocr.ts` or `scam-check.ts`'s shape), and iOS code in its own `Features/<Name>/` folder against the `Core/Interfaces.swift` protocols. Wire the new view into `BrownmellonApp.swift`'s `TabView`. Don't touch another feature's files — that's what kept the original three workstreams merge-conflict-free, and it still holds.

## What's mocked, and why

- **`MockGlassesSession`** — real on-device text-to-speech (`AVSpeechSynthesizer`) for `speak`, the system photo picker for `capturePhoto`, and a stored transcript callback (`simulateTranscript(_:)`) for `startListening`/`stopListening` so Scheduling's wake-word path is exercisable without a mic. Swap for the real DAT-backed session once that lands — no other code should need to change, that's the point of the protocol.
- **`MockCalendarService`** — in-memory, resets on relaunch. `GoogleCalendarService` is real and compiles clean against `GoogleSignIn-iOS` 7.1.0, but needs a Google Cloud OAuth client ID (PRD § Deployment) before it's usable.
- **`MockSecureLocalStore`** — in-memory. `KeychainSecureLocalStore` is real (Keychain-backed, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) and is a straight swap once someone wants Setup's data to actually persist.
- **Voice triggers** for Features 3–5 are manual button taps — Workstream A's `WakeWordListener`/`SchedulingCoordinator` only routes to Scheduling today. Extending it to dispatch "Hey Dojo, scan this" / "check this ad" to the other features' view models is the natural next step (their `scan()` / `checkAd()` methods are already designed as the integration seam).
- **Feature 6's dedicated emergency phrase** (its own always-on listener, independent of the general wake-word pipeline per PRD § Feature 6) isn't implemented — that's real device/DAT work, not something to fake convincingly on Simulator. `EmergencyCallService` only covers placing the call once triggered.

## Backend

Production: **https://backend-five-dusky-36.vercel.app** (connected to this GitHub repo — pushes to `main` auto-deploy). The iOS app defaults to this URL (`BROWNMELLON_BACKEND_URL` in `project.yml` / `Info.plist`).

Env vars on the Vercel project:
- `GEMINI_API_KEY` — **already set**, used by `api/ocr.ts` and `api/scam-check.ts`.
- `ANTHROPIC_API_KEY` — **not yet set**, needed by `api/parse-intent.ts` (Scheduling won't get real intents back until this is added). Run this yourself rather than pasting the key into chat:
  ```bash
  cd backend
  vercel env add ANTHROPIC_API_KEY production
  vercel --prod   # redeploy to pick it up
  ```

Running locally:

```bash
cd backend
npm install
cp .env.example .env   # fill in GEMINI_API_KEY and ANTHROPIC_API_KEY
npm run dev             # vercel dev, serves api/*.ts on localhost:3000
```

```bash
npx tsc --noEmit   # typecheck all three endpoints
```

## iOS app

Requires full Xcode (not just Command Line Tools).

```bash
brew install xcodegen   # if not already installed
cd ios
xcodegen generate
open Brownmellon.xcodeproj
```

Run on Simulator or a physical device — 5 tabs, one per feature area (Schedule / Scan Card / Read To Me / Check Ad / Setup). Talks to the deployed backend by default; point `BROWNMELLON_BACKEND_URL` at `vercel dev` locally instead if needed.

```bash
xcodebuild -project ios/Brownmellon.xcodeproj -scheme Brownmellon \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Verified (2026-09-19): builds with zero errors/warnings against iOS 27.0, all `WakeWordDetectorTests` pass, and the app installs and launches on an iPhone 17 Simulator without crashing.

## Known gaps

- No real `GlassesSession` (Meta DAT wrapper) yet — the highest-risk shared piece, per PRD § Foundation.
- Google Cloud OAuth client ID not set up — blocks real Calendar reads/writes.
- Voice triggers for Vision (3–4) and Safety (5) aren't wired to the wake-word pipeline yet.
- Feature 6's dedicated always-on emergency phrase isn't implemented.
- Only one physical Ray-Ban Meta Gen 2 pair confirmed available for hardware testing (PRD § Known risks).
