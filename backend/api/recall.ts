import type { VercelRequest, VercelResponse } from "@vercel/node";
import { GoogleGenAI } from "@google/genai";
import { z } from "zod";

// Feature 9's backend endpoint (PRD-memory § Backend): general recall —
// "where did I put my glasses case?" — grounded in the wearer's own notes.
// Same Gemini + retry + zod pattern as api/parse-intent.ts so the whole
// backend runs on one API key. Stateless: the phone sends its most recent
// notes with every question and nothing is persisted here. Coordinates are
// never part of the request — the phone answers parking questions itself.

// Constructed lazily, matching api/scam-check.ts: building the client at
// module load throws when GEMINI_API_KEY is unset, which takes the whole
// function down with an opaque 500 instead of this endpoint's own fallback —
// and lets the pure helpers below be unit-tested without a key.
let client: GoogleGenAI | undefined;
function ai(): GoogleGenAI {
  return (client ??= new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY }));
}
const MODEL = "gemini-3.6-flash";

/** PRD-memory § 9b: the phone sends at most its 100 most recent notes. */
export const MAX_NOTES = 100;

/** One saved note as the phone serializes it (RecallClient.Payload.Note). */
const NoteSchema = z.object({
  id: z.string().min(1).max(64),
  kind: z.enum(["parking", "general"]),
  /** The wearer's own words, prefix stripped. Empty for a photo-only parking note. */
  text: z.string().max(1000),
  /** OCR of the parking sign, or null. */
  signText: z.string().max(500).nullable(),
  /** ISO 8601 with the wearer's UTC offset. */
  createdAt: z.string().min(1),
});
export type RecallNote = z.infer<typeof NoteSchema>;

/** What the phone sends us. Unknown keys (there should be none) are stripped. */
export const RequestSchema = z.object({
  question: z.string().min(1).max(500),
  /** ISO 8601 with offset. */
  now: z.string().min(1),
  /** IANA identifier, e.g. "America/New_York". */
  timeZone: z.string().min(1),
  notes: z.array(NoteSchema).max(MAX_NOTES),
});
export type RecallRequest = z.infer<typeof RequestSchema>;

/** What we send back. Mirrors `RecallAnswer` in RecallClient.swift. */
export const RecallSchema = z.object({
  /** Spoken aloud verbatim. */
  answer: z.string(),
  matchedNoteIds: z.array(z.string()).default([]),
});
export type RecallResponse = z.infer<typeof RecallSchema>;

/** The exact no-match sentence, by contract with the phone and the prompt. */
export const NO_MATCH = "I don't have a note about that.";
export const NO_MATCH_RESPONSE: RecallResponse = { answer: NO_MATCH, matchedNoteIds: [] };

/** Spoken back verbatim, so it has to sound like a sentence. */
export const FALLBACK: RecallResponse = {
  answer: "I couldn't check my notes just now. Please try again.",
  matchedNoteIds: [],
};

export const QUOTA_FALLBACK: RecallResponse = {
  answer: "I've hit my daily limit for checking notes. Please try again later.",
  matchedNoteIds: [],
};

export const SYSTEM = `You are the voice of a pair of smart glasses worn by an adult over 60. Earlier they asked you to remember some things; now they are asking you about them. You are handed their saved notes and their question.

Each note has: an id, a kind ("parking" or "general"), the wearer's own words (may be empty for a photographed parking spot), the text of a parking sign if one was photographed (or null), and when it was saved as an ISO 8601 timestamp in the wearer's own time zone.

Rules:
- Answer ONLY from the notes. Never invent a detail that is not in a note. Do not guess.
- Reply in one or two short spoken sentences, warm and plain — this is read aloud, never shown.
- Always say when the matching note was saved, relative to the current time and time zone: "this morning at nine", "yesterday afternoon", "last Tuesday", "about two hours ago". Never read out a raw timestamp.
- If several notes could answer, prefer the most recent one; mention an older one only if it clearly helps.
- Repeat the note's contents in the wearer's own words where you can, as a sentence: "you told me you put your glasses case in the kitchen drawer."
- If no note plausibly answers the question, reply with exactly: ${NO_MATCH}  — and an empty matchedNoteIds.
- matchedNoteIds lists the ids of the notes your answer is based on, most relevant first.

Respond with ONLY a JSON object, no markdown fences, no commentary, matching exactly this shape:
{"answer": string, "matchedNoteIds": string[]}`;

