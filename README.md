# Brownmellon

Voice-first AI assistant on Ray-Ban Meta Gen 2 glasses + companion iOS app, for adults 60+. See `PRD.md` for the full spec, and `.lavish/index.html` for platform feasibility research (DAT capabilities, battery data, legal risk).

This is the **unified project** — one Xcode project, one Vercel backend, all three workstreams' code living side by side under a single layout. Each workstream started in its own git worktree (see PRD § Parallel workstreams); this integration pass reconciled them onto `main` so anyone can build the whole app and pick up any feature from here.

## Status by feature

| # | Feature | Workstream | Voice | Status |
|---|---|---|---|---|
| 1 | Voice scheduling/reminders | A — Voice & Calendar | "Hey Dojo, remind me to take my pills at 8" | Real backend (`api/parse-intent.ts`), unit-tested. |
| 2 | Daily briefing | A | "Hey Dojo, what do I have today" | Same path as #1 (answered without a model call). |
| 3 | Appointment-card scanning | B — Vision & Documents | "Hey Dojo, scan this" → "yes" / "no" | Real backend + full iOS flow, voice-triggered and voice-confirmed. |
| 4 | "Read this to me" | B | "Hey Dojo, read this to me" | Same backend endpoint as #3, different mode. |
| 5 | Advertisement scam detection (OCR-only) | C — Safety & Emergency | "Hey Dojo, check this ad" / "is this a scam" | Real backend (`api/scam-check.ts`), voice-triggered. |
| 6 | Emergency contact | C | "Hey Dojo, call my daughter" / "call 911" | Caregiver setup screen, Keychain-backed contacts, `tel:` call placement, voice-triggered. The PRD's *dedicated* always-on phrase (a second listener that bypasses "Hey Dojo") is still **not implemented** — see `EmergencyCallService.swift`. |

**Every feature works two ways: by voice, and by its on-screen button.** Both call the same view-model method, so the screen shows what the voice just did. The mic opens when the app launches and stays open across every tab (`VoiceCommandRouter`), and the tab switches to whichever feature a command triggers.

The real glasses work on a physical iPhone (`DATGlassesSession`: DAT camera + Bluetooth audio). Google Calendar is still a mock (needs a Google Cloud OAuth client ID — one-time setup, PRD § Deployment). Everything is demoable on Simulator with zero hardware — see "What's mocked" below.

## How voice commands are routed

```
mic → GlassesSession.startListening (cumulative partial transcripts)
    → VoiceTranscriptGate      finds the latest "Hey Dojo", waits for the wearer
                                to finish the sentence, ignores what was already
                                acted on and the assistant's own echo; also reads a
                                bare "yes"/"no" while a confirmation is open
    → VoiceCommandRouter
        → VoiceCommandClassifier   on-device, offline: scan / read / check ad /
                                    call <relation> / call 911 / yes / no
        → api/parse-intent.ts      everything else (dates and times need the
                                    model); also returns the feature intents above
                                    for paraphrases the classifier misses
    → the feature's view model     scan() / readThisToMe() / checkAd() /
                                    callNow() / SchedulingCoordinator.perform()
```

Features 3–6 never need the backend to be triggered — that matters because the Gemini free tier is 20 requests/day/model, and a camera command shouldn't spend one just to be understood. `Features/Voice/` holds all of this; the tests in `BrownmellonTests/Voice*Tests.swift` replay real recognizer transcript sequences (growing partials, accumulating segments, echoed speech) and are the place to add a case when a phrasing misroutes on hardware.

**Testing voice on Simulator:** there's no mic, so the Schedule tab's text field runs the exact path a spoken command does — type `scan this`, `check this ad`, `call my daughter`, etc. and watch the tab switch and the status bar show what Dojo said.

## Layout

