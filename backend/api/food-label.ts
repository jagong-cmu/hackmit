import type { VercelRequest, VercelResponse } from '@vercel/node';
import { GoogleGenAI } from '@google/genai';
import { z } from 'zod';

// Feature 10's backend endpoint (prds/PRD-food-label.md § 10b — Food label
// reader with diet check). Same shape as api/scam-check.ts on purpose: one
// still photo in, one stateless inference call, structured JSON back, nothing
// persisted server-side.
//
// This endpoint only *transcribes* the label: numbers per serving, the
// ingredient list, allergen statements, claims. Whether any of it fits the
// wearer's diet is decided on the phone (DietaryFitEvaluator) against a
// profile that never leaves the device — the request carries the photo and
// nothing else.

// Constructed lazily, matching api/scam-check.ts: building the client at
// module load throws when GEMINI_API_KEY is unset, which takes the whole
// function down with an opaque 500 instead of this endpoint's own fallback —
// and lets the pure helpers below be unit-tested with no key at all.
let client: GoogleGenAI | undefined;
function ai(): GoogleGenAI {
  return (client ??= new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY }));
}
const MODEL = 'gemini-3.6-flash';

// Same transient-503 behavior observed against gemini-3.6-flash's
// schema-constrained path in api/ocr.ts — plain-text generation + manual
// JSON parsing sidesteps it here too.
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

/** A number the model read clearly, or null. Never a guess. */
const legibleNumber = z.number().finite().nullable();

/** Per-serving nutrients. Mirrors `FoodLabelResult.Nutrients` in FoodLabelResult.swift. */
export const NutrientsSchema = z.object({
  calories: legibleNumber,
  totalFatG: legibleNumber,
  saturatedFatG: legibleNumber,
  transFatG: legibleNumber,
  cholesterolMg: legibleNumber,
  sodiumMg: legibleNumber,
  totalCarbohydrateG: legibleNumber,
  dietaryFiberG: legibleNumber,
  totalSugarsG: legibleNumber,
  addedSugarsG: legibleNumber,
  proteinG: legibleNumber,
  potassiumMg: legibleNumber,
  phosphorusMg: legibleNumber,
});

/** What we send back. Mirrors `FoodLabelResult` in FoodLabelResult.swift. */
export const FoodLabelSchema = z.object({
  /** A food label (Nutrition Facts and/or ingredients) is visible. */
  found: z.boolean(),
  productName: z.string().nullable(),
  /** As printed, e.g. "1 cup (245g)". */
  servingSize: z.string().nullable(),
  servingsPerContainer: legibleNumber,
  nutrients: NutrientsSchema,
  /** Split on top-level commas; sub-ingredients kept inside their parentheses. */
  ingredients: z.array(z.string()),
  /** "Contains: wheat, milk, soy" as printed. */
  containsStatement: z.string().nullable(),
  mayContainStatement: z.string().nullable(),
  /** "gluten-free", "low sodium", "no added sugar"… as printed on the package. */
  claims: z.array(z.string()),
  /** Cooking/heating instructions if visible. */
  preparation: z.string().nullable(),
  /** Best-by / use-by text as printed. */
  expiration: z.string().nullable(),
  /** Everything legible, in reading order, for "read everything". */
  fullText: z.string(),
});
export type FoodLabelResult = z.infer<typeof FoodLabelSchema>;
export type Nutrients = z.infer<typeof NutrientsSchema>;

export const NUTRIENT_KEYS = Object.keys(NutrientsSchema.shape) as (keyof Nutrients)[];

const EMPTY_NUTRIENTS: Nutrients = {
  calories: null,
  totalFatG: null,
  saturatedFatG: null,
  transFatG: null,
  cholesterolMg: null,
  sodiumMg: null,
  totalCarbohydrateG: null,
  dietaryFiberG: null,
  totalSugarsG: null,
  addedSugarsG: null,
  proteinG: null,
  potassiumMg: null,
  phosphorusMg: null,
};

