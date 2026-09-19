# Feature 8 — Sound Alerts for hearing loss ("I hear a smoke alarm")

**Status:** v2 feature, own workstream. Depends on [`PRD-foundation-v2.md`](PRD-foundation-v2.md) (audio tap, `isSpeaking`, handler hook, `UIBackgroundModes: audio`).

**One line:** the glasses' mic is already streaming all day for "Hey Dojo." Run Apple's on-device sound classifier on that same stream and speak up — right at the wearer's ear — when a smoke alarm, doorbell, knock, ringing phone or kitchen timer goes off. No audio is recorded or uploaded; only labels are produced.

## Brief for the implementing agent

Read first: [`../README.md`](../README.md), [`../PRD.md`](../PRD.md) § Design principles, [`PRD-foundation-v2.md`](PRD-foundation-v2.md) (all of it — you consume every part), `ios/Brownmellon/Core/Interfaces.swift`, `ios/Brownmellon/Core/Mocks/MockGlassesSession.swift`, `ios/Brownmellon/Features/Setup/EmergencyContactSetupViewModel.swift` (the Setup/persistence pattern to copy), `ios/Brownmellon/Features/Scheduling/WakeWordDetector.swift` (`normalize` — commands arrive already normalized).

Own these paths and nothing else: `ios/Brownmellon/Features/Hearing/**`, `ios/BrownmellonTests/Hearing/**`, `ios/BrownmellonTests/Fixtures/Sounds/**`, plus one line each in `App/BrownmellonApp.swift` and `Features/Setup/SetupHomeView.swift`. **No backend.** This feature must never make a network call.

Verify: `cd ios && xcodegen generate && xcodebuild -project Brownmellon.xcodeproj -scheme Brownmellon -destination 'platform=iOS Simulator,name=iPhone 17' test`. Zero warnings.

## Problem / target user

Roughly one in three adults 65–74 and about half of those over 75 have hearing loss, and age-related loss takes the *high* frequencies first — which is exactly where a standard smoke alarm (~3 kHz), a doorbell chime, a microwave beep and a phone ringer live. The dangerous version is a smoke alarm going off in another room at night; the daily version is missing the door, the phone, or the kettle. Fire-safety guidance for people with hearing loss is to add lower-frequency and non-auditory signals — a spoken sentence in a low-mid voice, from a speaker sitting on the wearer's temple, plus a phone vibration, is precisely that, and the hardware is already on their face.

**Not for:** profound deafness (the wearer must be able to hear the glasses speaker), or as a replacement for a code-compliant strobe/bed-shaker alarm. Say so in the Setup screen.

## Goals

- Detect a curated set of household sounds from the glasses' mic and announce them within ~3 seconds, on-device, with no recording
- Zero false alarms in a quiet room over an hour; no repeat announcements while a single alarm keeps ringing
- Caregiver chooses which sounds are announced
- "Hey Dojo, what was that?" answers from the last minute of detections

## Non-goals

- Not speech: the classifier's `speech` class and anything conversation-shaped is ignored — this feature never transcribes, stores or reasons about what people say (the all-party-consent problem in `PRD.md` deferred list stays closed)
- Not a medical or life-safety certified device — no claim of NFPA/UL compliance
- Not sound *localization* ("the doorbell is behind you") — one mic array, no attempt
- Not custom sounds ("learn my oven's beep") in v1 — built-in classifier only

## Feature requirements

### 8a. Always-on detection

