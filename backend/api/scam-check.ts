import type { VercelRequest, VercelResponse } from '@vercel/node';
import { GoogleGenAI } from '@google/genai';

// Workstream C's backend endpoint (PRD.md § Feature 5 — Advertisement scam
// detection, OCR-only). Same shape as Workstream B's api/ocr.ts on purpose:
// one still photo in, one stateless inference call, structured JSON back,
// nothing persisted server-side.
//
// OCR-only per the PRD: this reads the advertisement's visible TEXT and
// assesses it for scam-risk language patterns. It does not inspect pixels,
// so it cannot prove an image itself was AI-generated — the response has to
// say that plainly rather than imply more certainty than the method supports.

const ai = new GoogleGenAI({ apiKey: process.env.GEMINI_API_KEY });
const MODEL = 'gemini-3.6-flash';

// Same transient-503 behavior observed against gemini-3.6-flash's
// schema-constrained path in api/ocr.ts — plain-text generation + manual
// JSON parsing sidesteps it here too.
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
  throw new Error('unreachable');
}

type ScamRisk = 'high' | 'medium' | 'low';

interface ScamCheckResult {
  extractedText: string;
  /** OCR-only — this is a text-pattern read, never a pixel-level determination. */
  aiGeneratedTextSignals: boolean;
  scamRisk: ScamRisk;
  /** The specific visible cues that led to the result — never a bare verdict. */
  cues: string[];
  /** What the wearer should do next, spoken aloud verbatim. */
  safeAction: string;
}

const FALLBACK: ScamCheckResult = {
  extractedText: '',
  aiGeneratedTextSignals: false,
  scamRisk: 'low',
  cues: [],
  safeAction: "I couldn't read that ad clearly. Try holding it steadier or getting closer.",
};

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
    res.status(200).json(await checkAd(imageBase64));
  } catch (err) {
    console.error('scam-check handler failed', err);
    res.status(502).json({ error: 'scam check processing failed' });
  }
}

async function checkAd(imageBase64: string): Promise<ScamCheckResult> {
  const response = await generateWithRetry({
    model: MODEL,
    contents: [
      { inlineData: { mimeType: 'image/jpeg', data: imageBase64 } },
      {
        text:
          'This is a photo of a printed or on-screen advertisement, aimed at an adult over 60 who wants ' +
          "to know if it's safe to trust. Read the visible text and assess it — you are not analyzing " +
          'the image pixels, only the text content and its patterns.\n\n' +
          'Look for scam-risk language: impersonation of a real company or agency, artificial urgency ' +
          '("act now", "24 hours only"), guaranteed or unrealistic returns, requests for payment, gift ' +
          'cards, wire transfers, or personal/financial information, suspicious or misspelled links, and ' +
          'generic or robotic phrasing that reads like AI-generated marketing copy rather than a real ad.\n\n' +
          'Respond with ONLY a JSON object, no markdown fences, no commentary, matching exactly this shape:\n' +
          '{"extractedText": string, "aiGeneratedTextSignals": boolean, "scamRisk": "high" | "medium" | ' +
          '"low", "cues": string[], "safeAction": string}\n\n' +
          '"cues" must list the specific visible phrases or details that drove the assessment — never ' +
          'return a verdict with no cues. "safeAction" is one short sentence spoken aloud verbatim; for ' +
          '"high" or "medium" risk it must include not calling or paying from the ad and instead verifying ' +
          'the organization through its official website or a trusted contact. If no legible text is found, ' +
          'return empty extractedText, scamRisk "low", empty cues, and a safeAction asking to try again.',
      },
    ],
  });

  const raw = (response.text ?? '').trim().replace(/^```(?:json)?/i, '').replace(/```$/, '').trim();

  let parsed: Partial<ScamCheckResult>;
  try {
    parsed = JSON.parse(raw || '{}');
  } catch {
    return FALLBACK;
  }

  if (!parsed.extractedText) {
    return FALLBACK;
  }

  return {
    extractedText: parsed.extractedText,
    aiGeneratedTextSignals: parsed.aiGeneratedTextSignals ?? false,
    scamRisk: parsed.scamRisk === 'high' || parsed.scamRisk === 'medium' ? parsed.scamRisk : 'low',
    cues: Array.isArray(parsed.cues) ? parsed.cues.filter((c): c is string => typeof c === 'string') : [],
    safeAction: parsed.safeAction ?? FALLBACK.safeAction,
  };
}
