# Brownmellon — Product Requirements Document

Voice-first AI assistant on Ray-Ban Meta Gen 2 glasses + companion iOS app, for adults 60+. HackMIT weekend build.

Full platform feasibility research (DAT capabilities, battery data, legal risk analysis, sources): [`.lavish/index.html`](.lavish/index.html).

## Problem / target user

Adults 60+ face friction with managing appointments, reading small print (mail, labels, menus), evaluating suspicious advertisements, and getting help quickly when something goes wrong. Existing solutions assume comfort with phone screens and apps. Brownmellon moves the interaction to voice + glasses camera so the phone can stay in a pocket — the glasses have no display, so every interaction is spoken.

## Goals

- A working, demoable hands-free assistant on real Ray-Ban Meta Gen 2 hardware + a physical iPhone by the end of the hackathon weekend
- Every v1 feature works end-to-end, not just as a mock
- Be explicit about hardware/platform limits instead of overpromising — especially that ad-scam screening is advisory, not proof, and that emergency calling is meaningfully constrained by iOS

## Non-goals (v1)

- Not a medical device — no diagnosis, no clinical recommendations
- Not autonomously booking real appointments with outside businesses
- Not continuously recording or logging the wearer's environment
- Not supporting Android in v1
- Not a fraud-verification service — advertisement screening provides a risk signal, not a definitive determination that an ad is legitimate, AI-generated, or a scam

## v1 feature requirements

### 1. Voice scheduling & reminders

**Trigger:** "Hey Dojo, remind me to [x] at [time]" / "...schedule [x] on [date] at [time]"

**Flow:** continuous mic-only streaming on the phone (via DAT) → on-phone keyword spotter for "Hey Dojo" → intent/entity parsing via the backend (Claude) → write event to the wearer's Google Calendar → spoken confirmation through the glasses speaker.

**Requirements:**
- Must speak back what was captured and get an affirmative response before writing to the calendar (e.g. "Reminder set: take blood pressure pills, today at 6pm — is that right?")
- Supports one-time and recurring reminders ("every day at 8am")
- Ambiguous time references ("this afternoon") get a clarifying follow-up question, not a guess

### 2. Daily briefing

**Trigger:** "Hey Dojo, what do I have today?"

**Flow:** read the wearer's Google Calendar for today → summarize aloud through the glasses speaker.

**Requirements:** explicitly says "Nothing on your calendar today" when empty; summarizes rather than reading a long list verbatim.

### 3. Appointment-card scanning

**Trigger:** "Hey Dojo, scan this" while looking at a physical appointment card.

**Flow:** one still photo via DAT camera → backend parses date/time/provider/location from the image → spoken confirmation → write to Google Calendar on confirmation.

**Requirements:** single-shot capture only (episodic, battery-cheap); same confirm-before-write rule as feature 1.

### 4. "Read this to me"

**Trigger:** "Hey Dojo, read this to me" while looking at mail, a label, a menu, a bank statement, etc.

**Flow:** one still photo → backend OCR/vision extracts the text → read aloud through the glasses speaker.

**Requirements:** voice-triggered only — DAT does not currently expose the glasses' capture button/tap gesture as an event to third-party apps (confirmed against Meta's DAT GitHub discussions), so there is no button-press fallback in v1.

### 5. Advertisement scam detection (OCR-only)

**Trigger:** "Hey Dojo, check this ad" while looking at a printed or on-screen advertisement.

**Flow:** one still photo → backend OCR extracts the advertisement's visible text → the backend assesses the text for AI/synthetic-content signals and scam-risk patterns (for example, impersonation, urgency, guaranteed returns, payment demands, or suspicious links) → spoken result through the glasses speaker.

**Requirements:**
- Single-shot, voice-triggered capture only; the photo and OCR text are used for one stateless inference call and are never retained server-side
- The response must state a clear advisory result: whether the **text** shows AI/synthetic-content signals, whether it has potential scam indicators, and the specific visible cues that led to the alert
- OCR-only means v1 does not inspect pixels or prove who created an advertisement; it cannot reliably determine whether an image itself was AI-generated or whether an ad is definitively a scam
- High-risk results should prompt a safe next action, such as "Don't call or pay from this ad; verify the organization through its official website or a trusted contact"

