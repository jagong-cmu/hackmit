import type { VercelRequest, VercelResponse } from "@vercel/node";
import { GoogleGenAI } from "@google/genai";
import { z } from "zod";

// The voice-command parser. Same Gemini + retry pattern as ocr.ts and
// scam-check.ts so the whole backend runs on one API key. Stateless: the
// phone sends the current time + zone with every request, because "tomorrow
// at two" is meaningless without them.
//
// Scope: features 1–2 (calendar) are the reason this endpoint exists — they
// need a model to pull a date and time out of speech. Features 3–6 (scan /
// read / check ad / call) are recognized on the phone first, offline, by
// VoiceCommandClassifier.swift; the model returns those intents only as a
// fallback for paraphrases the phone's list misses ("what does this letter
// say"), so the phone can still route them without a re-ask.

const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
const MODEL = "gemini-3.6-flash";

/** What the phone sends us. */
const RequestSchema = z.object({
  command: z.string().min(1).max(500),
  /** ISO 8601 with offset. */
  now: z.string(),
  /** IANA identifier, e.g. "America/New_York". */
  timeZone: z.string(),
});

/** What we send back. Mirrors `VoiceIntent` in IntentClient.swift. */
const IntentSchema = z.object({
  intent: z.enum([
    "create_event",
    "daily_briefing",
    "scan_card",
    "read_text",
    "check_ad",
    "call_contact",
    "call_emergency",
    "unknown",
  ]),
  title: z.string().nullable(),
  /** ISO 8601 with offset. */
  start: z.string().nullable(),
  end: z.string().nullable(),
  /** Who to call, as the wearer said it ("daughter"), for "call_contact" only. */
  contact: z.string().nullable().default(null),
  /** Spoken aloud when intent is "unknown" — keep it short and kind. */
  reason: z.string().nullable(),
});
type Intent = z.infer<typeof IntentSchema>;

const SYSTEM = `You turn one spoken command from an adult over 60, wearing camera glasses with a speaker and no screen, into exactly one intent.

Calendar intents:
- "create_event" — they want something put on the calendar (a reminder, an appointment, a task at a time).
- "daily_briefing" — they are asking what is on their schedule today.

Camera intents (the glasses take one photo of what they are looking at):
- "scan_card" — they are holding an appointment card, letter, or notice and want the appointment on their calendar ("put this on my calendar", "when is this appointment").
- "read_text" — they want the text in front of them read aloud ("what does this letter say", "what's the dosage on this bottle").
- "check_ad" — they want to know whether an advertisement, offer, or message in front of them is trustworthy ("is this offer for real", "does this look like a scam").

Call intents:
- "call_contact" — they want to phone someone described by relation or name ("get my daughter on the phone"). Put the relation or name they used, lowercase, in "contact".
- "call_emergency" — they need emergency services (911, police, ambulance, "I need help now").

- "unknown" — anything else, or a request too vague to act on.

Rules:
- Resolve every relative date against the supplied current time and time zone. "Tomorrow at two" with no am/pm means the daytime reading (14:00), not 02:00.
- Return start and end as ISO 8601 with a UTC offset. Leave end null unless a duration or end time was actually spoken. Both are null for non-calendar intents.
- The title is what the wearer will hear read back, so keep their own words: "Doctor Reyes" not "Appointment with Doctor Reyes". Null for non-calendar intents.
- "contact" is null for every intent except "call_contact".
- The transcript comes from speech recognition and may be garbled. If you cannot tell what they want, return "unknown" — never guess a time or a person. A wrong appointment or a wrong phone call is worse than a re-ask.
- For "unknown", write reason as one short spoken sentence asking for what is missing, e.g. "What time should I set it for?". Leave it null for the other intents.

Respond with ONLY a JSON object, no markdown fences, no commentary, matching exactly this shape:
{"intent": "create_event" | "daily_briefing" | "scan_card" | "read_text" | "check_ad" | "call_contact" | "call_emergency" | "unknown", "title": string | null, "start": string | null, "end": string | null, "contact": string | null, "reason": string | null}`;