/** `found: false` with empty fields — what the phone hears as "I don't see a nutrition label." */
export const FALLBACK: FoodLabelResult = {
  found: false,
  productName: null,
  servingSize: null,
  servingsPerContainer: null,
  nutrients: { ...EMPTY_NUTRIENTS },
  ingredients: [],
  containsStatement: null,
  mayContainStatement: null,
  claims: [],
  preparation: null,
  expiration: null,
  fullText: '',
};

export const PROMPT =
  'This is a photo of a packaged food, taken for an adult over 60 who cannot read small print and may be ' +
  'on a restricted diet (low sodium, diabetes, kidney disease, allergies). Transcribe the label so the ' +
  'phone can read it aloud and compare the numbers to limits their doctor set.\n\n' +
  'Rules:\n' +
  '- Transcribe every number EXACTLY as printed. Use null for anything that is not clearly legible — a ' +
  'wrong sodium number is worse than a missing one. Never estimate, infer from similar products, or ' +
  'fill in a typical value.\n' +
  '- All nutrients are PER SERVING. When the panel has two columns (per serving and per container, or ' +
  'as packaged and as prepared), use the per-serving / as-packaged column only.\n' +
  '- Keep units as printed: milligrams in the "Mg" fields, grams in the "G" fields. Do not convert. If a ' +
  'value is printed in a different unit or as "<1", return null for it.\n' +
  '- "servingSize" is the text as printed, e.g. "1 cup (245g)". "servingsPerContainer" is a number ' +
  '("about 2.5" → 2.5).\n' +
  '- "ingredients": split the ingredient list on top-level commas only; keep sub-ingredients inside their ' +
  'parentheses as part of the parent entry. Preserve the printed order.\n' +
  '- "containsStatement" / "mayContainStatement": the allergen statements exactly as printed ' +
  '("Contains: wheat, milk, soy"), or null.\n' +
  '- "claims": marketing/regulatory claims printed on the package such as "gluten-free", "low sodium", ' +
  '"no added sugar", "organic".\n' +
  '- "preparation": cooking or heating instructions if visible, else null. "expiration": the best-by / ' +
  'use-by text if visible, else null.\n' +
  '- "fullText": everything legible on the visible packaging, in reading order.\n' +
  '- "found" is true only when a Nutrition Facts panel and/or an ingredients list is visible. For ' +
  'anything that is not a food label (a menu, a letter, a room, a person, a medication bottle) return ' +
  'found false with every other field null, empty arrays, and an empty fullText.\n\n' +
  'Respond with ONLY a JSON object, no markdown fences, no commentary, matching exactly this shape:\n' +
  '{"found": boolean, "productName": string | null, "servingSize": string | null, ' +
  '"servingsPerContainer": number | null, "nutrients": {"calories": number | null, "totalFatG": number | null, ' +
  '"saturatedFatG": number | null, "transFatG": number | null, "cholesterolMg": number | null, ' +
  '"sodiumMg": number | null, "totalCarbohydrateG": number | null, "dietaryFiberG": number | null, ' +
  '"totalSugarsG": number | null, "addedSugarsG": number | null, "proteinG": number | null, ' +
  '"potassiumMg": number | null, "phosphorusMg": number | null}, "ingredients": string[], ' +
  '"containsStatement": string | null, "mayContainStatement": string | null, "claims": string[], ' +
  '"preparation": string | null, "expiration": string | null, "fullText": string}';

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'method not allowed' });
    return;
  }

  const { imageBase64 } = (req.body ?? {}) as { imageBase64?: string };
  if (typeof imageBase64 !== 'string' || imageBase64.length === 0) {
    res.status(400).json({ error: 'expected { imageBase64: string }' });
    return;
  }

  try {
    res.status(200).json(await readLabel(imageBase64));
  } catch (err) {
    console.error('food-label handler failed', err);
    const message = err instanceof Error ? err.message : String(err);
    if (/429|RESOURCE_EXHAUSTED|quota/i.test(message)) {
      res.status(429).json({ error: 'model quota exceeded' });
      return;
    }
    res.status(502).json({ error: 'food label processing failed' });
  }
}

