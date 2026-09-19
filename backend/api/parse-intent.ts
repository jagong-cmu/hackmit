import type { VercelRequest, VercelResponse } from "@vercel/node";
import { GoogleGenAI } from "@google/genai";
import { z } from "zod";

// Workstream A's backend endpoint (features 1–2). Same Gemini + retry pattern
// as ocr.ts and scam-check.ts so the whole backend runs on one API key.
// Stateless: the phone sends the current time + zone with every request,
// because "tomorrow at two" is meaningless without them.

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
  intent: z.enum(["create_event", "daily_briefing", "unknown"]),
  title: z.string().nullable(),
  /** ISO 8601 with offset. */
  start: z.string().nullable(),
  end: z.string().nullable(),
  /** Spoken aloud when intent is "unknown" — keep it short and kind. */
  reason: z.string().nullable(),
});
type Intent = z.infer<typeof IntentSchema>;

const SYSTEM = `You turn one spoken command from an adult over 60 into a calendar action.

Return exactly one intent:
- "create_event" — they want something put on the calendar (a reminder, an appointment, a task at a time).
- "daily_briefing" — they are asking what is on their schedule today.
- "unknown" — anything else, or a calendar request too vague to act on.

Rules:
- Resolve every relative date against the supplied current time and time zone. "Tomorrow at two" with no am/pm means the daytime reading (14:00), not 02:00.
- Return start and end as ISO 8601 with a UTC offset. Leave end null unless a duration or end time was actually spoken.
- The title is what the wearer will hear read back, so keep their own words: "Doctor Reyes" not "Appointment with Doctor Reyes".
- The transcript comes from speech recognition and may be garbled. If you cannot tell what they want, return "unknown" — never guess a time. A wrong appointment is worse than a re-ask.
- For "unknown", write reason as one short spoken sentence asking for what is missing, e.g. "What time should I set it for?". Leave it null for the other intents.

Respond with ONLY a JSON object, no markdown fences, no commentary, matching exactly this shape:
{"intent": "create_event" | "daily_briefing" | "unknown", "title": string | null, "start": string | null, "end": string | null, "reason": string | null}`;

/** Spoken back verbatim, so it has to sound like a sentence. */
const FALLBACK: Intent = {
  intent: "unknown",
  title: null,
  start: null,
  end: null,
  reason: "I'm having trouble right now. Please try again.",
};

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
    return json(FALLBACK, 502);
  }
}