```
backend/                       One Vercel project, one endpoint per feature area
  api/ocr.ts                     Features 3–4 (Gemini)
  api/parse-intent.ts            Features 1–2 (Claude)
  api/scam-check.ts              Feature 5 (Gemini)
ios/
  project.yml                    XcodeGen source of truth — regenerate after any edit
  Brownmellon/
    App/BrownmellonApp.swift     Root view: voice status bar + tabs
    App/AppModel.swift           Composition root — builds services, view models, and the voice router once
    Core/                        Shared protocols + real/mock implementations
      Interfaces.swift             GlassesSession, CalendarService, SecureLocalStore
      GoogleCalendarService.swift  Real, not wired up (needs OAuth client ID)
      KeychainSecureLocalStore.swift  Real, used by Setup
      Mocks/                      MockGlassesSession, MockCalendarService, MockSecureLocalStore
    Features/
      Voice/                      "Hey Dojo" router shared by every feature (gate, classifier, status bar)
      Scheduling/                 Features 1–2 (Workstream A)
      Vision/                     Features 3–4 (Workstream B)
      Safety/                     Feature 5 (Workstream C)
      Setup/                      Feature 6 (Workstream C)
      Glasses/                    Hardware connection screen (device only)
  BrownmellonTests/              WakeWord / VoiceCommandClassifier / VoiceTranscriptGate / VoiceCommandRouter / AppointmentCardDate
```

**Adding a feature or picking one up:** put backend logic in its own `backend/api/*.ts` file (stateless, one inference call in, structured JSON out — copy `ocr.ts` or `scam-check.ts`'s shape), and iOS code in its own `Features/<Name>/` folder against the `Core/Interfaces.swift` protocols. Construct its view model in `AppModel`, add its tab in `BrownmellonApp.swift`, and give it a voice trigger by adding a case to `VoiceCommandClassifier` (plus a line in `VoiceCommandRouter.performLocal`). Don't touch another feature's files — that's what kept the original three workstreams merge-conflict-free, and it still holds.

## What's mocked, and why

- **`MockGlassesSession`** — real on-device text-to-speech (`AVSpeechSynthesizer`) for `speak`, the system photo picker for `capturePhoto`, and a stored transcript callback (`simulateTranscript(_:)`) for `startListening`/`stopListening` so Scheduling's wake-word path is exercisable without a mic. Swap for the real DAT-backed session once that lands — no other code should need to change, that's the point of the protocol.
- **`MockCalendarService`** — in-memory, resets on relaunch. `GoogleCalendarService` is real and compiles clean against `GoogleSignIn-iOS` 7.1.0, but needs a Google Cloud OAuth client ID (PRD § Deployment) before it's usable.
- **Emergency contacts persist for real** (`KeychainSecureLocalStore`) — "Hey Dojo, call my daughter" is only useful if the contact survives a relaunch. `MockSecureLocalStore` remains for tests.
- **Feature 6's dedicated emergency phrase** (its own always-on listener, independent of the general wake-word pipeline per PRD § Feature 6) isn't implemented — that's real device/DAT work. "Hey Dojo, call 911" goes through the general pipeline but is classified on-device, never behind a network call, and jumps any command already in progress.

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

Run on Simulator or a physical device — 5 tabs, one per feature area (Schedule / Scan Card / Read To Me / Check Ad / Setup), plus a Glasses tab on hardware, with the voice status bar above all of them. Talks to the deployed backend by default; point `BROWNMELLON_BACKEND_URL` at `vercel dev` locally instead if needed.

```bash
xcodebuild -project ios/Brownmellon.xcodeproj -scheme Brownmellon \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Verified (2026-09-19): builds with zero errors/warnings against iOS 27.0 (Simulator and device configurations), all 57 unit tests pass, and the app installs and launches on an iPhone 17 Simulator without crashing.

## Known gaps

- Google Cloud OAuth client ID not set up — blocks real Calendar reads/writes.
- Feature 6's dedicated always-on emergency phrase isn't implemented (see above).
- Voice + camera at the same time hasn't been hardware-tested: before this pass the mic only ran on the Schedule tab, so a "Hey Dojo, scan this" that opens a DAT camera session while the Bluetooth mic is streaming is a new combination on the glasses. The audio-session interruption handling in `DATGlassesSession` is there for the phone-call case but is likewise untested on hardware.
- Feature 1 writes to the calendar without a spoken confirmation (PRD asks for one; feature 3 has it). The yes/no plumbing in `VoiceTranscriptGate` is reusable for this.
- Only one physical Ray-Ban Meta Gen 2 pair confirmed available for hardware testing (PRD § Known risks).
