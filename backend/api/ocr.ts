import type { VercelRequest, VercelResponse } from '@vercel/node';
import { GoogleGenAI } from '@google/genai';

// Workstream B's backend endpoint (PRD.md § Parallel workstreams).
// Stateless by design: the photo is sent for one inference call and is
// never persisted here or anywhere server-side — only the structured
// result goes back to the phone, which stores it locally (PRD § AI backend).
//
// Uses the Gemini API (not Claude) — the PRD's original "AI backend"
// section says Claude direct, project-wide. This endpoint was switched
// to Gemini at the user's request; flag/reconcile with the PRD if the
// intent is to standardize on Gemini everywhere, or leave as a
// per-workstream choice if intentional.
//
// extractAppointment deliberately does NOT use responseSchema/JSON mode:
// tested live against the deployed endpoint and it 503'd 3/3 times
// ("high demand") on the schema-constrained path specifically, while
// plain-text generation on the same model succeeded every time in the
// same window — looks like gemini-3.6-flash's structured-output path has
// separate (currently tighter) capacity from plain generation. Asking
// for JSON in the prompt and parsing it manually sidesteps that.

// Constructed lazily, matching api/parse-intent.ts: building the client at
// module load throws when GEMINI_API_KEY is unset, which takes the whole
// function down with an opaque 500 instead of this endpoint's own fallback.
let client: GoogleGenAI | undefined;
function ai(): GoogleGenAI {
  return (client ??= new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY }));
}
const MODEL = 'gemini-3.6-flash';

// gemini-3.6-flash intermittently 503s with "high demand" even on plain
// generation (observed directly against this endpoint, not hypothetical) —
// short retry with backoff absorbs that instead of surfacing it to the app.
async function generateWithRetry(
  params: Parameters<GoogleGenAI['models']['generateContent']>[0],
  attempts = 3,
): Promise<Awaited<ReturnType<GoogleGenAI['models']['generateContent']>>> {
  for (let i = 0; i < attempts; i++) {
    try {
      return await ai().models.generateContent(params);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const isTransient = /503|UNAVAILABLE|high demand/i.test(message);
      if (!isTransient || i === attempts - 1) throw err;
      await new Promise((resolve) => setTimeout(resolve, 300 * (i + 1)));
    }
  }
  throw new Error('unreachable');
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'method not allowed' });
    return;
  }

  const { mode, imageBase64 } = (req.body ?? {}) as { mode?: string; imageBase64?: string };
  if (typeof imageBase64 !== 'string' || (mode !== 'appointment' && mode !== 'read')) {
    res.status(400).json({ error: 'expected { mode: "appointment" | "read", imageBase64: string }' });
    return;
  }

  try {
    const result = mode === 'appointment' ? await extractAppointment(imageBase64) : await readAloud(imageBase64);
    res.status(200).json(result);
  } catch (err) {
    console.error('ocr handler failed', err);
    // Gemini free tier is 20 requests/day/model — surface that distinctly so
    // the phone can say "daily limit" instead of a generic failure.
    const message = err instanceof Error ? err.message : String(err);
    if (/429|RESOURCE_EXHAUSTED|quota/i.test(message)) {
      res.status(429).json({ error: 'model quota exceeded' });
      return;
    }
    res.status(502).json({ error: 'vision processing failed' });
  }
}

async function extractAppointment(imageBase64: string) {
  const response = await generateWithRetry({
    model: MODEL,
    contents: [
      { inlineData: { mimeType: 'image/jpeg', data: imageBase64 } },
      {
        text:
          "This is a photo of a physical appointment card. Extract the appointment details. Today's date " +
          `is ${new Date().toISOString().slice(0, 10)}. If no year is printed, assume the nearest future ` +
          'occurrence of the printed date. Only set "found" to true if a date and time are both clearly ' +
          'legible — do not guess.\n\n' +
          'Respond with ONLY a JSON object, no markdown fences, no commentary, matching exactly this shape:\n' +
          '{"found": boolean, "title": string | null, "startISO8601": string | null, ' +
          '"endISO8601": string | null, "location": string | null}',
      },
    ],
  });

  const raw = (response.text ?? '').trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();

  let input: { found?: boolean; title?: string; startISO8601?: string; endISO8601?: string; location?: string };
  try {
    input = JSON.parse(raw || '{}');
  } catch {
    // Model didn't return clean JSON — treat as "nothing found" rather than
    // crashing the request; the ViewModel already handles this as a
    // "couldn't read the card, try again" case (PRD confirm-before-write rule).
    return { title: null, startISO8601: null, endISO8601: null, location: null };
  }

  if (!input.found || !input.startISO8601) {
    return { title: null, startISO8601: null, endISO8601: null, location: null };
  }

  return {
    title: input.title ?? 'Appointment',
    startISO8601: input.startISO8601,
    endISO8601: input.endISO8601 ?? null,
    location: input.location ?? null,
  };
}

async function readAloud(imageBase64: string) {
  const response = await generateWithRetry({
    model: MODEL,
    contents: [
      { inlineData: { mimeType: 'image/jpeg', data: imageBase64 } },
      {
        text:
          'Transcribe all the readable text in this photo exactly, in natural reading order, so it can be ' +
          'read aloud to someone who cannot see it clearly. Plain text only — no commentary, no formatting, ' +
          'no markdown. If there is no legible text, respond with an empty string.',
      },
    ],
  });

  return { text: (response.text ?? '').trim() };
}
