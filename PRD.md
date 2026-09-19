# Brownmellon — Product Requirements Document

Voice-first AI assistant on Ray-Ban Meta Gen 2 glasses + companion iOS app, for adults 60+. HackMIT weekend build.

Full platform feasibility research (DAT capabilities, battery data, legal risk analysis, sources): [`.lavish/index.html`](.lavish/index.html).

## Problem / target user

Adults 60+ face friction with managing appointments, reading small print (mail, labels, menus), remembering who people are, and getting help quickly when something goes wrong. Existing solutions assume comfort with phone screens and apps. Brownmellon moves the interaction to voice + glasses camera so the phone can stay in a pocket — the glasses have no display, so every interaction is spoken.

## Goals

- A working, demoable hands-free assistant on real Ray-Ban Meta Gen 2 hardware + a physical iPhone by the end of the hackathon weekend
- Every v1 feature works end-to-end, not just as a mock
- Be explicit about hardware/platform limits instead of overpromising — especially facial recognition and emergency calling, both of which are meaningfully constrained by iOS and by the current state of Meta's SDK

## Non-goals (v1)

- Not a medical device — no diagnosis, no clinical recommendations
- Not autonomously booking real appointments with outside businesses
- Not continuously recording or logging the wearer's environment
- Not supporting Android in v1
- Not a general people-identification system — facial recognition matches only against people the wearer's caregiver has explicitly enrolled

## v1 feature requirements

### 1. Voice scheduling & reminders

**Trigger:** "Hey Brownmellon, remind me to [x] at [time]" / "...schedule [x] on [date] at [time]"

**Flow:** continuous mic-only streaming on the phone (via DAT) → on-phone keyword spotter for "Hey Brownmellon" → intent/entity parsing via the backend (Claude) → write event to the wearer's Google Calendar → spoken confirmation through the glasses speaker.

**Requirements:**
- Must speak back what was captured and get an affirmative response before writing to the calendar (e.g. "Reminder set: take blood pressure pills, today at 6pm — is that right?")
- Supports one-time and recurring reminders ("every day at 8am")
- Ambiguous time references ("this afternoon") get a clarifying follow-up question, not a guess

### 2. Daily briefing

**Trigger:** "Hey Brownmellon, what do I have today?"

**Flow:** read the wearer's Google Calendar for today → summarize aloud through the glasses speaker.

**Requirements:** explicitly says "Nothing on your calendar today" when empty; summarizes rather than reading a long list verbatim.

### 3. Appointment-card scanning

**Trigger:** "Hey Brownmellon, scan this" while looking at a physical appointment card.

**Flow:** one still photo via DAT camera → backend parses date/time/provider/location from the image → spoken confirmation → write to Google Calendar on confirmation.

**Requirements:** single-shot capture only (episodic, battery-cheap); same confirm-before-write rule as feature 1.

### 4. "Read this to me"

**Trigger:** "Hey Brownmellon, read this to me" while looking at mail, a label, a menu, a bank statement, etc.

**Flow:** one still photo → backend OCR/vision extracts the text → read aloud through the glasses speaker.

**Requirements:** voice-triggered only — DAT does not currently expose the glasses' capture button/tap gesture as an event to third-party apps (confirmed against Meta's DAT GitHub discussions), so there is no button-press fallback in v1.

### 5. Facial recognition (consented enrollment only)

**Setup (caregiver, one-time per person):** in setup mode, the caregiver looks at the family member through the glasses camera and says "This is [name], my [relationship]." One photo is captured, a face embedding is generated via a single stateless backend call (the photo itself is not retained server-side), and the embedding + name/relationship are stored **locally on-device only** — encrypted, and never exposed through any UI, not even to the wearer, and never transmitted to any cloud store.

**Runtime:** wearer looks at a person and says a natural trigger phrase ("nice to meet you" / "who is this") → one photo captured → embedding computed via the same backend call → compared only against the locally stored enrolled set → spoken result ("That's your daughter, Angela") or an explicit "I don't recognize this person" — never a guess.

