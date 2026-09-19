# Brownmellon v2 Foundation — shared changes that must land before the v2 feature workstreams

**Status:** prerequisite for [`PRD-sound-alerts.md`](PRD-sound-alerts.md), [`PRD-memory.md`](PRD-memory.md), [`PRD-food-label.md`](PRD-food-label.md). ~1–2 hours of work. Land this on `main` first; the three feature agents then branch from it and touch none of these files again.

**Why this exists:** all three v2 features need (a) a way to receive voice commands other than calendar ones, (b) two of them need things `GlassesSession` doesn't expose today (raw mic audio, speaking state), (c) all camera features need photo downscaling before upload, and (d) all of them add `Info.plist` keys. If three parallel agents each make those edits, every merge conflicts. Do it once, here.

## Brief for the implementing agent

Read first, in this order: [`../README.md`](../README.md), [`../PRD.md`](../PRD.md) § Foundation and § Design principles, `ios/Brownmellon/Core/Interfaces.swift`, `ios/Brownmellon/Core/Mocks/MockGlassesSession.swift`, `ios/Brownmellon/Features/Scheduling/SchedulingCoordinator.swift`, `ios/Brownmellon/Features/Scheduling/SchedulingViewModel.swift`, `ios/Brownmellon/App/BrownmellonApp.swift`, `ios/project.yml`.

Verify with (from `ios/`): `xcodegen generate` then `xcodebuild -project Brownmellon.xcodeproj -scheme Brownmellon -destination 'platform=iOS Simulator,name=iPhone 17' test`. Zero warnings is the bar the repo is currently at (README § iOS app) — keep it there. Backend: `cd backend && npx tsc --noEmit`.

Do not build any feature behavior here. This is interfaces, mocks, wiring, and plist keys only.

## 1. Voice command handlers (the pre-parse hook)