async function readLabel(imageBase64: string): Promise<FoodLabelResult> {
  const response = await generateWithRetry({
    model: MODEL,
    contents: [{ inlineData: { mimeType: 'image/jpeg', data: imageBase64 } }, { text: PROMPT }],
  });

  return parseModelOutput(response.text ?? '');
}

// ---------------------------------------------------------------------------
// Pure helpers — exported so backend/tests/foodLabel.test.ts can exercise the
// parsing and normalization without a GEMINI_API_KEY.
// ---------------------------------------------------------------------------

/** Strips ```json fences the model sometimes adds despite being told not to. */
export function stripFences(raw: string): string {
  return raw.trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();
}

/**
 * Model text → validated `FoodLabelResult`. Unparseable or non-object output
 * is `FALLBACK`; a parseable object is normalized field by field so one odd
 * value (a number as "890mg", a missing key) degrades that field to null
 * rather than throwing the whole label away.
 */
export function parseModelOutput(raw: string): FoodLabelResult {
  let candidate: unknown;
  try {
    candidate = JSON.parse(stripFences(raw) || '{}');
  } catch {
    return FALLBACK;
  }
  return normalizeFoodLabel(candidate);
}

/** Coerces whatever the model returned into the exact shape the phone decodes. */
export function normalizeFoodLabel(candidate: unknown): FoodLabelResult {
  if (!isRecord(candidate)) return FALLBACK;

  const nutrientsSource = isRecord(candidate.nutrients) ? candidate.nutrients : {};
  const nutrients: Nutrients = { ...EMPTY_NUTRIENTS };
  for (const key of NUTRIENT_KEYS) {
    nutrients[key] = legibleNumberOrNull(nutrientsSource[key]);
  }

  const normalized: FoodLabelResult = {
    found: candidate.found === true,
    productName: stringOrNull(candidate.productName),
    servingSize: stringOrNull(candidate.servingSize),
    servingsPerContainer: legibleNumberOrNull(candidate.servingsPerContainer),
    nutrients,
    ingredients: stringArray(candidate.ingredients),
    containsStatement: stringOrNull(candidate.containsStatement),
    mayContainStatement: stringOrNull(candidate.mayContainStatement),
    claims: stringArray(candidate.claims),
    preparation: stringOrNull(candidate.preparation),
    expiration: stringOrNull(candidate.expiration),
    fullText: typeof candidate.fullText === 'string' ? candidate.fullText.trim() : '',
  };

  // A label with nothing on it isn't a label: "found" must be backed by
  // something the phone can speak.
  if (
    normalized.found &&
    normalized.ingredients.length === 0 &&
    NUTRIENT_KEYS.every((key) => normalized.nutrients[key] === null) &&
    normalized.fullText.length === 0
  ) {
    return FALLBACK;
  }
  if (!normalized.found) {
    return FALLBACK;
  }

  // Final gate: the same schema the phone decodes. Anything that still fails
  // becomes the fallback, never a crash.
  const parsed = FoodLabelSchema.safeParse(normalized);
  if (!parsed.success) {
    console.error('food-label: normalized output failed schema', parsed.error.message);
    return FALLBACK;
  }
  return parsed.data;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function stringOrNull(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length === 0 ? null : trimmed;
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value
    .filter((item): item is string => typeof item === 'string')
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

/**
 * A finite, non-negative number, or null. Accepts a numeric string with an
 * optional unit suffix the model sometimes leaves on ("890mg", "2.5 g") but
 * refuses anything that would require a guess ("<1", "trace", "N/A").
 */
export function legibleNumberOrNull(value: unknown): number | null {
  if (typeof value === 'number') {
    return Number.isFinite(value) && value >= 0 ? value : null;
  }
  if (typeof value === 'string') {
    const match = /^\s*(\d+(?:\.\d+)?)\s*(mg|mcg|g|kcal|cal|calories|%)?\s*$/i.exec(value);
    if (!match) return null;
    const parsed = Number(match[1]);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}
