# Workstream A — Voice & Calendar

Feature 1 (voice scheduling/reminders) and feature 2 (daily briefing).

## Wake word

`"Hey Dojo"` — canonical spelling in `WakeWordDetector.phrase`.

Matching is deliberately fuzzy. "Dojo" is a proper noun the recognizer has no
language-model prior for, so it comes back as "dodo", "doe joe", "dough joe".
`WakeWordDetector` accepts a list of known confusions plus edit distance 1.

Drive it through `WakeWordListener`, never the detector directly: streaming
recognition resends the same utterance as a growing partial transcript, and
without the cooldown one spoken sentence books several appointments.

Workstreams B and C should route their own triggers through `WakeWordListener`
too — it is shared trigger infrastructure, not scheduling-specific.

## Wiring

```swift
let coordinator = SchedulingCoordinator(
    glasses: MockGlassesSession(),        // swap for the real DAT wrapper
    calendar: MockCalendarService(),      // swap for GoogleCalendarService
    intents: IntentClient(endpoint: URL(string: "https://<app>.vercel.app/api/parse-intent")!)
)
coordinator.start()
```

`GoogleCalendarService` takes an `accessToken` closure rather than owning OAuth,
so the calendar calls are testable without standing up Google Sign-In, and
whoever wires up auth does not have to touch this file.

## Backend

`api/parse-intent.ts` — one stateless Vercel function. Takes the command plus
the phone's current time and time zone (the backend keeps no state, and
"tomorrow at two" is meaningless without them), returns a structured intent
validated against a Zod schema.

```bash
npm install
npx tsc --noEmit
```

Needs `ANTHROPIC_API_KEY` — see `.env.example`.

## Tests

`Tests/SchedulingTests/WakeWordDetectorTests.swift` covers clean transcripts,
known misrecognitions, false-trigger cases, and the streaming debounce. It
assumes an app module named `Brownmellon`; adjust the `@testable import` when
the Xcode project exists.
