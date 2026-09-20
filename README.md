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
| 5 | Multimodal advertisement scam screening | C — Scam Safety | Existing backend + manual-trigger UI; multimodal analysis and grounded web verification are the next implementation step. Not yet voice-triggered or hardware-tested. |
| 8 | Sound alerts for hearing loss ("I hear a smoke alarm") | v2 — Hearing | **Voice-driven, fully on-device.** Apple's `SoundAnalysis` classifier runs on the same mic stream as the wake word; caregiver toggles in Setup → Sound Alerts; "Hey Dojo, what was that?" answers from the last minute. No backend. Hardware tuning (HFP band-limited mic) still pending. Spec: `prds/PRD-sound-alerts.md`. |
| 9 | Memory ("remember where I parked") | v2 — Memory | **Voice-driven.** Save/recall/forget by voice; parking notes photograph the spot marker (via `api/ocr`) and keep a GPS fix; parking recall is offline; general recall via `api/recall.ts` (Gemini, wearer's own notes only, no coordinates). Spec: `prds/PRD-memory.md`. |
| 10 | Food label reader + diet check ("can I eat this?") | v2 — Nutrition | **Voice-driven.** One photo → `api/food-label.ts` extracts per-serving facts; an on-device rules engine compares them to the caregiver's diet profile (Setup → Diet). Follow-ups ("read the ingredients") reuse the last label without a new photo. The profile never leaves the phone. Spec: `prds/PRD-food-label.md`. |

Physical-device builds use the real Meta DAT-backed `GlassesSession`; Simulator builds use mocks. Google Calendar still needs a Google Cloud OAuth client ID, so calendar features continue to use an in-memory mock by default.

**Voice routing (v2 foundation, `prds/PRD-foundation-v2.md`):** `VoiceAssistant` owns the one "Hey Dojo" pipeline for the app's lifetime (every tab, not just Schedule). Commands go through a `VoiceCommandHandler` chain — memory → food label → sound alerts — before falling back to the calendar intent parser. On hardware, `DATGlassesSession` only forwards a transcript once it has stopped changing for ~1 s (`TranscriptSettler`), and the coordinator closes the mic for the duration of a command and reopens it afterwards, so a companion's remark or our own reply is never transcribed onto the command and the next utterance starts from an empty transcript. `CrossFeatureRoutingTests` pins the whole chain: every claimed phrase reaches exactly one owner, calendar phrasing always falls through. Every v2 feature ships voice-path tests (`MockGlassesSession.simulateTranscript("hey dojo …")` → asserted spoken reply); the on-screen buttons are a Simulator convenience.

## Layout

```
prds/                          v2 feature specs + dispatch order (prds/README.md)
backend/                       One Vercel project, one endpoint per feature area (all Gemini, one key)
  api/ocr.ts                     Features 3–4, and Feature 9's parking-sign read
  api/parse-intent.ts            Features 1–2
  api/scam-check.ts              Feature 5
  api/recall.ts                  Feature 9 — general memory recall
  api/food-label.ts              Feature 10 — label extraction (numbers only; diet rules run on-device)
  tests/                         node --test unit tests of the endpoints' pure helpers (`npm test`)
ios/
  project.yml                    XcodeGen source of truth — regenerate after any edit
  Brownmellon/
    App/BrownmellonApp.swift     Wires DAT on device and mocks on Simulator; owns the v2 handlers
    Core/                        Shared protocols + real/mock implementations
      Interfaces.swift             GlassesSession (+ isSpeaking, audio tap), CalendarService, SecureLocalStore
      VoiceAssistant.swift         App-lifetime "Hey Dojo" pipeline; VoiceCommandHandler chain
      TranscriptSettler.swift      One delivery per utterance from streaming recognizer partials
      DATGlassesSession.swift      Real Meta DAT camera + Bluetooth audio session (tap fan-out)
      KeychainSecureLocalStore.swift  Persistence for diet profile, sound-alert settings, memory notes
      UploadImage.swift            Downscales photos under Vercel's 4.5 MB body limit
      GoogleCalendarService.swift  Real, not wired up (needs OAuth client ID)
      Mocks/                      MockGlassesSession (simulateTranscript/simulateAudio/stubbedPhoto), MockCalendarService, MockSecureLocalStore
    Features/
      Glasses/                     Physical-device DAT connection UI
      Scheduling/                 Features 1–2 (Workstream A)
      Vision/                     Features 3–4 (Workstream B)
      Safety/                     Feature 5 (Workstream C)
      Hearing/                    Feature 8 — sound alerts
      Memory/                     Feature 9 — remember / recall
      Nutrition/                  Feature 10 — food label + diet check
      Setup/                      Caregiver menu (Diet, Sound Alerts)
  BrownmellonTests/              ~340 tests incl. per-feature voice-path tests
```

**Adding a feature or picking one up:** put backend logic in its own `backend/api/*.ts` file (stateless, one inference call in, structured JSON out — copy `ocr.ts` or `scam-check.ts`'s shape), and iOS code in its own `Features/<Name>/` folder against the `Core/Interfaces.swift` protocols. Wire the new view into `BrownmellonApp.swift`'s `TabView`. Don't touch another feature's files — that's what kept the original three workstreams merge-conflict-free, and it still holds.

## What's mocked, and why

- **`MockGlassesSession`** — used only on Simulator: on-device text-to-speech (`AVSpeechSynthesizer`) for `speak`, the system photo picker for `capturePhoto`, and a stored transcript callback (`simulateTranscript(_:)`) for `startListening`/`stopListening`. Physical-device builds use `DATGlassesSession`.
- **`MockCalendarService`** — in-memory, resets on relaunch. `GoogleCalendarService` is real and compiles clean against `GoogleSignIn-iOS` 7.1.0, but needs a Google Cloud OAuth client ID (PRD § Deployment) before it's usable.
- **Voice triggers** for Features 3–5 are manual button taps — Workstream A's `WakeWordListener`/`SchedulingCoordinator` only routes to Scheduling today. Extending it to dispatch "Hey Dojo, scan this" / "check this ad" to the other features' view models is the natural next step (their `scan()` / `checkAd()` methods are already designed as the integration seam).

## Backend

Production: **https://backend-five-dusky-36.vercel.app** (connected to this GitHub repo — pushes to `main` auto-deploy). The iOS app defaults to this URL (`BROWNMELLON_BACKEND_URL` in `project.yml` / `Info.plist`).

Env vars on the Vercel project:
- `GEMINI_API_KEY` — **already set**; every endpoint (`ocr`, `parse-intent`, `scam-check`, `recall`, `food-label`) uses it.

Running locally:

```bash
cd backend
npm install
cp .env.example .env   # fill in GEMINI_API_KEY
npm run dev             # vercel dev, serves api/*.ts on localhost:3000
```

```bash
npx tsc --noEmit   # typecheck all endpoints
npm test           # node --test over tests/**/*.test.ts — pure helpers, no API key needed
```

`api/recall.ts` and `api/food-label.ts` have only been verified by typecheck and unit tests of their pure helpers (no `GEMINI_API_KEY` on dev machines). Their live behaviour gets exercised once a merge to `main` deploys them.

## iOS app

Requires full Xcode (not just Command Line Tools).

```bash
brew install xcodegen   # if not already installed
cd ios
xcodegen generate
open Brownmellon.xcodeproj
```

Run on Simulator with 4 tabs — Schedule, Camera (Check Food / Read To Me / Scan Card / Check Ad), Memory, Setup (Diet, Sound Alerts). Physical-device builds add a Glasses tab for DAT registration and connection. The app talks to the deployed backend by default; point `BROWNMELLON_BACKEND_URL` at `vercel dev` locally instead if needed.

On Simulator there is no mic: type a command into the Schedule tab's field (it runs the same path a spoken "Hey Dojo, …" would), or use the Setup → Sound Alerts "Play: smoke alarm / doorbell" buttons, which feed bundled clips through the same audio tap the glasses would.

```bash
xcodebuild -project ios/Brownmellon.xcodeproj -scheme Brownmellon \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Verified (2026-09-19): builds with zero errors/warnings against iOS 27.0, 344 tests pass (voice-path tests for every v2 feature included), and the app installs and launches on an iPhone 17 Simulator.

## Known gaps

- The real DAT `GlassesSession` has landed but still requires verification on the physical Ray-Ban Meta hardware — including the v2 audio-tap fan-out, the 1 s transcript settle, and sound-alert accuracy over the band-limited HFP mic.
- Google Cloud OAuth client ID not set up — blocks real Calendar reads/writes.
- Voice triggers for Vision (3–4) and Safety (5) aren't wired to the wake-word pipeline yet — they'd each become a `VoiceCommandHandler` like the v2 features.
- `api/recall.ts` / `api/food-label.ts` not yet exercised live (see Backend).
- Only one physical Ray-Ban Meta Gen 2 pair confirmed available for hardware testing (PRD § Known risks).
