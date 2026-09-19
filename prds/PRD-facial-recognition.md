# Brownmellon — Facial Recognition (Enrolled-People Memory Aid)

**Status:** proposal / stretch feature, not part of the committed v1 scope in [`PRD.md`](../PRD.md). Lives on its own branch so it can be evaluated and demoed without touching the three v1 workstreams.

**One-line pitch:** the wearer looks at someone, says "Hey Dojo, who is this?", and the glasses quietly tell them — but only for the handful of family members and caregivers who chose to be enrolled. Nothing else. Nobody else.

## Context — read this first

This feature has already been through one full cycle on this project, and the new work should build on that rather than repeat it:

1. **Original v1 PRD** (`ddea140`) shipped with facial recognition as Feature 5 ("consented enrollment only"), owned by a "Workstream C — Identity & Safety," with a planned `api/face-embed.ts` backend endpoint and `Features/Identity/` on iOS.
2. **Feasibility research** ([`.lavish/index.html`](../.lavish/index.html) § "Facial ID risk") concluded it is *technically trivial* and *legally/reputationally the riskiest thing in the plan*: Meta built this exact feature ("Name Tag") for this exact hardware, shipped it dormant to 50M+ Ray-Ban Meta Gen 2 devices, and pulled it on June 9, 2026 after 70+ civil-liberties orgs objected. The research's verdict was still "build, consented-enrollment-only, capped scope, rank 3 of 4" — not "don't build."
3. **Cut from v1** (`406c424`, Sep 19 2026): Feature 5 was replaced with OCR-only advertisement scam detection and Workstream C became "Safety & Emergency." The face-embedding endpoint was never built.

**What this document proposes:** re-introduce facial recognition as an *additive* **Feature 7**, in a fourth vertical slice, with two changes from the original spec that make it materially safer and cheaper to build than what was cut:

- **Fully on-device.** No backend endpoint at all — no face image or embedding ever leaves the phone. The original `api/face-embed.ts` design is dropped (see § Technical feasibility for why it would not have worked anyway).
- **Consent is a first-class flow, not a checkbox.** The enrolled person confirms on the phone themselves, and the caregiver can delete them at any time.

It does **not** propose reverting the OCR scam-detection decision. Features 5 and 7 coexist; if the team decides Feature 7 isn't demo-ready or isn't wanted, this branch is simply not merged.

## Problem / target user

Adults 60+ who have trouble putting a name to a face — from ordinary age-related recall lag, to mild cognitive impairment, to the very practical problem of **rotating home-health aides** where three or four different people let themselves in each week. The failure mode is social and emotional, not informational: the wearer knows they *should* know this person, and the moment of not knowing is embarrassing for both sides. Family members report that "who are you?" moments are what make their parent withdraw from visits.

Existing aids (photo boards, name badges, a caregiver whispering a reminder) all require someone else to be present and prepared. Brownmellon's glasses are already on the wearer's face with a camera and a speaker, and the wearer already triggers things by voice — so a private, on-demand "who is this?" fits the product exactly as it exists.

**Who this is not for:** this is a memory *aid* for people who manage their own day. It is not a dementia-care tool and makes no clinical claim (PRD § Non-goals — not a medical device). A wearer who cannot reliably operate the voice trigger is outside the target.

## Goals

- A working "Hey Dojo, who is this?" on real Ray-Ban Meta Gen 2 hardware + iPhone, recognizing 3–5 enrolled people, demoable in a weekend
- Recognition runs **entirely on the phone** — demonstrable with the phone in airplane mode
- Consent, deletion, and the "enrolled people only" boundary are visible product features, not disclaimers — the demo enrolls a consenting teammate live on stage
- Be honest about what it is: matching against a short, consented list; never identification of strangers

## Non-goals

- **Not a general people-identification system.** Never matches against any external database, contact photos, social media, or anyone not explicitly enrolled through the consent flow. This is the load-bearing constraint of the whole feature.
- **Not ambient or continuous.** No "announce whoever walks in." Every recognition is a single still photo taken in response to a voice command (PRD design principle: camera use is episodic). Continuous recognition is exactly the framing that got Meta's Name Tag pulled, and it also exceeds the ~30 min streaming battery ceiling.
- Not logging encounters — no "you last saw Angela on Tuesday." That would be a record about a third party (PRD design principle: no data about anyone but the wearer without their consent).
- Not storing photos. Only mathematical embeddings are kept; the source photos are discarded in memory immediately after embedding.
- Not attempting to recognize the wearer themselves, or to unlock anything, or to verify identity for any transaction.