**Problem:** `SchedulingCoordinator.handle(_:)` is the only consumer of "Hey Dojo" commands and sends every one to `api/parse-intent.ts`, which only knows calendar intents. Features 3–5 are button-only today because of this (README § What's mocked).

**Change:** add a handler chain the coordinator consults *before* calling the intent backend.

New file `ios/Brownmellon/Core/VoiceCommandHandler.swift`:

```swift
/// A feature that can act on a "Hey Dojo" command. `command` is already
/// lower-cased and punctuation-stripped by `WakeWordDetector.normalize`.
/// Return true if you handled it (the coordinator then stops); false to let
/// the next handler — and finally the calendar intent parser — try.
@MainActor
protocol VoiceCommandHandler: AnyObject {
    func handle(_ command: String) async -> Bool
}
```

Edit `SchedulingCoordinator`:
- Add `private let handlers: [VoiceCommandHandler]` and an `init` parameter `handlers: [VoiceCommandHandler] = []`.
- At the top of `handle(_ command:)`, before `intents.parse`:
  ```swift
  for handler in handlers {
      if await handler.handle(command) {
          listener.reset()
          return
      }
  }
  ```
- Nothing else in the coordinator changes. Existing `SchedulingCoordinator` tests (if any are added by A) must still pass with an empty handler list.

Thread `handlers` through `SchedulingViewModel.init` and `SchedulingView.init` as a defaulted parameter, so `BrownmellonApp` can pass the feature view models in. Handler order is the array order; the three v2 PRDs each say which phrases they claim, and they are disjoint.

**Rule for feature agents:** a handler must return `false` fast for anything it doesn't own — a couple of string checks, no network. Only claim phrases listed in your PRD.

## 2. `GlassesSession` additions

Edit `ios/Brownmellon/Core/Interfaces.swift` — add `import AVFoundation` and extend the protocol:

```swift
@MainActor
protocol GlassesSession {
    // ...existing speak / startListening / stopListening / capturePhoto...

    /// True while the glasses speaker is playing our own speech. Features
    /// use this to ignore the mic while we talk (the open-ear speaker leaks
    /// straight back into the mic array).
    var isSpeaking: Bool { get }

    /// Raw mic audio for on-device analysis (sound classification). Runs
    /// alongside `startListening` — both are consumers of the same input
    /// stream. Buffers never leave the device. Callback may arrive on a
    /// non-main thread.
    func startAudioTap(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)
    func stopAudioTap()
}
```

**Why these two, and why in the protocol:** the real DAT-backed session will own one `AVAudioEngine` whose input node is the glasses' Bluetooth HFP mic (the glasses present to iOS as a headset; DAT covers the camera). Speech recognition and sound classification must both be fed from that single `installTap` — two engines fighting over the input route is exactly the failure mode to avoid. So the session fans out buffers, and features consume. This is the expected design for the not-yet-built real session; whoever builds it should treat this as the contract.

`MockGlassesSession` changes:
- `isSpeaking`: return `synthesizer.isSpeaking`.
- `startAudioTap` / `stopAudioTap`: store the callback.
- New `func simulateAudio(fileURL: URL, realtime: Bool = false) async throws` — opens the file with `AVAudioFile`, reads 4096-frame `AVAudioPCMBuffer`s in the file's processing format, and calls the stored tap callback for each (sleeping `frames / sampleRate` between buffers when `realtime` is true). This is how the sound-alert feature is developed and demoed on Simulator with bundled clips. No-op if no tap is installed.

Also note in a comment on `speak`: the mock returns before speech finishes (`AVSpeechSynthesizer.speak` is fire-and-forget). Callers that need "done speaking" should poll `isSpeaking`. Don't fix this here — the real session should `await` completion, and the mock can be made to match later.

## 3. Photo downscaling before upload

**Problem:** every camera client (`VisionBackendClient`, `ScamCheckBackendClient`) does `image.jpegData(compressionQuality: 0.85)` on whatever `capturePhoto()` returns. A 12 MP glasses frame is 4–6 MB as JPEG, ~35% more as base64 — over Vercel's 4.5 MB request-body limit. Simulator picker photos are small enough that nobody has hit this yet; the first real-device photo will.

New file `ios/Brownmellon/Core/UploadImage.swift`:

```swift
import UIKit

extension UIImage {
    /// JPEG sized for a single-inference upload. Long edge capped at
    /// `maxDimension` px — enough for label-sized text, safely under
    /// Vercel's 4.5 MB body limit after base64.
    func uploadJPEGData(maxDimension: CGFloat = 2048, quality: CGFloat = 0.8) -> Data?
}
```

Implement with `preparingThumbnail(of:)` (iOS 15+) preserving aspect ratio; return the original's JPEG if it's already within bounds. Then replace the two existing `jpegData(compressionQuality:)` call sites with `uploadJPEGData()` — a one-line change each in `Features/Vision/VisionBackendClient.swift` and `Features/Safety/ScamCheckBackendClient.swift`. New clients in the v2 PRDs use it from the start. Do not change any request/response shapes.

## 4. `project.yml` / `Info.plist` keys (one edit, all features)

In `ios/project.yml` under `targets.Brownmellon.info.properties`:

```yaml
NSCameraUsageDescription: "Brownmellon uses the glasses camera to scan appointment cards, read documents and food labels aloud, and check ads."
NSMicrophoneUsageDescription: "Brownmellon listens for \"Hey Dojo\" and, if enabled, for household sounds like a smoke alarm or doorbell so it can tell you about them."
NSLocationWhenInUseUsageDescription: "Brownmellon saves your location when you ask it to remember where you parked."
UIBackgroundModes:
  - audio
```

`UIBackgroundModes: audio` is what lets an active recording audio session keep running when the phone locks — this is the mechanism that makes "phone in pocket" plausible for the mic path (PRD § Deployment, open risk 5) and is required for sound alerts to be worth anything. It changes nothing on Simulator. Regenerate the project (`xcodegen generate`) and confirm `Info.plist` picked the keys up.

## 5. Setup tab becomes a menu

`BrownmellonApp` currently puts `EmergencyContactSetupView` directly in the Setup tab's `NavigationStack`. Two v2 features add caregiver settings (diet profile, sound-alert toggles).

New file `ios/Brownmellon/Features/Setup/SetupHomeView.swift`: a `List` of `NavigationLink`s, starting with the one existing destination ("Emergency Contacts" → `EmergencyContactSetupView(store:)`). `BrownmellonApp` shows `SetupHomeView` in the stack instead. Feature agents each add one `NavigationLink` line; these will conflict trivially (adjacent lines) — the merge order in [`README.md`](README.md) says who rebases onto whom.

## 6. App wiring shape (so feature agents wire the same way)

`BrownmellonApp` already owns service objects as plain properties. Feature view models that also act as `VoiceCommandHandler`s must be owned the same way and passed to *both* their view and the coordinator, otherwise the voice path and the on-screen path act on different instances:

```swift
private let glasses = MockGlassesSession()
// ...
// v2 features (each PRD adds one line here, and one tab or Setup link):
// private let foodLabel = FoodLabelViewModel(glasses: glasses, ...)
// SchedulingView(..., handlers: [memory, foodLabel, soundAlerts])
```

Views take the view model as `@ObservedObject` (not `@StateObject`) when it's injected this way. Leave the existing feature views alone — converting Vision/Safety to voice routing is Workstream A/B/C's call, not part of v2.

## Acceptance

- App builds with zero warnings; `WakeWordDetectorTests` still green; a new `SchedulingCoordinatorHandlerTests` proves: a handler returning `true` short-circuits the intent client (use a stub `IntentClient` that fails the test if called); a handler returning `false` falls through to it.
- `MockGlassesSession.simulateAudio` delivers buffers to an installed tap (test with a 1-second generated sine WAV written to a temp file).
- Backend typechecks; the two existing camera clients send images ≤ 2048 px on the long edge (unit test `UploadImage` on a synthetic 4000×3000 image → 2048×1536).
- `Info.plist` contains the four keys above.
