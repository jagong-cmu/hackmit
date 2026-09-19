# Brownmellon v2 Foundation — shared changes that must land before the v2 feature workstreams

**Status:** prerequisite for [`PRD-sound-alerts.md`](PRD-sound-alerts.md), [`PRD-memory.md`](PRD-memory.md), [`PRD-food-label.md`](PRD-food-label.md). ~1–2 hours of work. Land this first; the three feature agents then branch from it and touch none of these files again.

**Why this exists:** all three v2 features need (a) a way to receive voice commands other than calendar ones, and for that to work from *any* tab, (b) two of them need things `GlassesSession` doesn't expose today (raw mic audio, speaking state), (c) all camera features need photo downscaling before upload, and (d) all of them add `Info.plist` keys. If three parallel agents each make those edits, every merge conflicts. Do it once, here.

## Brief for the implementing agent

Read first, in this order: [`../README.md`](../README.md), [`../PRD.md`](../PRD.md) § Foundation and § Design principles, `ios/Brownmellon/Core/Interfaces.swift`, `ios/Brownmellon/Core/Mocks/MockGlassesSession.swift`, **`ios/Brownmellon/Core/DATGlassesSession.swift`** (the real Ray-Ban Meta session — read all of it, especially `beginRecognition`, `tearDownRecognition`, `configureAudioSession`, `speak`), `ios/Brownmellon/Features/Scheduling/SchedulingCoordinator.swift`, `SchedulingViewModel.swift`, `SchedulingView.swift`, `ios/Brownmellon/App/BrownmellonApp.swift`, `ios/project.yml`.

Verify with (from `ios/`): `xcodegen generate` then `xcodebuild -project Brownmellon.xcodeproj -scheme Brownmellon -destination 'platform=iOS Simulator,name=<the simulator you were given>' test`. Zero warnings is the bar the repo is currently at — keep it there. Backend is untouched by this doc.

**Hardware caveat:** `DATGlassesSession` was just fixed against real glasses (`dfa0fd7`) and cannot be tested on Simulator (the app uses `MockGlassesSession` there). Every change to it must be minimal, must leave behavior byte-for-byte identical when no audio tap is installed, and must be reviewed for thread-safety — the tap closure runs on the audio thread, everything else is `@MainActor`.

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
- Nothing else in the coordinator changes.

**Rule for feature agents:** a handler must return `false` fast for anything it doesn't own — a couple of string checks, no network. Only claim phrases listed in your PRD.

## 2. Listening is app-lifetime, not a tab

**Problem:** `SchedulingView` calls `viewModel.start()` in `onAppear` and `stop()` in `onDisappear`, so the wake word only works while the Schedule tab is showing. That's fine for a scaffold; it's wrong for a voice-first product where the wearer says "Hey Dojo, can I eat this?" with the phone in a pocket.

**Change:**
- New `ios/Brownmellon/Core/VoiceAssistant.swift` — a `@MainActor final class VoiceAssistant: ObservableObject` that owns the `SchedulingCoordinator` (built from `glasses`, `calendar`, an `IntentClient`, and the `handlers` array), exposes `start()` / `stop()` / `handle(_ typed: String) async` / `@Published lastResponse: String?` / `@Published isListening`, and installs the `onSpeak` hook on whichever session it's given (`MockGlassesSession` or `DATGlassesSession` — both have `onSpeak`; `SchedulingViewModel` already shows the pattern).
- `BrownmellonApp` owns one `VoiceAssistant` (plain property, like `glasses`) and starts it once from a `.task { }` on the root `TabView`. Nothing stops it on tab changes.
- `SchedulingViewModel` becomes a thin adapter over the shared `VoiceAssistant` (typed command field, last response, listening state) instead of constructing its own coordinator. `SchedulingView` drops `onAppear`/`onDisappear` start/stop. Keep the hardware `ListenerStatus` block as is.

The typed "Try it" field continues to call the coordinator's `handle(_:)` directly (works on both sessions). Tests exercise the *full* path instead — `MockGlassesSession.simulateTranscript("hey dojo …")` → `WakeWordListener` → coordinator → handler.

