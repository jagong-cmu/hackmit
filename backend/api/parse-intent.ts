import type { VercelRequest, VercelResponse } from "@vercel/node";
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod";

// Constructed lazily: `new Anthropic()` throws if ANTHROPIC_API_KEY is
// unset, and doing that at module load would take the whole function down
// with an opaque 500 instead of the spoken FALLBACK the phone expects.
let client: Anthropic | undefined;
function anthropic(): Anthropic {
  return (client ??= new Anthropic());
}

/** What the phone sends us. */
const RequestSchema = z.object({
  command: z.string().min(1).max(500),
  /** ISO 8601 with offset — "tomorrow at two" is meaningless without it. */
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
- For "unknown", write reason as one short spoken sentence asking for what is missing, e.g. "What time should I set it for?". Leave it null for the other intents.`;

/** Spoken back verbatim, so it has to sound like a sentence. */
const FALLBACK = {
  intent: "unknown" as const,
  title: null,
  start: null,
  end: null,
  reason: "I'm having trouble right now. Please try again.",
};

// Node runtime (VercelRequest/VercelResponse), same as ocr.ts and
// scam-check.ts — not the Web Request/Response API, which this project's
// runtime doesn't hand to handlers (req.json() doesn't exist on it).
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
    const response = await anthropic().messages.parse({
      model: "claude-opus-5",
      max_tokens: 4096,
      system: SYSTEM,
      output_config: {
        format: zodOutputFormat(IntentSchema),
        // This is a short parse on a voice path where latency is the whole
        // experience — low effort keeps the round trip tight.
        effort: "low",
      },
      messages: [
        {
          role: "user",
          content: `Current time: ${now}\nTime zone: ${timeZone}\n\nCommand: "${command}"`,
        },
      ],
    });

    if (response.stop_reason === "refusal") {
      return json(FALLBACK);
    }

    // parsed_output is null when the model's output failed schema validation.
    return json(response.parsed_output ?? FALLBACK);
  } catch (error) {
    if (error instanceof Anthropic.RateLimitError) {
      return json(FALLBACK, 429);
    }
    if (error instanceof Anthropic.APIError) {
      console.error(`Claude API error ${error.status}:`, error.message);
      return json(FALLBACK, 502);
    }
    console.error("parse-intent failed:", error);
    return json(FALLBACK, 500);
  }
}