### 6. Emergency contact

**Setup (caregiver, one-time):** configure a relation → contact mapping (e.g. "daughter" → a phone number); 911 is always available as a target without separate setup.

**Trigger:** a single, dedicated phrase, separate from "Hey Dojo" and short enough to say reliably under stress — recognized by its own always-on listener, bypassing the general NLU pipeline entirely so this path stays simple and reliable.

**Flow:** phrase detected → phone opens the native iOS call screen for the configured contact or 911 → glasses speak "Calling [contact] now, please confirm on your phone" → wearer or a bystander taps once on the phone to connect.

**Requirements:**
- Must be communicated clearly, in-app and during onboarding, that this is **not** a fully hands-free call — iOS does not allow third-party apps to place any call, including to 911, without a user-confirming tap
- No automatic fall or incapacitation detection in v1 — this is a voice-triggered call only (see deferred list)

## Explicitly deferred (v2 / future work)

| Feature | Why deferred |
|---|---|
| Automatic fall detection (IMU-based) | Meta's DAT still lists accelerometer/IMU access as unshipped/future as of the current SDK release |
| Camera-based "walk mode" fall-anomaly detection | Continuous streaming exceeds the ~30 min battery ceiling already measured for this hardware; reopens the same privacy problem as "find lost things"; a head-mounted camera is an unvalidated fall signal |
| Scam-call alerts | Needs Android's `NotificationListenerService`; out of scope now that v1 targets iOS only |
| Auto-scheduling (books real appointments) | Needs an outbound-calling/booking agent against arbitrary businesses — a different product, not a glasses feature |
| Find lost things | Needs continuous recording of the wearer's home — blocked on both battery and privacy grounds |
| Live-conversation scam detection | Needs recording live conversations with people who haven't consented — 12 U.S. states require all-party consent to record a private conversation |
| Ambient voice-to-calendar | Higher false-positive risk with no screen to show a draft; revisit once the confirm-before-add pattern is proven via feature 1 |
| Medication mix-up check | Real value, but needs a careful liability pass (label-reading, not medical advice) before it's ready to scope |
| Companion check-ins | Targets loneliness/isolation, not core to this build's thesis |
| Contact-aware caller announcement | Nice-to-have, not core |
| Missed-call notification | Android-only pattern; may also duplicate Meta's own native call announcement |
| Audio wayfinding | Feasible, but the mic+speaker HFP audio-quality tradeoff (drops to 8kHz mono) needs testing before committing to it |

## Platform & architecture

- **Client:** native iOS (Swift), using Meta's Wearables Device Access Toolkit (DAT) for camera/mic/speaker access to Ray-Ban Meta Gen 2 glasses (audio-only hardware — no display, no Neural Band).
- **Calendar:** Google Calendar via Google Sign-In + Calendar API. OAuth consent screen in "Testing" publishing status — sufficient for a hackathon demo, full Google verification not required.
- **AI backend:** one thin serverless function (Vercel), calling the Claude API directly. All photo/audio processing is stateless — sent for a single inference call, never persisted server-side. Only structured results (parsed text, ad-scam assessments, transcripts, calendar events) return to the phone and are stored there.
- **Local storage:** emergency contact mapping and auth tokens — encrypted at rest on-device (iOS Keychain / file protection), never synced to any backend.
- **Auth:** Google Sign-In only; single wearer, single device assumption for v1.
- **Wake word:** "Hey Dojo" for general voice commands (features 1–4). The emergency trigger (feature 6) uses its own dedicated phrase and listener, independent of the general pipeline.

## Deployment & device pairing

