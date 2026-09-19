# Feature 9 — Memory ("Remember where I parked")

**Status:** v2 feature, own workstream. Depends on [`PRD-foundation-v2.md`](PRD-foundation-v2.md) (handler hook, `UploadImage`, `NSLocationWhenInUseUsageDescription`).

**One line:** the wearer offloads small facts to the glasses by voice — "remember I parked in section B," "remember I put my glasses case in the kitchen drawer," "remember Frank is the new neighbor" — and gets them back by asking. Parking gets special treatment: the glasses photograph the spot marker and save the GPS fix, so "where did I park?" answers with the sign text, how long ago, and how far away the car is.

## Brief for the implementing agent

Read first: [`../README.md`](../README.md), [`../PRD.md`](../PRD.md) § Feature 1 (so you don't collide with "remind me") and § Design principles, [`PRD-foundation-v2.md`](PRD-foundation-v2.md) § 1, 2, 3, 7, `ios/Brownmellon/Core/VoiceAssistant.swift` (from the foundation — how handlers are registered), `ios/Brownmellon/Features/Scheduling/SchedulingCoordinator.swift` (`spokenDateTime` — reuse it), `ios/Brownmellon/Features/Scheduling/IntentClient.swift` and `backend/api/parse-intent.ts` (Gemini + zod-validated JSON; the request/response style your recall endpoint copies), `ios/Brownmellon/Features/Vision/VisionBackendClient.swift` (you call `readAloud` for the parking sign), `ios/Brownmellon/Features/Setup/EmergencyContactSetupViewModel.swift` (persistence pattern).

Own: `ios/Brownmellon/Features/Memory/**`, `ios/BrownmellonTests/Memory/**`, `backend/api/recall.ts`, `backend/lib/recall*.ts` and `backend/tests/recall*.test.ts` if you split pure logic out for testing, plus the single wiring lines in `App/BrownmellonApp.swift` named in the foundation doc § 7. Reuses `GEMINI_API_KEY` — nothing to add to `.env.example`. Do not modify `api/parse-intent.ts` or `IntentClient.swift`.

Verify: `cd ios && xcodegen generate && xcodebuild ... test` (README § iOS app); `cd backend && npx tsc --noEmit`. Zero warnings.

## Problem / target user

The everyday memory failures that make older adults feel they're "losing it" are not dramatic — they're *where did I put it, where did I park, what was that person's name*. Each one costs minutes of anxious searching and, over time, confidence. Phones have notes apps, but the moment of "I should write this down" happens with hands full, standing in a parking lot; the wearer already has a mic at their mouth and can just say it. Retrieval has to be equally effortless — a question, not a search.

Parking is the sharpest instance: a large lot, no landmarks, and the wearer may not be able to read the small level/row sign at distance — which is exactly what the glasses camera is for.

**Not for:** clinical memory care. This is a notebook you talk to. No diagnosis, no cognitive scoring, and it never volunteers "you asked me that already."

## Goals

- Save a note by voice in one utterance, with spoken confirmation, in under 3 seconds
- Recall by natural question with the note's content *and when it was saved*
- Parking: photo of the spot marker (read by the existing OCR endpoint) + GPS fix, saved together; recall speaks sign text, elapsed time, distance and direction; "take me to my car" opens walking directions
- Everything stored on the phone, encrypted; the recall call to the backend is stateless

## Non-goals

- Not ambient — the glasses never save anything the wearer didn't explicitly ask to remember (PRD non-goal: no continuous recording/logging)
- Not a calendar — "remind me to X at 3" stays Feature 1; this feature must **not** claim commands starting with `remind`
- Not shared with a caregiver in v1
- Not a general chatbot — recall answers come only from saved notes; if there isn't one, it says so

## Feature requirements

### 9a. Save — "remember …"

**Claimed commands** (normalized: lowercase, no punctuation): starts with `remember`, `remember that`, `note that`, `don't forget that`, `dont forget that`, `make a note that`. Strip the prefix; what remains is the note text. Reject an empty remainder ("Remember what? Try: Hey Dojo, remember I parked in section B.").

**Parking detection:** the note text (or the whole command) contains `park`. Two sub-cases:
- `remember where i parked` / `remember where i'm parked` / `remember my parking spot` (no other content) → **take a photo** of whatever the wearer is looking at, send it to `VisionBackendClient.readAloud` (existing `api/ocr` mode `read`), keep the first ~120 characters of returned text as `signText`; capture a GPS fix.
- `remember i parked in section b` → note text is `i parked in section b`; capture a GPS fix; no photo.

**Every note** captures a GPS fix if location permission is granted (one `CLLocationUpdate.liveUpdates()` value with `horizontalAccuracy ≤ 65 m`, 5 s timeout, otherwise `nil` — never block a save on GPS). Ask for `whenInUse` permission the first time a save happens, not at launch.

**Spoken confirmation:**

| Case | Says |
|---|---|
| Plain note | "Got it. I'll remember: I put my glasses case in the kitchen drawer." (the note text, first person as spoken) |
| Parking, photo read something | "Got it. I saved your parking spot — the sign says Level 3, Row F." |
| Parking, photo read nothing / failed | "Got it. I saved where you're parked." (location still saved; photo failure is silent) |
| Parking, no location permission and no sign text | "Got it. I saved a note that you parked, but I can't save the location without permission. You can turn it on in Settings." |

### 9b. Recall — "where did I …"

**Claimed commands:** contains any of `where did i park`, `where's my car`, `where is my car`, `where did i leave the car`, `where did i put`, `where's my`, `where is my`, `where are my`, `what did i tell you`, `what did i say about`, `do you remember`, `what do you remember about`, `what did i ask you to remember`. Must **not** claim `where is my next appointment`-style calendar phrasing — if the command also contains `appointment`, `meeting`, `schedule` or `calendar`, return `false`.

**Parking recall** (`park` / `car` variants) is answered **on-device, no backend**: take the newest note with `kind == .parking`.

| Situation | Says |
|---|---|
| Note with sign text + both locations | "You parked about two hours ago. The sign said Level 3, Row F. Your car is about 300 feet to the northeast." |
| Note with location, no sign | "You parked about two hours ago, about 300 feet to the northeast of here." |
| Note text only | "You told me about two hours ago: I parked in section B." |
| No parking note | "I don't have a parking spot saved. Next time, say: Hey Dojo, remember where I parked." |
| Newest parking note is > 24 h old | prefix with "This might be old —" |

Distance: `CLLocation.distance(from:)` → spoken in feet under 1000 ft, otherwise tenths of a mile; direction from the bearing, 8-point compass. Elapsed time via `RelativeDateTimeFormatter` with `.spellOut` ("two hours ago"); under 60 s say "just now."

**"Take me to my car" / "directions to my car"** → `MKMapItem(placemark:)` for the saved coordinate, `openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])`, and speak "Opening walking directions on your phone." If no coordinate: "I don't have your car's location saved."

**General recall** goes to the new backend `api/recall.ts` (Gemini, same as every other endpoint), which grounds an answer in the wearer's own notes:

- Send the question plus the **most recent 100 notes** (id, text, kind, createdAt ISO with offset, signText). Notes are the wearer's own data; the call is stateless and nothing is persisted server-side (PRD § AI backend). Never send coordinates — they aren't needed to answer and shouldn't leave the phone.
- Response: `{ answer: string, matchedNoteIds: string[] }`. `answer` is spoken verbatim, so the backend prompt must produce one or two spoken sentences that include *when* ("This morning at nine you told me…"). If nothing matches: exactly `"I don't have a note about that."` and an empty `matchedNoteIds`.
- If there are zero notes, don't call the backend: "You haven't asked me to remember anything yet."
- On any backend failure: "I couldn't check my notes just now. Please try again."

### 9c. Forget

**Claimed:** starts with `forget`. `forget my parking spot` / `forget where i parked` → delete the newest parking note; `forget that` / `forget the last thing` → delete the newest note of any kind; `forget everything` → speak "Say 'Hey Dojo, yes, forget everything' to confirm" and only act on that exact follow-up within 30 s (the only two-step interaction in this feature — everything else is one utterance). Confirm every deletion aloud with the note text.

### 9d. Phone UI (secondary)

`MemoryView` on a "Memory" tab: list of notes (newest first, with time, a map pin glyph if a location is saved, a "Directions" button on parking notes), swipe to delete, and the same Simulator text field pattern as `SchedulingView` for typing a command. This is a debugging and demo surface; the product is the voice path.

## Technical design

### Data

```swift
struct MemoryNote: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case parking, general }
    let id: UUID
    var kind: Kind
    var text: String                 // what the wearer said, prefix stripped; "" allowed for photo-only parking
    var signText: String?            // OCR of the spot marker (parking only)
    let createdAt: Date
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
}
```

`MemoryStore` wraps `SecureLocalStore` under key `memoryNotes` as one array (same as emergency contacts). Cap **300** notes — on insert past the cap, drop the oldest non-parking note first. This keeps the Keychain item well under 100 KB.

### Command routing

`MemoryCommandHandler: VoiceCommandHandler` does all classification with plain string checks against the already-normalized command (see `WakeWordDetector.normalize`), in this order: forget → save → parking recall → directions → general recall → `false`. Every rule is a pure function in `MemoryCommandParser` returning an enum:

```swift
enum MemoryCommand: Equatable {
    case save(text: String, wantsParkingPhoto: Bool, isParking: Bool)
    case recallParking
    case directionsToCar
    case recall(question: String)
    case forgetLastParking, forgetLast, forgetAllRequest, forgetAllConfirm
}
```

This parser is where the tests live. ASR garbles things — include variants like `remember i parked on level three` and `wear did i park`? No: do not chase misrecognitions of ordinary English words; `WakeWordDetector` only does that for the made-up wake word. Keep the matching literal and well-tested.

### Backend `api/recall.ts`

Copy the structure of `api/parse-intent.ts` exactly (`VercelRequest`/`VercelResponse` handler, `GoogleGenAI` with `gemini-3.6-flash`, the `generateWithRetry` helper, `zod` request schema *and* zod validation of the model's JSON output, fence-stripping, same error → `FALLBACK` handling, same `GEMINI_API_KEY`). Request:

```ts
{ question: string, now: string /* ISO w/ offset */, timeZone: string,
  notes: { id: string, kind: "parking" | "general", text: string, signText: string | null, createdAt: string }[] }  // ≤ 100
```

System prompt essentials: you answer only from the supplied notes; speak as the glasses to an adult over 60; one or two short sentences; always say when the note was saved, relative to `now` ("this morning at nine," "last Tuesday"); prefer the most recent matching note; if no note plausibly answers, reply exactly `I don't have a note about that.`; never invent details not in a note. Output `{ answer, matchedNoteIds }`. `FALLBACK.answer` = `"I couldn't check my notes just now. Please try again."`.

### Files

```
ios/Brownmellon/Features/Memory/
    MemoryNote.swift
    MemoryStore.swift                SecureLocalStore-backed, cap + prune
    MemoryCommandParser.swift        pure; the enum above
    MemoryCommandHandler.swift       VoiceCommandHandler; orchestrates store, location, photo, backend, speech
    LocationFix.swift                one-shot CLLocationUpdate.liveUpdates() with timeout + accuracy gate
    ParkingSpeech.swift              distance/bearing/elapsed → sentences (pure, tested)
    RecallClient.swift               calls api/recall.ts; mirrors IntentClient's style
    MemoryView.swift + MemoryViewModel.swift
ios/BrownmellonTests/Memory/
    MemoryCommandParserTests.swift   every claimed phrase + every must-NOT-claim phrase ("remind me…", "where is my next appointment")
    ParkingSpeechTests.swift         feet vs miles, compass points, "just now", > 24 h prefix
    MemoryStoreTests.swift           cap/prune order, parking survives pruning
backend/api/recall.ts
```

Wiring in `BrownmellonApp`: `private let memory = MemoryCommandHandler(glasses:, store:, vision: VisionBackendClient(), recall: RecallClient(endpoint:))`; pass in the `VoiceAssistant` `handlers:` (foundation § 7); `MemoryView(viewModel:)` as a tab ("Memory", `brain.head.profile`).

**Voice-path tests (required):** build a `VoiceAssistant` with `MockGlassesSession`, `MockSecureLocalStore`, a stub `VisionBackendClient`-shaped dependency and a stub recall client (inject via protocols — `RecallClient` and the OCR call must be behind protocols so tests never hit the network), then drive it with `simulateTranscript`:
- `"hey dojo remember i parked in section b"` → `onSpeak` receives "Got it. I'll remember: I parked in section B." and the store holds one `.parking` note.
- `"hey dojo where did i park"` → speaks the recall sentence including "just now."
- `"hey dojo remind me to take my pills at 8"` → the memory handler returns `false` (assert the stubbed intent path was reached).
These prove the feature is voice-driven end to end, minus ASR.

### Simulator / demo

Type into the Memory tab's field: `remember I parked in section B` → hear the confirmation; `where did I park` → hear it back with "just now." Simulator location: set a fixed location in Xcode's Debug menu so distance/bearing render. For the photo path, the mock's photo picker opens — pick a photo of a parking-garage sign. Demo beat on hardware: walk away from the car, "Hey Dojo, where did I park?" → "…about 300 feet to the northeast."

## Success criteria

- All parser tests green, including the negative cases; `remind me to…` is provably never claimed
- Save → confirmation ≤ 3 s without photo; ≤ 8 s with the parking photo (dominated by the OCR round-trip)
- Parking recall works offline (no network in that path — assert by code review of `MemoryCommandHandler`)
- `api/recall.ts` typechecks and, given 3 sample notes, answers a matching question with the time phrase and answers a non-matching one with the exact fallback string
- Notes survive app relaunch when `KeychainSecureLocalStore` is wired (they won't with the in-memory mock — say so in the tab's empty state on Simulator)

## Risks / open questions

- **ASR of place words** — "section B" may arrive as "section be." Acceptable: the wearer hears exactly what was captured in the confirmation and can re-say it.
- **GPS in parking garages** is often unavailable — hence the photo of the sign is the primary parking signal and the fix is best-effort with a hard 5 s timeout.
- **Recall latency** — one Gemini round-trip on the general path; Feature 1 has the same characteristic. Keep notes ≤ 100 and the prompt short.
- **No local API key** — `GEMINI_API_KEY` is only set on the Vercel project. Verify the endpoint with `npx tsc --noEmit` plus unit tests of the pure parsing/validation logic (extract it into `backend/lib/`, run with `node --test`); live behavior is checked after merge to `main` deploys it.
- **Location privacy** — coordinates never leave the phone (not sent to `api/recall.ts`); the handler must be written so this is obvious in code review.

## Deferred

| Item | Why |
|---|---|
| Spoken turn-by-turn to the car | `MKDirections` steps read through the glasses is feasible; validate the open-ear audio outdoors first (same note as "audio wayfinding" in `PRD.md`) |
| Caregiver visibility of notes | Needs the consent/dashboard design from the v2 proposal |
| On-device retrieval (NaturalLanguage embeddings) instead of the backend | Would make general recall offline; worth it once the phrasing quality of the backend path is established |
| Notes feeding the daily briefing ("you said your car is in section B") | Cross-feature; after both are stable |
