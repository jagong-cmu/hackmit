# Workstream B — Vision & Documents

Worktree for `feature/vision-documents` (see `PRD.md` § Parallel workstreams for the full plan). Owns Feature 3 (appointment-card scanning) and Feature 4 ("read this to me").

## Status

Scaffolded and running against mocks — not yet wired to real glasses hardware or a real calendar.

- **Backend (`backend/`)** — real, working `api/ocr.ts` endpoint. Typechecks clean (`npx tsc --noEmit`). Calls the Claude API directly per the PRD's settled architecture, one endpoint with two modes (`appointment` / `read`), stateless — no image or transcript is ever persisted server-side.
- **iOS (`ios/`)** — real Swift source (view models + SwiftUI views + backend client), generated as an Xcode project via [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`ios/project.yml` is the source of truth — `Brownmellon.xcodeproj` is generated, gitignored, and must be regenerated after any `project.yml` change: `cd ios && xcodegen generate`).
- **Verified with full Xcode (27.0):** `xcodebuild` succeeds against the real iOS 27.0 SDK with zero errors and zero warnings (`GoogleCalendarService.swift`'s `GIDSignIn`/`GoogleSignIn-iOS` 7.1.0 call signatures included), and the app installs and launches cleanly on an iPhone 17 Simulator without crashing. Fixed two Swift 6-mode concurrency warnings in `MockGlassesSession` along the way (`GlassesSession` protocol is now `@MainActor`; the `PHPickerViewControllerDelegate` callback hops back to the main actor before touching UIKit).

## Two things this workstream is deliberately faking, and why

1. **Voice trigger.** The real trigger for both features is "Hey Brownmellon, scan this" / "...read this to me" — but that keyword-routing infrastructure is Workstream A's, and doesn't exist yet. Both screens use a manual button tap instead (`AppointmentCardScanView` / `ReadToMeView`). When A's keyword router lands, wire it to call `AppointmentCardScanViewModel.scan()` / `ReadToMeViewModel.readThisToMe()` directly — they're already designed as the integration seam.
2. **Camera + speech.** `MockGlassesSession` (`ios/Brownmellon/Core/Mocks/`) uses the system photo picker to stand in for the glasses camera (pick any photo of an appointment card or document) and real on-device text-to-speech (`AVSpeechSynthesizer`) to stand in for the glasses speaker — so the feature is genuinely testable, and audible, on Simulator with zero hardware. Swap for the real `GlassesSession` (DAT-backed) once that shared-foundation piece lands.

Calendar writes go through `MockCalendarService` (in-memory, resets on relaunch) by default. `GoogleCalendarService.swift` is written (real Calendar API v3 calls — create + list events, via `GoogleSignIn-iOS`) and now **verified to compile clean against the real SDK (7.1.0)**, but still **not wired up or usable yet**: it needs a Google Cloud OAuth client ID that doesn't exist yet (one-time setup, PRD § Deployment). Whoever sets up the Google Cloud project should swap it in for the mock in `BrownmellonApp.swift`.

## Heads up for whoever picks up A or C's worktree next

`feature/voice-calendar` (Workstream A) scaffolded its own `Core/Interfaces.swift` at the **repo root** (`Core/`, `Features/Scheduling/`, `api/parse-intent.ts`, no `ios/`/`backend/` split and no `.xcodeproj` at all yet), which is a different layout from this worktree's `ios/Brownmellon/Core/` + `backend/`. These two will conflict structurally, not just textually, whenever they both land on `main` — someone needs to pick one layout before merging. A also changed the wake word from "Hey Brownmellon" to "Hey Dojo"; this worktree's copy hasn't been renamed to match. Separately, `main` itself picked up a scope change (Feature 5 facial recognition → OCR-based ad scam detection, Workstream C renamed Safety & Emergency) that doesn't touch this workstream's files.

## Backend is deployed

Production: **https://backend-five-dusky-36.vercel.app** (also connected to this GitHub repo — pushes to `main` will auto-deploy). The iOS app defaults to this URL (`BROWNMELLON_BACKEND_URL` in `project.yml`) since a physical device can't reach `localhost`.

`GEMINI_API_KEY` is already set on the Vercel project (production) — the endpoint runs on Gemini now, not Claude (see `api/ocr.ts` header comment for why). Nothing further needed for the backend to work end-to-end.

## Running the backend locally

```bash
cd backend
npm install
cp .env.example .env   # fill in GEMINI_API_KEY
npm run dev             # vercel dev, serves api/ocr.ts on localhost:3000
```

Quick manual test once it's running:

```bash
curl -X POST http://localhost:3000/api/ocr \
  -H "Content-Type: application/json" \
  -d "{\"mode\":\"read\",\"imageBase64\":\"$(base64 -i /path/to/a/photo.jpg)\"}"
```

## Opening the iOS app

Requires full Xcode (not just Command Line Tools) — install from the App Store first if needed.

```bash
brew install xcodegen   # if not already installed
cd ios
xcodegen generate
open Brownmellon.xcodeproj
```

Run on Simulator or a physical device. `AppointmentCardScanView` / `ReadToMeView` will prompt the photo picker in place of the glasses camera. Talks to the deployed backend by default — see `VisionBackendClient.baseURL` / `project.yml`'s `BROWNMELLON_BACKEND_URL` to point at `vercel dev` locally instead.