**Apple Developer account:** a free Apple ID is sufficient for v1 — build and run on your own iPhone via Xcode at no cost. Tradeoffs to plan around: the install certificate expires every 7 days (rebuild from Xcode to renew), free accounts are capped at 3 sideloaded apps per device and 3 registered device UDIDs per rolling 7-day window, and entitlements like Push Notifications, Sign in with Apple, and iCloud aren't available (none of which Brownmellon needs — auth is Google Sign-In only). The $99/year Developer Program is only needed for TestFlight or App Store distribution, not for building or running the app itself.

**Fastest iteration loop:** phone connected via USB or on the same Wi-Fi with wireless debugging → Xcode → Cmd+R. Builds and installs in under a minute for an app this size — this is the loop to use while actively building, not TestFlight.

**Getting a build onto teammates' phones without a cable** (requires the paid account): archive → upload to App Store Connect → add up to 100 internal testers (no Apple review required for internal testing) → install via the TestFlight app. Expect a few minutes of build-processing latency — good for demo day, not for the live edit-test loop.

**Meta's own developer registration (separate from Apple, required regardless of account tier):** register the app in Meta's Wearables Developer Center (a Managed Meta Account or org) to get a `MetaAppID` and `ClientToken`; these plus the Apple `TeamID` and an `AppLinkURLScheme` go in `Info.plist`. The URL scheme is how the Meta AI app hands device-access authorization back to Brownmellon. Note: Meta's docs state that general App Store publishing isn't open during this developer-preview period — only "testers within your organization/team" can receive builds, via Xcode sideload or TestFlight internal testing. This is a hard ceiling independent of Apple account tier.

**Runtime pairing flow, in an actual setting:**
1. Glasses are paired to a phone the normal consumer way, through Meta's own Meta AI app — this has to happen before any third-party app can access them.
2. Brownmellon launches, requests device access, and hands off to the Meta AI app for a one-time permission grant (wearer or caregiver approves it, similar to any other OAuth-style consent screen).
3. Brownmellon opens a DAT session claiming the camera/mic/speaker. Only one third-party app can hold this session at a time, so it can't run alongside another DAT app or Meta AI's own live features simultaneously.
4. The phone must stay within Bluetooth range of the glasses (tens of feet) — all compute (mic streaming, camera capture, backend calls) happens on the phone, the glasses are a peripheral.
5. **Open risk, test early:** per DAT's own changelog, backgrounding the phone app stops video decoding even though the camera transport keeps flowing at the transport level. Whether the "Hey Dojo" mic-only wake-word listener keeps working with the phone locked in a pocket is unconfirmed — this determines whether "hands-free, phone in pocket" is real or whether the phone needs to stay unlocked/foregrounded. Test in the first build session, since it affects the UX story for every voice-triggered feature.

## Design principles (apply across every feature)

- Every calendar write requires spoken confirmation before it commits
- Camera use is episodic (single-shot captures) — never continuous streaming, which is why several candidate features above are deferred
- No feature collects, stores, or transmits data about anyone other than the wearer without that person's own consent

## Parallel workstreams (3 people, git worktrees)

The 6 features split into 3 vertical slices, grouped by shared pipeline rather than by feature number — each owns its own Swift files, its own backend endpoint file, and (where relevant) its own screen, so the three worktrees touch almost no common files after the foundation layer lands.

### Foundation (build first, interfaces before implementations)

A few pieces are genuinely shared — don't let building them for real block anyone. Agree on these protocol shapes immediately (they can live in one `Core/Interfaces.swift` committed in the first few minutes), then each of the three people codes against a mock implementation until the real one lands:

```swift
protocol GlassesSession {
    func speak(_ text: String) async
    func startListening(onTranscript: @escaping (String) -> Void)
    func stopListening()
    func capturePhoto() async throws -> UIImage
}

protocol CalendarService {
    func createEvent(title: String, start: Date, end: Date?) async throws
    func todaysEvents() async throws -> [CalendarEvent]
}

protocol SecureLocalStore {
    func save<T: Codable>(_ value: T, forKey: String) throws
    func load<T: Codable>(forKey: String) throws -> T?
}
```