/** The one message we send: instructions, clock, notes, question. */
export function buildPrompt(request: RecallRequest): string {
  const notes = request.notes.map((note) => ({
    id: note.id,
    kind: note.kind,
    text: note.text,
    signText: note.signText,
    savedAt: note.createdAt,
  }));
  return [
    SYSTEM,
    "",
    `Current time: ${request.now}`,
    `Time zone: ${request.timeZone}`,
    "",
    `Notes (${notes.length}, newest first):`,
    JSON.stringify(notes),
    "",
    `Question: "${request.question}"`,
  ].join("\n");
}

/** Strips ```json fences the model sometimes adds despite being told not to. */
export function stripFences(raw: string): string {
  return raw.trim().replace(/^```(?:json)?/i, "").replace(/```$/, "").trim();
}

/**
 * Validates the model's JSON against the same schema the phone decodes and
 * tidies it: unknown note ids are dropped, the no-match sentence always comes
 * with an empty id list, and anything malformed or empty becomes the spoken
 * fallback — never a crash, never silence.
 */
export function normalizeAnswer(candidate: unknown, knownIds: Iterable<string>): RecallResponse {
  const parsed = RecallSchema.safeParse(candidate);
  if (!parsed.success) return FALLBACK;

  const answer = parsed.data.answer.trim();
  if (answer.length === 0) return FALLBACK;
  if (answer === NO_MATCH) return NO_MATCH_RESPONSE;

  const known = new Set(knownIds);
  const matchedNoteIds = [...new Set(parsed.data.matchedNoteIds)].filter((id) => known.has(id));
  return { answer, matchedNoteIds };
}

/**
 * Answers that need no model: with no notes there is nothing to ground an
 * answer in. (The phone short-circuits this too, with its own sentence; the
 * backend still has to be safe on its own.)
 */
export function localAnswer(request: RecallRequest): RecallResponse | null {
  if (request.notes.length === 0) return NO_MATCH_RESPONSE;
  return null;
}

function isQuotaError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /429|RESOURCE_EXHAUSTED|quota/i.test(message);
}

// gemini-3.6-flash intermittently 503s with "high demand" (observed live from
// ocr.ts) — short retry with backoff instead of surfacing it to the wearer.
async function generateWithRetry(
  params: Parameters<GoogleGenAI["models"]["generateContent"]>[0],
  attempts = 3,
): Promise<Awaited<ReturnType<GoogleGenAI["models"]["generateContent"]>>> {
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
  const request = parsedBody.data;

  const local = localAnswer(request);
  if (local) {
    return json(local);
  }

  try {
    const response = await generateWithRetry({
      model: MODEL,
      contents: [{ text: buildPrompt(request) }],
    });

    const raw = stripFences(response.text ?? "");
    let candidate: unknown;
    try {
      candidate = JSON.parse(raw || "{}");
    } catch {
      return json(FALLBACK);
    }

    // The model's output is validated against the same schema the phone
    // decodes — anything malformed becomes the spoken fallback, never a crash.
    const normalized = normalizeAnswer(candidate, request.notes.map((note) => note.id));
    if (normalized === FALLBACK) {
      console.error("recall: model output failed schema", raw);
    }
    return json(normalized);
  } catch (error) {
    console.error("recall failed:", error);
    // A quota wall is a 200 with a spoken reason, not a 502: the phone treats
    // non-2xx as "something went wrong", and the wearer should hear *why*.
    if (isQuotaError(error)) {
      return json(QUOTA_FALLBACK);
    }
    return json(FALLBACK, 502);
  }
}