**Requirements:**
- Matches only against caregiver-enrolled individuals — never against any external or stranger database
- No user-facing way to view, browse, or export the enrolled face store — this is a deliberate design constraint
- Enrollment requires an explicit consent step from the person being enrolled (or their legal representative), not just the caregiver's say-so — this still counts as biometric-identifier collection under laws like Illinois's BIPA regardless of how the data is later stored

### 6. Emergency contact

**Setup (caregiver, one-time):** configure a relation → contact mapping (e.g. "daughter" → a phone number); 911 is always available as a target without separate setup.

**Trigger:** a single, dedicated phrase, separate from "Hey Brownmellon" and short enough to say reliably under stress — recognized by its own always-on listener, bypassing the general NLU pipeline entirely so this path stays simple and reliable.

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
| In-person scam detection | Needs recording live conversations with people who haven't consented — 12 U.S. states require all-party consent to record a private conversation |
| Ambient voice-to-calendar | Higher false-positive risk with no screen to show a draft; revisit once the confirm-before-add pattern is proven via feature 1 |
| Medication mix-up check | Real value, but needs a careful liability pass (label-reading, not medical advice) before it's ready to scope |
| Companion check-ins | Targets loneliness/isolation, not core to this build's thesis |
| Contact-aware caller announcement | Nice-to-have, not core |
| Missed-call notification | Android-only pattern; may also duplicate Meta's own native call announcement |
| Audio wayfinding | Feasible, but the mic+speaker HFP audio-quality tradeoff (drops to 8kHz mono) needs testing before committing to it |

## Platform & architecture

- **Client:** native iOS (Swift), using Meta's Wearables Device Access Toolkit (DAT) for camera/mic/speaker access to Ray-Ban Meta Gen 2 glasses (audio-only hardware — no display, no Neural Band).
- **Calendar:** Google Calendar via Google Sign-In + Calendar API. OAuth consent screen in "Testing" publishing status — sufficient for a hackathon demo, full Google verification not required.
- **AI backend:** one thin serverless function (Vercel), calling the Claude API directly. All photo/audio processing is stateless — sent for a single inference call, never persisted server-side. Only structured results (parsed text, face embeddings, transcripts, calendar events) return to the phone and are stored there.
- **Local storage:** face embeddings + enrolled names/relationships, emergency contact mapping, auth tokens — encrypted at rest on-device (iOS Keychain / file protection), never synced to any backend.
- **Auth:** Google Sign-In only; single wearer, single device assumption for v1.
- **Wake word:** "Hey Brownmellon" for general voice commands (features 1–4). The emergency trigger (feature 6) uses its own dedicated phrase and listener, independent of the general pipeline.

## Design principles (apply across every feature)

- Every calendar write requires spoken confirmation before it commits
- Camera use is episodic (single-shot captures) — never continuous streaming, which is why several candidate features above are deferred
- No feature collects, stores, or transmits data about anyone other than the wearer without that person's own consent

## Suggested build order

1. Voice scheduling + reminders + "Hey Brownmellon" keyword trigger — foundational; everything else reuses this infrastructure
2. Daily briefing — trivial once #1 exists
3. Appointment-card scanning + "Read this to me" — share the same photo-capture → backend-vision pipeline
4. Facial recognition — enrollment flow, then runtime matching
5. Emergency contact — most platform-constrained and safety-sensitive; build and test last, on real hardware with a real phone number

## Known risks / open items

- iOS's tap-to-confirm call restriction makes "emergency contact" meaningfully weaker than a true hands-free SOS — frame it honestly in the demo, don't oversell it
- Only one physical Ray-Ban Meta Gen 2 pair confirmed available — plan device-testing time across the team accordingly
- DAT is in public developer preview and not yet cleared for App Store distribution — fine for a sideloaded hackathon build, not a launch
- Set up the Google Cloud project and OAuth consent screen early — losing build time to this later would hurt