## Feature requirements

### 7a. Enrollment (caregiver Setup Mode, with the enrollee present)

Lives in the existing **Setup** tab alongside emergency contacts (`Features/Setup/EmergencyContactSetupView.swift` already establishes the caregiver-facing shell), as a new "People to recognize" section.

**Flow:**
1. Caregiver taps "Add a person," enters **name**, **relationship** ("your daughter"), and an optional one-line **memory hook** ("she lives in Boston") — all text the caregiver writes, spoken back verbatim at recognition time.
2. **Consent screen, handed to the enrollee.** Large type, plain language: what will be captured (a few photos of your face, converted to numbers), where it lives (only on this phone, never uploaded), who can hear it (the wearer, spoken aloud), and how to be removed (ask the caregiver, it's one tap). The enrollee — or their legal representative — taps "I agree." The timestamp is stored with the enrollment. Enrollment cannot proceed without this step.
3. **Capture 3 photos** via `GlassesSession.capturePhoto()` (or the phone camera as a fallback for enrollment only — the glasses are worn by the wearer, not the caregiver). Prompt for slight variety: "look at the camera," "turn a little left," "turn a little right." Each photo is gated by Vision's face-capture-quality score; a blurry or badly lit shot is rejected with a spoken/visual "let's try that one again" rather than silently degrading the match later.
4. Each photo → face crop → embedding vector (see § Technical feasibility). The photos are discarded. The person record — name, relationship, memory hook, consent timestamp, 3 embeddings — is saved through `SecureLocalStore` (Keychain, `AfterFirstUnlockThisDeviceOnly`, so it is excluded from iCloud/iTunes backups and never leaves the device).

**Requirements:**
- The caregiver can see the **list of enrolled names** and delete any of them at any time; deletion destroys the embeddings immediately. This refines the original spec's "no UI to view the face store": the list of *who* is enrolled is visible (it has to be, for deletion to be possible), the biometric data itself is never viewable or exportable.
- Enrollment has no network dependency and makes no backend call.
- Maximum of ~10 enrolled people. This is a product cap, not a technical one — it keeps the feature honest about being a short list of close people.
- `NSCameraUsageDescription` in `ios/project.yml` is updated to disclose this use ("…and to recognize family members you've chosen to enroll").

### 7b. Recognition — "Who is this?"

**Trigger:** "Hey Dojo, who is this?" (also accept "who's this," "who is that," "who am I talking to," "do I know this person"). Routed through the existing `WakeWordListener` (`Features/Scheduling/WakeWordDetector.swift`), matched locally by keyword — this command never needs the intent backend, so it works offline.

**Flow:** one still photo via `capturePhoto()` → detect faces on-device → pick the largest face (the person the wearer is facing) → embedding → cosine similarity against every enrolled embedding → spoken result.

**Spoken script** (everything the wearer hears is spoken through an open-ear speaker, so the person being identified may faintly hear it — the phrasing is written to be fine if overheard):

| Situation | Says |
|---|---|
| Confident match | "That's Angela, your daughter." + memory hook if set: "She lives in Boston." |
| No face found in frame | "I don't see anyone's face clearly. Try looking straight at them." |
| Face found, no confident match | "I'm not sure who that is." — never a guess, never a "closest match" |
| Two enrolled people both confident | "I see Angela, your daughter, and Marcus, your nurse." (largest two faces only) |
| Enrolled set is empty | "No one has been added yet. Your helper can add people in the Brownmellon app." |

**Requirements:**
- **Never guesses.** A match is spoken only when the best similarity clears a fixed threshold *and* beats the second-best enrolled person by a margin (so two siblings don't get confused for each other). Everything else is "I'm not sure."
- Zero network calls on the recognition path. This is a verifiable property — demo it in airplane mode.
- End-to-end trigger → speech under ~3 seconds on device. The glasses photo round-trip dominates; on-device detection + embedding is well under a second on the Neural Engine.
- The captured photo is never written to disk and is released after the embedding is computed.
- The wearer can also press an on-screen "Who is this?" button in the app, mirroring how the Vision and Safety features expose a button today — this is the Simulator/demo path and the fallback if the wake-word router isn't extended in time.

## Technical feasibility

### The core finding: the existing backend pattern does not extend to this feature

Every camera feature in v1 (`api/ocr.ts`, `api/scam-check.ts`) is "one photo → one stateless LLM vision call → JSON." It is tempting to add `api/who-is-this.ts` in the same shape and send the enrolled reference photos alongside the new one. **This does not work, and not for a technical reason:**

- **Claude** is deliberately trained not to identify real people from their facial features, and Anthropic's usage policy restricts biometric identification. It will decline the matching step.
- **Gemini** (what the entire backend calls today — all three endpoints run on `gemini-3.6-flash` since `eeaf0fb`) has the same trained refusal for identifying real people in photos, and Google Cloud Vision deliberately ships face *detection* but has never offered face *recognition*.

This is a policy boundary the model providers chose on purpose, and it happens to push the design toward the right answer: the recognition step must be a dedicated face-embedding model, and there is no reason for it to live anywhere but on the phone.

### Options considered

| Approach | How it would work | Privacy story | Weekend feasibility | Verdict |
|---|---|---|---|---|
| **On-device: Apple Vision detection + Core ML face-embedding model** | Vision finds and aligns the face; a small embedding model (MobileFaceNet / ArcFace family, ~4–20 MB) turns it into a 512-d vector; cosine similarity against Keychain-stored vectors | Strongest possible — no face data ever leaves the device; no backend; works offline | Good. Standard mobile-ML pattern; the risk is sourcing/converting the model, not the pipeline | **Recommended** |
| On-device fallback: Vision `VNGenerateImageFeaturePrintRequest` on the aligned face crop | Apple's built-in image-similarity feature print, no third-party model | Same as above | Trivial — Apple frameworks only | **Plan B.** Not a face-recognition model; distinguishes 3–5 people in demo lighting but degrades with pose/lighting. Acceptable only as a de-risk if model integration slips |
| Cloud: AWS Rekognition `CompareFaces` | Send new photo + each enrolled reference photo per query; stateless, no server-side collection | Weak — requires *keeping raw reference photos* on the phone and shipping them to AWS on every query; Amazon's own moratorium on Rekognition for police use is the wrong headline to invite | Easy technically; AWS account setup and IAM adds friction | Rejected |
| Cloud: AWS Rekognition collections (`IndexFaces` / `SearchFacesByImage`) | Faces indexed server-side | Violates PRD "nothing persisted server-side" outright | Easy | Rejected |
| Cloud: Azure Face identification | — | — | Blocked — Limited Access program requires Microsoft approval; not obtainable in a weekend | Rejected |
| Backend LLM vision (Claude / Gemini) `api/who-is-this.ts` | Reuse the ocr/scam-check shape | Moderate | Blocked by provider refusals/policy, see above | Rejected |

### Recommended architecture

```
"Hey Dojo, who is this?"
        │  WakeWordListener (existing) → local keyword match, no backend
        ▼
GlassesSession.capturePhoto()  → UIImage            (existing interface)
        │
        ▼
FaceDetector        Vision: VNDetectFaceRectanglesRequest + VNDetectFaceLandmarksRequest
        │           → largest face bbox + eye landmarks
        ▼
FaceAligner         rotate so eyes are level, crop with margin, resize to model input (112×112)
        │
        ▼
FaceEmbedder        Core ML face-embedding model → [Float] (512-d, L2-normalized)
        │
        ▼
FaceMatcher         cosine similarity vs. every embedding of every EnrolledPerson
        │           threshold + margin over runner-up → .match(person) | .unknown
        ▼
GlassesSession.speak(...)                            (existing interface)
```

Everything above the speak call is pure Swift + Apple frameworks + one bundled model file. No new backend file, no new network client, no new environment variable.

**Data model** (stored via the existing `SecureLocalStore`, one Keychain item under a single key, mirroring how `EmergencyContactSetupViewModel` stores its list):

```swift
struct EnrolledPerson: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var relationship: String          // spoken as "your daughter"
    var memoryHook: String?           // caregiver-written, spoken verbatim
    let consentedAt: Date             // set by the enrollee's own tap, required
    var embeddings: [[Float]]         // 3 × 512, L2-normalized; never photos
}
```

**Matching rule** (starting values, to be tuned on the demo set):
- Cosine similarity ≥ **0.60** against a person's best embedding → candidate
- Candidate must exceed the runner-up person's best score by ≥ **0.10**, else `.unknown`
- With 3 embeddings per person, take the max per person before comparing across people

**Multiple faces:** compute on the largest detected face; if a second face is at least half the size of the first, run it too and speak at most two names. Never more.

**Enrollment quality gate:** `VNDetectFaceCaptureQualityRequest` score below a threshold (start at 0.5) → reject that shot and ask for another. This is the single cheapest thing that improves runtime accuracy.

### Sourcing the embedding model — the one real schedule risk

Ranked by speed to a working build:

1. **Pre-converted Core ML model** (`.mlmodel` / `.mlpackage`) of MobileFaceNet, ArcFace, or FaceNet — several exist publicly. Drop into `ios/Brownmellon/Resources/`; xcodegen/Xcode compiles it automatically. Verify the expected input preprocessing (112×112, RGB vs. BGR, mean/std normalization) against the model card before trusting any similarity numbers. **Budget: 1–2 hours.**
2. **ONNX Runtime for iOS + an InsightFace ONNX model** (e.g. the `buffalo_sc` MobileFaceNet, ~13 MB) via the `onnxruntime-swift-package-manager` SPM package. Skips model conversion entirely. Note `coremltools` no longer converts ONNX directly (dropped in v6) — if converting yourself, go PyTorch → `torch.jit.trace` → `coremltools.convert`, not via ONNX. **Budget: 2–3 hours.**
3. **Vision FeaturePrint fallback** (Plan B above) — Apple-only, zero dependencies, demo-grade. **Budget: under 1 hour**; build this first as a scaffold so the rest of the pipeline is testable while option 1 or 2 is being sorted.

**Licensing note:** InsightFace's pretrained weights are released for **non-commercial research use only**. Fine for a hackathon; must be replaced before anything beyond that. FaceNet-family open implementations are typically MIT.

### Hardware fit

- **Gen 2 camera:** 12 MP ultra-wide. At conversational distance (~1–1.5 m) a face spans roughly 200+ px in the full frame — comfortably enough for a 112×112 embedding input. At 3 m+ it gets marginal; the "look straight at them" retry prompt covers this.
- **Compute:** face detection + embedding on the A-series Neural Engine is tens of milliseconds. The DAT photo round-trip over Bluetooth is the latency that matters and is unmeasured until the real `GlassesSession` lands (PRD § Known risks).
- **Phone state:** per DAT's changelog, camera decoding stops when the phone app is backgrounded. This feature inherits the same open question as every other camera feature and adds nothing new.

### Demo without glasses

`Core/Mocks/MockGlassesSession.swift` already opens the system photo picker for `capturePhoto()` and uses real text-to-speech for `speak()`. Load photos of consenting teammates into the Simulator's photo library and the entire enrollment → recognition loop is demoable on a laptop with no hardware. This is also how the pipeline gets built and tuned before device time, which is scarce (one pair of glasses for the team).

## Legal & ethical guardrails

The research in `.lavish/index.html` covers the legal landscape; the operative points for this build:

- **Biometric-privacy statutes attach at collection, not storage.** Illinois BIPA, Texas CUBI, and Washington's biometric law (and GDPR Art. 9 if this ever leaves the US) regulate *capturing* a face geometry without informed written consent, regardless of how well it's protected afterward. On-device storage is the responsible-storage half of the answer; the enrollee's own consent tap (7a step 2) is the responsible-collection half. **Both are required; neither is optional or "post-hackathon."**
- **Retention:** BIPA requires a written retention/destruction schedule. For the demo, caregiver deletion suffices; a real product needs a written policy (e.g. destroy on caregiver request, or after N months without re-confirmation).
- **Demo rules, non-negotiable:** enroll only people who have personally consented on the device. Never point the feature at judges, audience, or passers-by. Demo the "I'm not sure who that is" response on a non-enrolled teammate *as a feature* — it is the proof that the boundary is real.
- **Pitch framing:** say "we know Meta built and pulled this exact feature in June, and here is specifically how ours is different: enrolled-only, consent-gated, on-device, single-shot." Naming the precedent first is what separates diligence from naivety in front of judges.
- **Bias:** face-embedding models have documented accuracy gaps across skin tone, age, and gender. Test the enrolled demo set for this, keep the threshold conservative, and say so in the demo rather than claiming universal accuracy.
- **The wearer's own dignity:** "I'm not sure who that is" while looking at a spouse is a bad moment. Three enrollment photos, the quality gate, and a conservative-but-not-paranoid threshold exist to make that rare for enrolled people. It will still happen; the phrasing is deliberately soft.

## Build plan (Workstream D — Identity)

Zero overlap with Workstreams A, B, C after the tab-wiring line. All new files:

```
ios/Brownmellon/Features/Identity/
    EnrolledPerson.swift
    FaceDetector.swift            Vision wrapper: largest face + landmarks + capture quality
    FaceAligner.swift
    FaceEmbedder.swift            protocol + CoreMLFaceEmbedder + FeaturePrintFaceEmbedder (Plan B)
    FaceMatcher.swift             threshold/margin logic, pure and unit-testable
    EnrollPersonView.swift        + ViewModel; consent screen is a step inside this flow
    WhoIsThisView.swift           + ViewModel; the on-screen button path
ios/Brownmellon/Resources/<model>.mlpackage
ios/BrownmellonTests/FaceMatcherTests.swift
```

**Touches shared files only for:** one tab (or one Setup-section) in `App/BrownmellonApp.swift`; `NSCameraUsageDescription` in `ios/project.yml`; optionally an SPM package entry if using ONNX Runtime.

**Wake-word routing** ("Hey Dojo, who is this?") requires a small pre-parse hook in `Features/Scheduling/SchedulingCoordinator.swift` so identity phrases are handled locally before `intents.parse` is called — a ~5-line change that belongs to Workstream A and should be coordinated with them. Until then, the on-screen button is the trigger, exactly as it is for the Vision and Safety features today.

| Step | Scope | Estimate |
|---|---|---|
| 0 | `FaceMatcher` with unit tests; `FeaturePrintFaceEmbedder` scaffold so the pipeline runs end to end on Simulator | 1–2 h |
| 1 | Enrollment flow: name/relationship/hook → consent screen → 3 gated captures → Keychain via `SecureLocalStore`; list + delete | 3 h |
| 2 | `WhoIsThisView`: capture → detect → align → embed → match → speak, all five script cases | 2 h |
| 3 | Swap in the real Core ML / ONNX embedding model; tune threshold + margin on 4–5 consenting teammates | 2–3 h |
| 4 | Wake-word hook with Workstream A; real `GlassesSession` when it lands | 1 h + device time |

Steps 0–3 are fully buildable on Simulator with no dependency on the DAT wrapper or on any other workstream.

## Success criteria for the demo

- 4–5 enrolled, consenting teammates recognized correctly in the demo venue's lighting on at least 9 of 10 attempts each
- No false name on a non-enrolled face across at least 20 attempts — "I'm not sure who that is" every time
- Trigger → spoken name in under 3 seconds on device
- Enrollment of a new person completes in under 60 seconds, live, including the consent tap
- Recognition works with the phone in airplane mode

## Risks / open questions

- **Team alignment.** Facial recognition was removed from v1 scope today. This branch should be shown to the team as a proposal before anyone spends a full day on it; the cheap first step (Step 0 + Plan B embedder, ~2 hours) is enough to have a real conversation.
- **Model sourcing** is the only genuinely uncertain engineering item — hence Plan B first, so a slipped model never blocks the demo.
- **DAT camera latency and face size at conversational distance** are unverified until the real `GlassesSession` exists. Same risk the whole product carries.
- **Open-ear speaker leakage.** The identified person may faintly hear their own name. The script is written to be fine if overheard; a "quiet mode" (haptic + large text on the phone) is deferred.
- **Regulatory optics at a hackathon.** Judges may push on "isn't this what Meta got in trouble for?" The answer is prepared above; whoever demos should have it cold.

## Deferred (if this ships at all)

| Item | Why deferred |
|---|---|
| Quiet mode (phone haptic + large-text card instead of speech) | Wearer would need to look at the phone; validate the spoken path first |
| Re-confirmation / expiry of enrollments | Needed for a real retention policy; not needed to prove the concept |
| Recognizing more than two people in frame | Group settings are exactly where announcing names aloud stops being appropriate |
| Voice-based recognition ("that voice is Angela") | Would need recording other people's speech — reopens the all-party-consent problem noted in `PRD.md` deferred list |
| Any form of continuous or passive recognition | Never. Battery, privacy, and the Meta precedent all point the same way |