Runs from app launch, independent of which tab is showing (the current wake-word listener only runs while `SchedulingView` is visible — don't copy that; own your lifecycle from `BrownmellonApp`).

**Announced sounds and defaults** (caregiver-toggleable):

| Group | Sounds | Default | Spoken |
|---|---|---|---|
| Safety | smoke / CO detector, glass breaking | on | "I hear a smoke alarm." (repeated once after 2 s) |
| Someone's here | doorbell, knock | on | "Someone's at the door — I heard the doorbell." / "I heard knocking." |
| Phone | telephone ringing, ringtone | on | "Your phone is ringing." |
| Kitchen | microwave / oven / kettle beeps, alarm clock, boiling | on | "I heard a kitchen timer." / "I heard an alarm going off." |
| Ambient | dog bark, baby crying, siren, car horn, water running | off | "I heard a dog barking." etc. |

The exact classifier label strings must be taken from `SNClassifySoundRequest(classifierIdentifier: .version1).knownClassifications` at build time and mapped in one table (`SoundCatalog.swift`). Expected identifiers include `smoke_detector`, `siren`, `doorbell`, `knock`, `glass_breaking`, `telephone_bell_ringing`, `ringtone`, `alarm_clock`, `microwave_oven`, `boiling`, `dog_bark`, `baby_crying`, `car_horn`, `water_tap_faucet` — **verify every one against the API and drop any that don't exist; do not ship a label this doc guessed.** Print the full list once during development and pick the best matches for each row.

**Requirements:**
- Announce only when the label is enabled in settings, confidence ≥ threshold (start 0.7) in **two consecutive windows**, and the label is not in cooldown.
- **Cooldown:** 60 s per label after an announcement (a smoke alarm rings continuously; one announcement plus one repeat is the right amount). Safety group ignores the cooldown of *other* labels and is never suppressed by an ambient one.
- **Self-suppression:** drop all results while `glasses.isSpeaking` is true and for 1.0 s after it flips false — our own TTS leaks straight back into the mic array.
- **Redundant channels for the Safety group:** `UINotificationFeedbackGenerator(.warning)` haptic on the phone and a local notification (`UNUserNotificationCenter`) with the sound name and time in large text, so a wearer who takes their phone out sees "Smoke alarm heard — 8:42 PM." Request notification permission on first enable in Setup, never at launch.
- Mic permission is already requested by the wake-word path; if it's denied, the Setup screen says so and the feature stays off.

### 8b. "What was that?"

**Trigger** (claimed via `VoiceCommandHandler`): commands containing `what was that`, `what was that sound`, `what was that noise`, `did you hear that`, `what did you hear`.

Keep a rolling log of the last 60 s of *labels* (never audio): `(identifier, confidence, timestamp)` for anything ≥ 0.4 confidence, enabled or not.

| Situation | Says |
|---|---|
| Something ≥ 0.4 in the last 60 s | "About ten seconds ago it sounded like a doorbell." (most recent, most confident) |
| Nothing | "I didn't notice anything unusual in the last minute." |
| Feature disabled | "Sound alerts are turned off. Your helper can turn them on in Setup." |

### 8c. Caregiver Setup

`Features/Hearing/SoundAlertSettingsView.swift`, reached from `SetupHomeView` ("Sound Alerts"): a master toggle, one toggle per row of the table above, and a footer paragraph in plain language: on-device, nothing recorded, not a substitute for a proper alarm, needs the glasses on and the phone nearby. Persist as `SoundAlertSettings` via `SecureLocalStore` under key `soundAlertSettings`, same pattern as `EmergencyContactSetupViewModel`.

## Technical design

### Audio path

The glasses present to iOS as a Bluetooth headset; the real `GlassesSession` will run one `AVAudioEngine` on an `AVAudioSession` configured `.playAndRecord` with `.allowBluetooth` (renamed `.allowBluetoothHFP` in newer SDKs) so the HFP mic is the input route, and fan `inputNode` tap buffers out to consumers. This feature is one consumer, via `glasses.startAudioTap`. **You do not touch AVAudioSession or AVAudioEngine** — that belongs to the session. On Simulator, `MockGlassesSession.simulateAudio(fileURL:)` is your input.

Known constraint to test first on hardware: HFP mic audio is narrowband (8 kHz CVSD) or wideband (16 kHz mSBC). The classifier was trained on full-band audio; band-limiting will reduce confidence, especially for high-pitched beeps. Everything you need (smoke alarm ~3 kHz, doorbell, ringer) sits below the 4 kHz Nyquist limit even in the narrowband case, so expect it to work with lower margins — which is why the threshold and the two-window rule are settings, not constants. If the glasses mic proves unusable, the fallback is the phone's own mic — but iOS has a single input route at a time, so that is an either/or decision for the real session, not something this feature can do on its own.

### SoundAnalysis pipeline

```
tap buffer (AVAudioPCMBuffer, AVAudioTime)          from GlassesSession
        │  hop to a serial DispatchQueue — never analyze on the audio thread
        ▼
SNAudioStreamAnalyzer(format: buffer.format)        recreate if the format changes
        │  .analyze(buffer, atAudioFramePosition: when.sampleTime)
        ▼
SNClassifySoundRequest(classifierIdentifier: .version1)
        windowDuration 1.5 s, overlapFactor 0.5      → a result every ~0.75 s
        │  SNResultsObserving.request(_:didProduce:) → SNClassificationResult
        ▼
SoundAlertDecider (pure Swift, unit-tested)
        enabled? ≥ threshold? two consecutive? not in cooldown? not while speaking?
        │
        ▼
glasses.speak(...) + haptic + local notification;  RecentSoundLog.append(...)
```

### Files

```
ios/Brownmellon/Features/Hearing/
    SoundCatalog.swift            label → (group, spoken phrase, default on/off); verified against knownClassifications
    SoundAlertSettings.swift      Codable; master + per-group toggles; threshold
    SoundAlertDecider.swift       pure: (classification results over time, settings, isSpeaking, now) → announce? — no Apple frameworks beyond Foundation
    RecentSoundLog.swift          60 s ring buffer of labels
    SoundAlertMonitor.swift       owns SNAudioStreamAnalyzer + request + observer; consumes the tap; calls the decider; speaks
    SoundAlertSettingsView.swift  + ViewModel (SecureLocalStore)
    WhatWasThatHandler.swift      VoiceCommandHandler for 8b (can live on the monitor)
ios/BrownmellonTests/Hearing/
    SoundAlertDeciderTests.swift  two-window rule, cooldown, self-suppression, safety-overrides-ambient
    SoundCatalogTests.swift       every catalog identifier ∈ knownClassifications (this test is what enforces "don't ship a guessed label")
    SoundAlertMonitorTests.swift  feed fixture clips through the real analyzer via SNAudioFileAnalyzer; assert detection
ios/BrownmellonTests/Fixtures/Sounds/
    smoke_alarm.wav, doorbell.wav, knock.wav, silence.wav     mono, 16 kHz, ≤ 3 s, ≤ 200 KB each; record them yourself or use CC0 clips — note the source in a SOURCES.txt
```

`SoundAlertMonitor` is created once in `BrownmellonApp` (plain property, like `glasses`) and started at launch when settings say enabled. It is also passed in the `handlers:` array for 8b.

### Decider rules (make these the test names)

- `announcesAfterTwoConsecutiveWindowsAboveThreshold`
- `doesNotAnnounceOnSingleWindow`
- `respectsPerLabelCooldown` (second smoke alarm result at +30 s → silent; at +61 s → announces)
- `safetyLabelIgnoresAmbientCooldown`
- `suppressesWhileSpeakingAndOneSecondAfter`
- `disabledLabelNeverAnnounces`
- `speechClassIsAlwaysIgnored`
- `safetyAnnouncementRepeatsOnce`

### Simulator / demo

`SoundAlertSettingsView` gets a debug section (Simulator only, `#if targetEnvironment(simulator)`) with buttons "Play: smoke alarm / doorbell / knock / silence" that call `MockGlassesSession.simulateAudio(fileURL:realtime:true)` on the bundled fixtures. Expected demo beat: tap "smoke alarm" → ~2 s later the Simulator says "I hear a smoke alarm." twice and a banner notification appears. On hardware: play a smoke-alarm clip from a laptop speaker across the room while wearing the glasses.

## Success criteria

- Fixture clips: smoke alarm, doorbell and knock each detected in the analyzer test; `silence.wav` produces no announcement
- On device: smoke-alarm clip from a laptop at 3 m announced within 3 s in ≥ 8 of 10 trials; one hour of normal conversation and TV in a room → zero announcements
- Continuous alarm → exactly one announcement + one repeat, then silence until 60 s after it stops
- Feature works with the phone locked and in a pocket for ≥ 10 minutes (this is the `UIBackgroundModes: audio` test — do it early, it's the biggest unknown)
- No network requests from any file under `Features/Hearing/` (grep for `URLSession`/`URLRequest` — there should be none)

## Risks / open questions

- **HFP band-limiting** — the real determinant of accuracy; untestable until the DAT-backed session exists. Mitigation is the tunable threshold and the phone-mic fallback decision noted above.
- **Background execution** — `UIBackgroundModes: audio` keeps a *recording* session alive, but iOS can still end it under memory pressure or if the session is interrupted (a phone call). Handle `AVAudioSession.interruptionNotification` in the real session and restart the tap; this feature should tolerate `startAudioTap` being called again.
- **Battery** — no incremental glasses cost (the mic is already open for the wake word); phone-side classifier cost is small but measure it over an hour.
- **Open-ear paradox** — a wearer who can't hear a smoke alarm may also miss quiet TTS. Speak safety alerts at the session's maximum volume if DAT exposes volume; otherwise rely on the repeat + haptic + notification. Test with an actual hard-of-hearing person if at all possible.
- **Classifier gaps** — CO detectors and some modern smoke alarms use voice announcements, not tones; the built-in classifier may miss them. Document what was tested.

## Deferred

| Item | Why |
|---|---|
| Custom sound enrollment ("this is my oven") | Needs Create ML sound classifier training on-device; real, but not a weekend |
| Escalation to caregiver if a safety sound goes unacknowledged | Belongs with the Twilio emergency-escalation proposal, not here |
| Directional cue | Would need multi-mic beamforming data DAT doesn't expose |
