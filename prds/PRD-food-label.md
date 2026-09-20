# Feature 10 — Food Label Reader with Diet Check ("Can I eat this?")

**Status:** v2 feature, own workstream. Depends on [`PRD-foundation-v2.md`](PRD-foundation-v2.md) (handler hook, `UploadImage`, Setup menu, camera usage string).

**One line:** the wearer holds up a package and asks either "read this label" (the tiny print, read aloud in a sensible order) or "can I eat this?" (the same label, checked against the diet their caregiver set up — low sodium, diabetes carb budget, allergies, ingredients to avoid). One photo, one backend call, two spoken modes, and follow-ups ("read the ingredients") without another photo.

This is the two features from the brainstorm ("read tiny text" and "dietary restrictions") built as one pipeline with two mouths, which is what they are.

## Brief for the implementing agent

Read first: [`../README.md`](../README.md), [`../PRD.md`](../PRD.md) § Feature 4 and § Feature 5 (the pattern you're specializing) and § Design principles, [`PRD-foundation-v2.md`](PRD-foundation-v2.md) § 1, 2, 3, 4, 6, 7, `ios/Brownmellon/Core/VoiceAssistant.swift` (handler registration) and `ios/Brownmellon/Core/Mocks/MockGlassesSession.swift` (`stubbedPhoto` for tests), `backend/api/scam-check.ts` (copy its structure exactly for the new endpoint — retry helper, plain-text-then-parse JSON, `FALLBACK`), `ios/Brownmellon/Features/Safety/ScamCheckBackendClient.swift` and `AdScamCheckViewModel.swift` (client + view-model shape to copy), `ios/Brownmellon/Features/Vision/ReadToMeViewModel.swift` (what "read this to me" does today — you don't change it), `ios/Brownmellon/Features/Setup/EmergencyContactSetupView*.swift` (caregiver Setup pattern).

Own: `ios/Brownmellon/Features/Nutrition/**`, `ios/BrownmellonTests/Nutrition/**`, `backend/api/food-label.ts`, `backend/lib/foodLabel*.ts` and `backend/tests/foodLabel*.test.ts` if you split pure logic out for testing, plus the single wiring lines in `App/BrownmellonApp.swift` (foundation § 7) and one `NavigationLink` in `Features/Setup/SetupHomeView.swift`. Reuses `GEMINI_API_KEY` — nothing to add to `.env.example`. There is no local API key: verify the endpoint with `npx tsc --noEmit` and `node --test` on the pure response-normalization logic; live behavior is checked after merge to `main` deploys it.

Verify: `cd ios && xcodegen generate && xcodebuild ... test` (README § iOS app); `cd backend && npx tsc --noEmit`. Zero warnings.

## What exists already, and what this adds

Feature 4 ("Read this to me") is implemented as a button-triggered scaffold: `ReadToMeViewModel.readThisToMe()` → `api/ocr` mode `read` → Gemini transcribes *all* visible text → spoken verbatim. It's fine for a letter. For a food package it fails the wearer three ways: it reads a Nutrition Facts panel as a 90-second wall of numbers, it has no idea what any of it means for *this* person, and there's no way to ask a follow-up without taking another photo. It stays as-is for letters, menus and mail. This feature owns packaged food.

## Problem / target user

Two pain points that show up together at the kitchen counter and in the grocery aisle:

- **The print is too small.** Ingredient lists and Nutrition Facts panels are 6–8 pt on a curved, glossy surface. Low vision (presbyopia, cataracts, macular degeneration) is near-universal in this age group; readers get left in another room.
- **The numbers only matter relative to a diet they've been told to follow.** A large share of adults over 65 are managing hypertension or heart failure (low sodium), type 2 diabetes (carbohydrates and added sugars), chronic kidney disease (potassium, phosphorus), high cholesterol (saturated fat), plus allergies, celiac, and drug–food interactions ("no grapefruit" on statins, watch vitamin K on warfarin). Even someone who *can* read "890 mg" has to remember what their limit is and do the arithmetic against a serving size that isn't the whole can.

The caregiver knows the diet. The wearer holds the can. This feature connects the two.

**Not for:** unpackaged food, restaurant menus, or anything without a label — the app would be guessing. And it is **not medical advice**: it compares label numbers to limits a person entered, and says so.

## Goals

