# Workstream B — Vision & Documents

Worktree for `feature/vision-documents` (see `PRD.md` § Parallel workstreams for the full plan). Owns Feature 3 (appointment-card scanning) and Feature 4 ("read this to me").

## Status

Scaffolded and running against mocks — not yet wired to real glasses hardware or a real calendar.

- **Backend (`backend/`)** — real, working `api/ocr.ts` endpoint. Typechecks clean (`npx tsc --noEmit`). Calls the Claude API directly per the PRD's settled architecture, one endpoint with two modes (`appointment` / `read`), stateless — no image or transcript is ever persisted server-side.
- **iOS (`ios/`)** — real Swift source (view models + SwiftUI views + backend client), generated as an Xcode project via [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`ios/project.yml` is the source of truth — `Brownmellon.xcodeproj` is generated, gitignored, and must be regenerated after any `project.yml` change: `cd ios && xcodegen generate`).
- **Not done here:** this machine only has Xcode Command Line Tools, not full Xcode — I could write and typecheck the backend, and generate the Xcode project structure, but I have not opened, built, or run the iOS app on a simulator or device. **You'll need to open `ios/Brownmellon.xcodeproj` in full Xcode yourself** to actually build/run it and confirm the Swift compiles against the real iOS SDK.

## Two things this workstream is deliberately faking, and why

1. **Voice trigger.** The real trigger for both features is "Hey Brownmellon, scan this" / "...read this to me" — but that keyword-routing infrastructure is Workstream A's, and doesn't exist yet. Both screens use a manual button tap instead (`AppointmentCardScanView` / `ReadToMeView`). When A's keyword router lands, wire it to call `AppointmentCardScanViewModel.scan()` / `ReadToMeViewModel.readThisToMe()` directly — they're already designed as the integration seam.
2. **Camera + speech.** `MockGlassesSession` (`ios/Brownmellon/Core/Mocks/`) uses the system photo picker to stand in for the glasses camera (pick any photo of an appointment card or document) and real on-device text-to-speech (`AVSpeechSynthesizer`) to stand in for the glasses speaker — so the feature is genuinely testable, and audible, on Simulator with zero hardware. Swap for the real `GlassesSession` (DAT-backed) once that shared-foundation piece lands.

Calendar writes go through `MockCalendarService` (in-memory, resets on relaunch) by default. `GoogleCalendarService.swift` is written (real Calendar API v3 calls — create + list events, via `GoogleSignIn-iOS`) but **not wired up or usable yet**: it needs a Google Cloud OAuth client ID that doesn't exist yet (one-time setup, PRD § Deployment), and its `GIDSignIn` call signatures haven't been checked against the actually-resolved SDK version (written from general knowledge, no way to verify without Xcode). Whoever sets up the Google Cloud project should pick this up, verify it against the real SDK, and swap it in for the mock in `BrownmellonApp.swift`.

## Backend is deployed

Production: **https://backend-five-dusky-36.vercel.app** (also connected to this GitHub repo — pushes to `main` will auto-deploy). The iOS app defaults to this URL (`BROWNMELLON_BACKEND_URL` in `project.yml`) since a physical device can't reach `localhost`.

**Still needed for it to actually work:** set `ANTHROPIC_API_KEY` on the Vercel project. Run this yourself rather than pasting the key into chat:
```bash
cd backend
vercel env add ANTHROPIC_API_KEY production
vercel --prod   # redeploy to pick it up
```

## Running the backend locally

```bash
cd backend
npm install
cp .env.example .env   # fill in ANTHROPIC_API_KEY
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