- **`GlassesSession` (DAT wrapper)** — the highest-risk, most-shared piece (covers mic streaming, camera capture, and speaker output through one session object — don't split this across people, it's one underlying connection). Recommend whoever's most comfortable with Bluetooth/hardware integration builds this first, in their own worktree, and merges it to `main` as soon as the interface is stable — even before every method is fully correct. Everyone else starts immediately against `MockGlassesSession` and swaps to the real one via a rebase once it lands.
- **`CalendarService`** — needed by Workstream A (both features) and Workstream B (appointment-card scanning writes an event). Whoever gets to it first in Workstream A or B builds it for real; the other just consumes the interface.
- **`SecureLocalStore`** — needed only by Workstream C for the emergency-contact mapping; C builds it as part of its own work, with no cross-workstream dependency.
- **One-time setup, not per-workstream work** — do these once, in any worktree, before anyone needs them: Meta Wearables Developer Center registration (`MetaAppID`/`ClientToken`), Google Cloud project + OAuth consent screen (Testing mode), Vercel project + Claude API key.

### Workstream A — Voice & Calendar

**Owns:** Feature 1 (voice scheduling/reminders + "Hey Dojo" keyword trigger) and Feature 2 (daily briefing).
**Files:** `Features/Scheduling/`, backend `api/parse-intent.ts`.
**Depends on:** `GlassesSession` (mic), `CalendarService` (read + write) — mock until foundation lands.
**Produces for others:** `CalendarService`, if this workstream builds it first.

### Workstream B — Vision & Documents

**Owns:** Feature 3 (appointment-card scanning) and Feature 4 ("read this to me") — grouped together because they share the same photo-capture → backend-vision pipeline.
**Files:** `Features/Vision/`, backend `api/ocr.ts`.
**Depends on:** `GlassesSession` (camera), `CalendarService` (write-only, for feature 3) — mock until foundation lands.
**Produces for others:** nothing required by A or C.

### Workstream C — Safety & Emergency

**Owns:** Feature 5 (advertisement scam detection) and Feature 6 (emergency contact) — grouped together because both deliver a simple, spoken safety response after a direct user request.
**Files:** `Features/Safety/`, `Features/Setup/`, backend `api/scam-check.ts`.
**Depends on:** `GlassesSession` (camera + mic) and `SecureLocalStore` (for the emergency-contact mapping; C builds it) — mock `GlassesSession` until foundation lands. Telephony (`tel:` call placement) is native iOS, no dependency on anyone.
**Produces for others:** nothing required by A or B.

### Suggested worktree setup

```bash
git worktree add ../hackmit-voice-calendar -b feature/voice-calendar
git worktree add ../hackmit-vision-docs -b feature/vision-documents
git worktree add ../hackmit-safety-emergency -b feature/safety-emergency
```

**Merge order:** foundation interfaces + whichever real implementation (DAT wrapper, Calendar service) lands first → `main`, immediately, even partially done. Then each workstream rebases onto `main` periodically to pick up the real implementations as they replace the mocks. Feature branches merge to `main` independently as they're demo-ready — there's no required merge order between A, B, and C themselves, since they don't touch each other's files.

**Within each workstream**, the original single-track build order still applies: Workstream A builds feature 1 before feature 2 (2 reuses 1's trigger infra); Workstream C builds feature 5's OCR-and-assessment flow before feature 6, since its camera capture and spoken safety-response patterns are reusable.

## Known risks / open items

- iOS's tap-to-confirm call restriction makes "emergency contact" meaningfully weaker than a true hands-free SOS — frame it honestly in the demo, don't oversell it
- Only one physical Ray-Ban Meta Gen 2 pair confirmed available — plan device-testing time across the team accordingly
- DAT is in public developer preview and not yet cleared for App Store distribution — fine for a sideloaded hackathon build, not a launch
- Set up the Google Cloud project and OAuth consent screen early — losing build time to this later would hurt
- OCR and model-based scam screening can produce false positives and false negatives; frame every result as an explanation of visible risk signals, not a verdict