- "Read this label" speaks a food label in an order that makes sense to listen to — headline facts first, detail on request
- "Can I eat this?" gives a clear fit verdict against the caregiver's diet profile, with the one or two reasons that matter, per serving, and flags when the container is more than one serving
- The diet profile never leaves the phone — the backend sees only the photo, the rules run on-device
- Follow-ups ("read the ingredients," "how much sugar") reuse the last label for 5 minutes without a new photo
- Legible-or-nothing: a number the model can't read is reported as unreadable, never guessed

## Non-goals

- Not nutrition advice or meal planning; no "you should eat…"; no calorie counting or daily totals in v1
- Not barcode lookup in v1 (see § Deferred — it's the right Phase 2)
- Not unpackaged food, menus, or supplements/medication labels (medication is its own liability pass — `PRD.md` deferred list)
- Not changing Feature 4's behavior

## Feature requirements

### 10a. Caregiver Setup — Diet profile

`Features/Nutrition/DietSetupView.swift`, reached from `SetupHomeView` ("Diet"). Each restriction is a toggle with an editable number where relevant, defaults pre-filled from standard guidance so a caregiver can just flip the switch:

| Restriction | Editable limit (default) | What it checks |
|---|---|---|
| Low sodium | daily limit, mg (1500) | sodium per serving vs. daily limit |
| Diabetes / carb-aware | carbs per meal, g (45) | total carbs and added sugars per serving |
| Low saturated fat | daily limit, g (13) | saturated fat per serving; trans fat > 0 always flagged |
| Low potassium (kidney) | daily limit, mg (2000) | potassium per serving; also `phosphate` in ingredients |
| Gluten-free | — | ingredient keywords (wheat, barley, rye, malt, spelt, semolina, durum, farro, triticale, brewer's yeast); a "gluten-free" claim on the label overrides |
| Allergies | pick from the FDA nine: milk, eggs, fish, shellfish, tree nuts, peanuts, wheat, soybeans, sesame | "Contains:" statement first, then ingredient keywords |
| Ingredients to avoid | free-text list (e.g. `grapefruit`, `alcohol`, `aspartame`, `spinach`) | substring match on ingredients and product name |

Footer copy, plain language: "Brownmellon compares the numbers on a food label to the limits you enter here. It is not medical advice — set these from what the doctor recommended." Persist `DietaryProfile` via `SecureLocalStore` under key `dietaryProfile`. The profile is health-adjacent personal data: it is stored on-device only and **never included in any network request**.

### 10b. Capture and extraction (shared by both modes)

**Claimed commands** (normalized) — all route to one capture:

- Read mode: `read this label`, `read the label`, `read this package`, `what's in this`, `whats in this`, `read the ingredients`, `read the nutrition`, `read everything on this`
- Check mode: `can i eat this`, `can i have this`, `is this okay for me`, `is this ok for me`, `is this good for me`, `check this food`, `is this safe for me to eat`, `does this fit my diet`
- Question mode: `how much sodium`, `how much salt`, `how much sugar`, `how many carbs`, `how much fat`, `does this have <allergen or avoid-word>`, `is there <x> in this`, `when does this expire`, `how do i cook this`, `how do i make this`

Must **not** claim `read this to me` / `read this` alone (Feature 4) or `check this ad` (Feature 5).

**Flow:** `capturePhoto()` → `UIImage.uploadJPEGData()` → `POST api/food-label` → `FoodLabelResult` → cached as `lastLabel` with timestamp → speak per mode. If a follow-up command arrives within **5 minutes** of `lastLabel` and is a question or read-mode command, **skip the photo** and answer from the cache; say "From the label I just read:" so the wearer knows no new photo was taken. Check-mode always re-photographs unless the previous command was also on this label within 60 s.

**Backend `api/food-label.ts`** (Gemini, `gemini-3.6-flash`, copy `scam-check.ts` verbatim for transport, retry, fence-stripping and fallback). Request `{ imageBase64 }`. Response:

```ts
interface FoodLabelResult {
  found: boolean;                 // a food label (Nutrition Facts and/or ingredients) is visible
  productName: string | null;
  servingSize: string | null;     // as printed, e.g. "1 cup (245g)"
  servingsPerContainer: number | null;
  nutrients: {                    // PER SERVING, from the per-serving column if there are two; null when not legible
    calories: number | null;
    totalFatG: number | null; saturatedFatG: number | null; transFatG: number | null;
    cholesterolMg: number | null; sodiumMg: number | null;
    totalCarbohydrateG: number | null; dietaryFiberG: number | null;
    totalSugarsG: number | null; addedSugarsG: number | null;
    proteinG: number | null; potassiumMg: number | null; phosphorusMg: number | null;
  };
  ingredients: string[];          // split on commas at the top level; sub-ingredients kept inside their parentheses
  containsStatement: string | null;   // "Contains: wheat, milk, soy" as printed
  mayContainStatement: string | null;
  claims: string[];               // "gluten-free", "low sodium", "no added sugar"… as printed on the package
  preparation: string | null;     // cooking/heating instructions if visible
  expiration: string | null;      // best-by / use-by text as printed
  fullText: string;               // everything legible, in reading order, for "read everything"
}
```

Prompt essentials (write them, don't paraphrase weakly): this is a photo of a packaged food for an adult over 60 who cannot read small print and may be on a restricted diet; transcribe numbers **exactly** and use `null` for anything not clearly legible — a wrong sodium number is worse than a missing one; use the per-serving column when a label has per-serving and per-container columns; keep units as printed (mg vs g); `found` is `false` for anything that isn't a food label; respond with only the JSON, no fences. `FALLBACK` is `found: false` with empty fields.

### 10c. Read mode — the tiny print, in listening order

Never speak `fullText` first. Order:

1. "This is *Campbell's Chicken Noodle Soup*. One serving is one cup, and the can has about two and a half servings."
2. "Per serving: 60 calories, 890 milligrams of sodium, 8 grams of carbohydrates with 1 gram of sugar, 2 grams of fat, 3 grams of protein." (only the fields that are non-null; round to whole numbers; say units in words)
3. "It contains wheat, chicken, and soy." (from `containsStatement`, else the first five ingredients)
4. "Say 'read the ingredients' for the full list, or 'read everything' for the whole label."

`read the ingredients` → the full `ingredients` list, joined with commas, in ≤ 2 chunks with "…and…" between them. `read everything` → `fullText`. `when does this expire` → `expiration` or "I couldn't find a date on this side of the package." `how do i cook this` → `preparation` or the same kind of miss.

### 10d. Check mode — fit against the profile

`DietaryFitEvaluator` (pure Swift, on-device, unit-tested) takes `(DietaryProfile, FoodLabelResult)` and returns:

```swift
struct FitAssessment: Equatable {
    enum Verdict { case fits, caution, doesNotFit, unknown, noProfile, notALabel }
    let verdict: Verdict
    let findings: [Finding]        // ordered most severe first
    let servingsPerContainer: Double?
}
struct Finding: Equatable {
    enum Severity { case high, moderate, info, unreadable }
    let severity: Severity
    let spoken: String             // one clause, already phrased for speech
}
```

Rules — per serving, against the wearer's own limits (not the FDA's generic Daily Values):

| Restriction | high (→ doesNotFit) | moderate (→ caution) | unreadable (→ unknown if nothing else decides) |
|---|---|---|---|
| Low sodium | sodium ≥ 20% of daily limit | 10–20% | `sodiumMg == nil` |
| Carb-aware | total carbs > per-meal target **or** added sugars ≥ 15 g | carbs > 50% of target, or added sugars 8–15 g | `totalCarbohydrateG == nil` |
| Low saturated fat | sat fat ≥ 20% of daily limit **or** trans fat > 0 | 10–20% | `saturatedFatG == nil` |
| Low potassium | potassium ≥ 15% of daily limit, or `phosphate` in ingredients | 8–15% | potassium `nil` → info: "the label doesn't list potassium" |
| Gluten-free | any gluten keyword unless a gluten-free claim is present | — | no ingredients read → unreadable |
| Allergy | allergen in `containsStatement` or ingredient keywords | allergen only in `mayContainStatement` | no ingredients read → unreadable |
| Avoid list | any match in ingredients or product name | — | no ingredients read → unreadable |

Aggregate: any high → `doesNotFit`; else any moderate → `caution`; else if every active restriction could be evaluated → `fits`; else `unknown`. Empty profile → `noProfile`. `found == false` → `notALabel`.

**Spoken script** (product → the top one or two findings → verdict → serving note → offer):

| Verdict | Example |
|---|---|
| doesNotFit | "This is Campbell's Chicken Noodle Soup. One serving has 890 milligrams of sodium — that's more than half of your daily limit, so it doesn't fit your low-sodium diet. It also contains wheat, which you avoid. And the can is about two and a half servings." |
| caution | "This is Cheerios. One serving has 190 milligrams of sodium, about an eighth of your daily limit, and 22 grams of carbohydrates, about half your meal budget. It's a moderate fit for your diet." |
| fits | "This is Del Monte No Salt Added Green Beans. It fits your diet — 10 milligrams of sodium per serving, and none of the ingredients you avoid." |
| unknown | "I could read most of this label, but the sodium wasn't legible. Try a closer photo of the Nutrition Facts panel." |
| noProfile | "No diet has been set up yet, so I can't check this for you — your helper can add one in Setup. Here's the label:" then read mode step 2 |
| notALabel | "I don't see a nutrition label. Hold the Nutrition Facts panel or the ingredients list in front of you." |

Rules for the script: at most two findings spoken (say "and one more thing to watch" if there are more, available via `what else`); fractions in words ("about a third of your daily limit") rather than percentages; always "per serving"; mention servings per container whenever it's ≥ 1.5; never say "safe," "healthy," "you should," or "don't eat" — the vocabulary is *fits / moderate fit / doesn't fit your diet*.

**Question mode** answers from `nutrients` directly: "890 milligrams of sodium per serving" — and, if the relevant restriction is active, appends the comparison clause ("that's more than half of your daily limit").

### 10e. Phone UI (secondary)

`FoodLabelView` on a "Check Food" tab (`carrot` glyph): a button per mode for Simulator use, the last spoken text, and a collapsible dump of the parsed `FoodLabelResult` for debugging. Product is the voice path.

## Technical design

### Why extraction is remote and judgment is local

The vision model is excellent at reading a curved, glossy, 7-pt panel and terrible as a source of truth for "is this okay for a person with heart failure." Splitting the two gives: a deterministic, unit-testable rules engine; a profile that is health data and stays on the phone; and consistent phrasing regardless of model mood. The backend gets a photo and returns numbers. That's all.

### Image quality — the tiny-text problem specifically

- `uploadJPEGData(maxDimension: 2048)` from the foundation is the default. For labels, text legibility matters more than for a letter: if extraction returns `found: true` but ≥ 3 of the nutrients the active profile needs are `nil`, retry **once** with `maxDimension: 3000` (still under the body limit at quality 0.8 for a typical label photo) before reporting unreadable.
- The glasses camera is ultra-wide; a label at arm's length is a small region of the frame. Say "hold it closer, about a foot from your face" in the `notALabel` / `unknown` prompts — the wearer can't see the framing.
- Offline fallback (Phase 2, not v1): Vision `VNRecognizeTextRequest` (`.accurate`) on-device produces the verbatim text for read mode without a backend, but parsing a Nutrition Facts panel from OCR lines into fields is brittle — keep Gemini as the extractor.

### Files

```
ios/Brownmellon/Features/Nutrition/
    DietaryProfile.swift            Codable; the seven restrictions with limits; Allergen enum (FDA nine)
    FoodLabelResult.swift           Codable mirror of the backend shape
    FoodLabelBackendClient.swift    POST api/food-label; copy ScamCheckBackendClient
    DietaryFitEvaluator.swift       pure rules → FitAssessment
    IngredientMatcher.swift         keyword tables: gluten, each allergen, phosphate; case/diacritic-insensitive; "may contain" handling
    FoodLabelSpeech.swift           read-mode ordering, check-mode script, question answers, number → words ("890 milligrams")
    FoodLabelCommandParser.swift    pure; claimed phrases → enum { read(kind), check, question(kind) }
    FoodLabelViewModel.swift        VoiceCommandHandler + ObservableObject; capture, cache (5 min), retry-at-3000, speech
    FoodLabelView.swift
    DietSetupView.swift + DietSetupViewModel.swift
ios/BrownmellonTests/Nutrition/
    DietaryFitEvaluatorTests.swift  one test per table cell above, plus aggregation, plus "gluten-free claim overrides keyword"
    IngredientMatcherTests.swift    "whey" → milk; "Contains: tree nuts (almonds)"; "may contain peanuts" → moderate; diacritics
    FoodLabelSpeechTests.swift      each verdict script with fixed fixtures; fractions in words; ≤ 2 findings; servings ≥ 1.5 mentioned
    FoodLabelCommandParserTests.swift  every claimed phrase; must NOT claim "read this to me", "check this ad"
    Fixtures/*.json                 4–5 hand-written FoodLabelResult fixtures (soup, cereal, no-salt beans, unreadable, not-a-label)
backend/api/food-label.ts
```

Wiring in `BrownmellonApp`: `private let foodLabel = FoodLabelViewModel(glasses:, store:)`; the `VoiceAssistant` `handlers:` includes it (foundation § 7); tab "Check Food"; `SetupHomeView` link "Diet".

**Voice-path tests (required):** the backend client must sit behind a protocol so tests inject a stub returning a fixture `FoodLabelResult`. Build a `VoiceAssistant` with `MockGlassesSession` (`stubbedPhoto` set to any `UIImage`), `MockSecureLocalStore` holding a low-sodium + peanut-allergy profile, and the view model as a handler; drive with `simulateTranscript`:
- `"hey dojo can i eat this"` with the soup fixture → `onSpeak` receives the doesNotFit script (assert it contains "doesn't fit your low-sodium diet" and "two and a half servings").
- `"hey dojo read the ingredients"` immediately after → no second `capturePhoto` (count calls on the mock or stub) and the ingredients are spoken.
- `"hey dojo read this to me"` → handler returns `false` (Feature 4 keeps it).
These prove the feature is voice-driven end to end, minus ASR.

### Simulator / demo

Photo picker → any clear photo of a Nutrition Facts panel (take 3–4 with a phone in a grocery store beforehand: a high-sodium soup, a cereal, a no-salt-added vegetable, a bag of nuts). Set up a profile with low sodium + a peanut allergy. Demo beat: "Hey Dojo, can I eat this?" on the soup → doesn't fit; on the green beans → fits; then "read the ingredients" with no new photo.

## Success criteria

- Every rules-table cell has a passing unit test; the evaluator has no dependency on UIKit or networking
- On the 4 grocery fixtures photographed with a phone: `found` true and sodium, carbs, sat fat, ingredients extracted correctly on all 4 (verify by eye against the physical label); no numeric hallucination in 10 repeated calls per photo
- Check mode spoken result ≤ 25 seconds of speech; read mode headline ≤ 20 seconds before the offer
- A follow-up "read the ingredients" within 5 minutes triggers no photo and no backend call
- `grep -r "dietaryProfile\|DietaryProfile" backend/` returns nothing — the profile never crosses the wire

## Risks / open questions

- **Numeric hallucination** is the failure mode that matters: the prompt's "null over guess" instruction plus the fixture check above are the guard; consider asking the model to also return `sodiumMg` as it appears in text (e.g. `"890mg"`) and cross-check the parse.
- **Serving-size reality** — older adults often eat the whole container; the "about two and a half servings" clause is the honest mitigation without doing math the wearer didn't ask for.
- **Curved cans and glare** — expect misses; the closer-photo retry prompt is the UX. Test with real cans, not flat boxes.
- **Liability framing** — the vocabulary rules in 10d exist for a reason; a reviewer should grep the speech code for "safe", "healthy", "should".
- **Non-US labels** (kJ, salt vs sodium, per-100 g columns) — out of scope; `found` may still be true and numbers wrong. Note it in the Setup footer.

## Deferred

| Item | Why |
|---|---|
| **Barcode lookup** via Vision `VNDetectBarcodesRequest` (EAN-13/UPC) → Open Food Facts (`/api/v2/product/{barcode}`, free, no key, set a User-Agent) | The right Phase 2: barcodes are large and high-contrast where the print is tiny, coverage of US products is decent, and it gives a second source to cross-check the photo. Not v1 because it adds a third-party dependency and a network path that bypasses the extractor. |
| Daily running totals ("you're at 1,200 mg of sodium today") | Needs the wearer to say what they actually ate; pairs with Feature 9's memory notes later |
| Restaurant menus | No label → estimates → guessing; revisit with explicit "this is an estimate" framing |
| Medication labels | Own liability pass (`PRD.md` deferred list) |
| Offline verbatim read via Vision OCR | Useful resilience once the primary path is proven |
