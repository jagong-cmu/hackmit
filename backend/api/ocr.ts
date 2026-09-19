import type { VercelRequest, VercelResponse } from '@vercel/node';
import Anthropic from '@anthropic-ai/sdk';

// Workstream B's backend endpoint (PRD.md § Parallel workstreams).
// Stateless by design: the photo is sent for one inference call and is
// never persisted here or anywhere server-side — only the structured
// result goes back to the phone, which stores it locally (PRD § AI backend).

const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
const MODEL = 'claude-sonnet-5';

const APPOINTMENT_TOOL = {
  name: 'record_appointment',
  description: 'Records the appointment details found on a physical appointment card, if any are legible.',
  input_schema: {
    type: 'object' as const,
    properties: {
      found: {
        type: 'boolean' as const,
        description: 'true only if a date AND time are both clearly legible on the card',
      },
      title: { type: 'string' as const, description: 'short description, e.g. "Dentist appointment"' },
      startISO8601: { type: 'string' as const, description: 'ISO 8601 date-time' },
      endISO8601: { type: 'string' as const },
      location: { type: 'string' as const },
    },
    required: ['found'],
  },
};

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
    res.status(502).json({ error: 'vision processing failed' });
  }
}

async function extractAppointment(imageBase64: string) {
  const message = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 512,
    tools: [APPOINTMENT_TOOL],
    tool_choice: { type: 'tool', name: 'record_appointment' },
    messages: [
      {
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: imageBase64 } },
          {
            type: 'text',
            text:
              "This is a photo of a physical appointment card. Extract the appointment details. Today's date " +
              `is ${new Date().toISOString().slice(0, 10)}. If no year is printed, assume the nearest future ` +
              'occurrence of the printed date. Only set found=true if a date and time are both clearly legible ' +
              '— do not guess.',
          },
        ],
      },
    ],
  });

  const toolUse = message.content.find((block) => block.type === 'tool_use');
  const input = (toolUse && 'input' in toolUse ? toolUse.input : {}) as {
    found?: boolean;
    title?: string;
    startISO8601?: string;
    endISO8601?: string;
    location?: string;
  };

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
  const message = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 1024,
    messages: [
      {
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: imageBase64 } },
          {
            type: 'text',
            text:
              'Transcribe all the readable text in this photo exactly, in natural reading order, so it can be ' +
              'read aloud to someone who cannot see it clearly. Plain text only — no commentary, no formatting, ' +
              'no markdown. If there is no legible text, respond with an empty string.',
          },
        ],
      },
    ],
  });

  const text = message.content
    .filter((block) => block.type === 'text')
    .map((block) => ('text' in block ? block.text : ''))
    .join('\n')
    .trim();

  return { text };
}
