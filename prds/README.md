# v2 feature PRDs — how to dispatch them

Each document is written to be handed to a fresh implementing agent with no other context. Every PRD opens with a "Brief for the implementing agent" section: what to read first, which paths it owns, and the exact verify commands.

| Doc | Feature | Backend | Depends on |
|---|---|---|---|
| [`PRD-foundation-v2.md`](PRD-foundation-v2.md) | Shared interface changes (handler hook, audio tap, image downscale, plist keys, Setup menu) | none | — |
| [`PRD-sound-alerts.md`](PRD-sound-alerts.md) | Feature 8 — Sound alerts for hearing loss | **none** (fully on-device) | foundation |
| [`PRD-memory.md`](PRD-memory.md) | Feature 9 — "Remember where I parked" | `api/recall.ts` (Gemini) | foundation |
| [`PRD-food-label.md`](PRD-food-label.md) | Feature 10 — Food label reader + diet check | `api/food-label.ts` (Gemini) | foundation |
| [`PRD-facial-recognition.md`](PRD-facial-recognition.md) | Feature 7 — Enrolled-people recognition (proposal; team decision pending) | none | foundation § 1 for the wake-word hook; otherwise standalone |

## Order

1. **Foundation first, alone, on `main`.** ~1–2 hours. Nothing else starts until it's merged — it edits the exact shared files (`Interfaces.swift`, `MockGlassesSession.swift`, `SchedulingCoordinator.swift`, `project.yml`, `BrownmellonApp.swift`) that would otherwise conflict three ways.
2. **Features 8, 9, 10 in parallel**, each in its own worktree branched from the merged foundation:
   ```bash
   git worktree add ../hackmit-sound-alerts -b feature/sound-alerts
   git worktree add ../hackmit-memory       -b feature/memory
   git worktree add ../hackmit-food-label   -b feature/food-label
   ```
   They own disjoint paths (`Features/Hearing`, `Features/Memory`, `Features/Nutrition`, plus their own backend file and test folder). The only shared touches are one added line each in `App/BrownmellonApp.swift` (a property, a handler in the array, a tab) and in `Features/Setup/SetupHomeView.swift` (a link). Those conflict trivially.
3. **Merge order for the trivial conflicts:** food-label → memory → sound-alerts (largest surface first; each later one rebases and re-adds its single lines). Handler array order in `BrownmellonApp` should end up `[memory, foodLabel, soundAlerts]` — the claimed phrase sets are disjoint so order doesn't affect behavior, but keep it stable.

## Rules every feature agent follows

- Don't edit files outside your owned paths except the single lines named above.
- A `VoiceCommandHandler` returns `false` fast for anything not in your PRD's claimed-phrases list; never claim `remind…`, `read this to me`, `scan this`, or `check this ad`.
- Camera uploads go through `UIImage.uploadJPEGData()`; nothing is persisted server-side; the backend file copies the shape of `api/scam-check.ts` (photo in) or `api/parse-intent.ts` (text in) — both Gemini, one `GEMINI_API_KEY`.
- Every feature ships a voice-path test: `MockGlassesSession.simulateTranscript("hey dojo …")` through `VoiceAssistant` to the feature's handler, asserting on `onSpeak`. Buttons are a Simulator convenience, not the product.
- There is no `GEMINI_API_KEY` on dev machines. Backend verification = `npx tsc --noEmit` + `npm test` (node's test runner over `backend/tests/**/*.test.ts`, importing the endpoints' exported pure helpers; a bare `node --test backend/tests/` directory argument does not glob on Node 24). Live checks happen after merge to `main` (Vercel auto-deploys).

## Status (2026-09-19)

Foundation and Features 8, 9, 10 are implemented, independently verified, and integrated on the `worktree-facial-recognition` branch: 344 iOS tests and 32 backend tests green, zero warnings. Feature 7 (facial recognition) remains a proposal.
- Zero-warning build and green tests before opening the PR: `cd ios && xcodegen generate && xcodebuild -project Brownmellon.xcodeproj -scheme Brownmellon -destination 'platform=iOS Simulator,name=iPhone 17' test`, and `cd backend && npx tsc --noEmit`.