/** Spoken back verbatim, so it has to sound like a sentence. */
const FALLBACK: Intent = {
  intent: "unknown",
  title: null,
  start: null,
  end: null,
  contact: null,
  reason: "I'm having trouble right now. Please try again.",
};

const QUOTA_FALLBACK: Intent = {
  ...FALLBACK,
  reason: "I've hit my daily limit for understanding requests. Please try again later.",
};

const NO_INTENT: Intent = { intent: "unknown", title: null, start: null, end: null, contact: null, reason: null };

// The briefing question has a handful of phrasings and nothing to extract —
// answering it locally is faster, never hits the model quota, and still works
// when Gemini is down. Everything with a date/time still goes to the model.
const BRIEFING_PATTERNS = [
  /\bwhat('s| is| do i have| have i got)?\s*(on\s+)?(my\s+)?(schedule|calendar|agenda|day|plans?)\b.*\btoday\b/,
  /\bwhat do i have\s+(today|on today)\b/,
  /\b(today'?s|my)\s+(schedule|calendar|agenda|appointments?|plans?)\b/,
  /\banything\s+(on\s+)?(today|my calendar|my schedule)\b/,
  /\bwhat('s| is)\s+(happening|going on|up)\s+today\b/,
];

function localIntent(command: string): Intent | null {
  const text = command.toLowerCase().replace(/[^a-z0-9' ]+/g, " ").replace(/\s+/g, " ").trim();
  if (BRIEFING_PATTERNS.some((re) => re.test(text))) {
    return { ...NO_INTENT, intent: "daily_briefing" };
  }
  return null;
}

function isQuotaError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /429|RESOURCE_EXHAUSTED|quota/i.test(message);
}

// gemini-3.6-flash intermittently 503s with "high demand" (observed live from
// ocr.ts) — short retry with backoff instead of surfacing it to the wearer.
async function generateWithRetry(
  params: Parameters<typeof ai.models.generateContent>[0],
  attempts = 3,
): Promise<Awaited<ReturnType<typeof ai.models.generateContent>>> {
  for (let i = 0; i < attempts; i++) {
    try {
      return await ai.models.generateContent(params);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const isTransient = /503|UNAVAILABLE|high demand/i.test(message);
      if (!isTransient || i === attempts - 1) throw err;
      await new Promise((resolve) => setTimeout(resolve, 300 * (i + 1)));
    }
  }
  throw new Error("unreachable");
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  const json = (body: unknown, status = 200) => res.status(status).json(body);

  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const parsedBody = RequestSchema.safeParse(req.body ?? null);
  if (!parsedBody.success) {
    return json({ error: "bad_request", detail: parsedBody.error.message }, 400);
  }
  const { command, now, timeZone } = parsedBody.data;

  const local = localIntent(command);
  if (local) {
    return json(local);
  }

  try {
    const response = await generateWithRetry({
      model: MODEL,
      contents: [{ text: `${SYSTEM}\n\nCurrent time: ${now}\nTime zone: ${timeZone}\n\nCommand: "${command}"` }],
    });

    const raw = (response.text ?? "").trim().replace(/^```(?:json)?/i, "").replace(/```$/, "").trim();
    let candidate: unknown;
    try {
      candidate = JSON.parse(raw || "{}");
    } catch {
      return json(FALLBACK);
    }

    // The model's output is validated against the same schema the phone
    // decodes — anything malformed becomes the spoken fallback, never a crash.
    const parsed = IntentSchema.safeParse(candidate);
    if (!parsed.success) {
      console.error("parse-intent: model output failed schema", parsed.error.message, raw);
      return json(FALLBACK);
    }
    return json(parsed.data);
  } catch (error) {
    console.error("parse-intent failed:", error);
    // A quota wall is a 200 with a spoken reason, not a 502: the phone treats
    // non-2xx as "something went wrong", and the wearer should hear *why*.
    if (isQuotaError(error)) {
      return json(QUOTA_FALLBACK);
    }
    return json(FALLBACK, 502);
  }
}