## 3. `GlassesSession` additions

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
    /// stream. Buffers never leave the device. The callback arrives on the
    /// audio thread, not the main actor.
    func startAudioTap(_ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)
    func stopAudioTap()
}
```

### `DATGlassesSession` (real hardware) — how to add the tap without breaking speech

Today `beginRecognition()` installs one `inputNode.installTap(onBus: 0, bufferSize: 1024, format:)` whose closure captures the local `request` and calls `request.append(buffer)`. `tearDownRecognition` removes the tap and stops the engine; Apple ends recognition roughly every minute, so this tear-down/re-begin cycle runs continuously while listening.

Implement fan-out with a small thread-safe holder rather than touching `@MainActor` state from the audio thread:

```swift
/// Audio-thread-safe fan-out for the single input tap.
private final class AudioTapFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    func set(request: SFSpeechAudioBufferRecognitionRequest?) { ... }
    func set(handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?) { ... }
    func deliver(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        lock.lock(); let r = request; let h = handler; lock.unlock()
        r?.append(buffer); h?(buffer, when)
    }
}
```

Rules:
- One tap closure only: `{ buffer, when in fanout.deliver(buffer, when) }`. `beginRecognition` sets `fanout.set(request:)`; `tearDownRecognition` sets it to `nil`.
- `startAudioTap(handler)` stores the handler in the fanout. If the engine is not running (nobody called `startListening`), call `configureAudioSession()`, request mic permission the same way `beginRecognition` does, install the tap and start the engine — the same guards (`format.sampleRate > 0`) apply.
- `tearDownRecognition(deactivateSession:)` must **not** stop the engine or remove the tap while an audio-tap handler is installed — only clear the request. Stopping the engine there is what makes the recognizer restart cycle invisible to the sound feature. `stopAudioTap` clears the handler and, if not listening, stops the engine and deactivates the session.
- `isSpeaking`: `synthesizer.isSpeaking`.
- When no handler is installed and `startAudioTap` was never called, the observable behavior must be exactly today's.

### `MockGlassesSession` (Simulator)

- `isSpeaking`: `synthesizer.isSpeaking`.
- Make `speak` await completion using an `AVSpeechSynthesizerDelegate` continuation, exactly as `DATGlassesSession.speak` does. Today the mock returns immediately, which makes the coordinator's `listener.reset()` fire before speech ends on Simulator and diverges from hardware.
- `startAudioTap` / `stopAudioTap`: store the callback.
- New `func simulateAudio(fileURL: URL, realtime: Bool = false) async throws` — opens the file with `AVAudioFile`, reads 4096-frame `AVAudioPCMBuffer`s in the file's processing format, and calls the stored tap callback for each (sleeping `frames / sampleRate` between buffers when `realtime` is true). No-op if no tap is installed.
- New `var stubbedPhoto: UIImage?` — when set, `capturePhoto()` returns it immediately instead of presenting the picker. For tests.

## 4. Photo downscaling before upload

**Problem:** every camera client (`VisionBackendClient`, `ScamCheckBackendClient`) does `image.jpegData(compressionQuality: 0.85)` on whatever `capturePhoto()` returns. A real glasses frame is several MB as JPEG, ~35% more as base64 — over Vercel's 4.5 MB request-body limit. Simulator picker photos are small enough that nobody has hit this yet.

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

Implement with `preparingThumbnail(of:)` preserving aspect ratio; return the original's JPEG if it's already within bounds. Replace the two existing `jpegData(compressionQuality:)` call sites with `uploadJPEGData()` — a one-line change each in `Features/Vision/VisionBackendClient.swift` and `Features/Safety/ScamCheckBackendClient.swift`. Do not change any request/response shapes.

## 5. `project.yml` keys (one edit, all features)

In `ios/project.yml` under `targets.Brownmellon.info.properties`, change/add only these (leave the DAT keys and `UIBackgroundModes` — `audio` is already there — untouched):

```yaml
NSCameraUsageDescription: "Brownmellon uses the glasses camera to scan appointment cards, read documents and food labels aloud, and check ads."
NSMicrophoneUsageDescription: "Brownmellon listens for \"Hey Dojo\" and, if enabled, for household sounds like a smoke alarm or doorbell so it can tell you about them."
NSLocationWhenInUseUsageDescription: "Brownmellon saves your location when you ask it to remember where you parked."
```

Regenerate the project and confirm `Info.plist` picked the keys up.

## 6. Setup tab becomes a menu

`BrownmellonApp` currently puts `EmergencyContactSetupView` directly in the Setup tab's `NavigationStack`. Two v2 features add caregiver settings (diet profile, sound-alert toggles).

New file `ios/Brownmellon/Features/Setup/SetupHomeView.swift`: a `List` of `NavigationLink`s, starting with the one existing destination ("Emergency Contacts" → `EmergencyContactSetupView(store:)`). `BrownmellonApp` shows `SetupHomeView` in the stack instead. Feature agents each add one `NavigationLink` line; these conflict trivially (adjacent lines) — [`README.md`](README.md) gives the merge order.

## 7. App wiring shape (so feature agents wire the same way)

`BrownmellonApp` already owns service objects as plain properties and picks `MockGlassesSession` vs `DATGlassesSession` with `#if targetEnvironment(simulator)`. Feature view models that also act as `VoiceCommandHandler`s must be owned the same way and passed to *both* their view and the `VoiceAssistant`, otherwise the voice path and the on-screen path act on different instances:

```swift
private let glasses: GlassesSession
// ...
// v2 features (each PRD adds one line here, and one tab or Setup link):
// private let foodLabel = FoodLabelViewModel(glasses: glasses, ...)
private let assistant: VoiceAssistant   // built in init() with handlers: [memory, foodLabel, soundAlerts]
```

Views take an injected view model as `@ObservedObject` (not `@StateObject`). Leave the existing Vision/Safety feature views alone — converting them to voice routing is their own workstream's call, not part of v2 foundation.

## Acceptance

- App builds with zero warnings; `WakeWordDetectorTests` and `AppointmentCardDateTests` still green.
- New `VoiceRoutingTests`: (1) a handler returning `true` short-circuits the intent client — use a stub `IntentClient`-shaped dependency or a `URLProtocol` stub that fails the test if hit; (2) a handler returning `false` falls through; (3) **full path:** `MockGlassesSession.simulateTranscript("hey dojo test phrase")` after `VoiceAssistant.start()` reaches a registered handler with command `"test phrase"`.
- `MockGlassesSession.simulateAudio` delivers buffers to an installed tap (test with a 1-second generated sine WAV written to a temp file); `stubbedPhoto` short-circuits `capturePhoto`.
- `VoiceAssistant.start()` is called once at launch; switching tabs on Simulator does not stop listening (`MockGlassesSession.isListening` stays true — assert in a test by constructing the assistant and checking after `start()`; the UI part is a manual check).
- `DATGlassesSession` diff is reviewed against the rules in § 3: fan-out holder, no `@MainActor` state touched on the audio thread, engine lifetime = (listening || tap installed), identical behavior when neither `startAudioTap` nor `isSpeaking` is used.
- The two existing camera clients send images ≤ 2048 px on the long edge (unit test `UploadImage` on a synthetic 4000×3000 image → 2048×1536).
- `Info.plist` contains the three strings above.
