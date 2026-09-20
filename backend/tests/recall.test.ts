import { test } from "node:test";
import assert from "node:assert/strict";
import {
  FALLBACK,
  MAX_NOTES,
  NO_MATCH,
  NO_MATCH_RESPONSE,
  QUOTA_FALLBACK,
  RequestSchema,
  RecallSchema,
  SYSTEM,
  buildPrompt,
  localAnswer,
  normalizeAnswer,
  stripFences,
} from "../api/recall.ts";

// There is no GEMINI_API_KEY locally, so these cover everything around the
// model call: request validation, prompt assembly, and the normalization of
// whatever the model hands back. The client is constructed lazily, so
// importing the endpoint needs no key.

const sampleNotes = [
  {
    id: "a1",
    kind: "parking",
    text: "",
    signText: "Level 3, Row F",
    createdAt: "2027-01-15T09:05:00-05:00",
  },
  {
    id: "b2",
    kind: "general",
    text: "i put my glasses case in the kitchen drawer",
    signText: null,
    createdAt: "2027-01-14T18:30:00-05:00",
  },
  {
    id: "c3",
    kind: "general",
    text: "frank is the new neighbor",
    signText: null,
    createdAt: "2027-01-12T11:00:00-05:00",
  },
];

const sampleRequest = {
  question: "where did i put my glasses case",
  now: "2027-01-15T14:00:00-05:00",
  timeZone: "America/New_York",
  notes: sampleNotes,
};

// MARK: Request schema

test("RequestSchema accepts the phone's payload", () => {
  const parsed = RequestSchema.safeParse(sampleRequest);
  assert.ok(parsed.success, parsed.success ? "" : parsed.error.message);
  assert.equal(parsed.data.notes.length, 3);
  assert.equal(parsed.data.notes[0].signText, "Level 3, Row F");
  assert.equal(parsed.data.notes[1].signText, null);
});

test("RequestSchema strips coordinate fields if a client ever sent them", () => {
  const leaky = {
    ...sampleRequest,
    notes: [{ ...sampleNotes[1], latitude: 42.35, longitude: -71.06, horizontalAccuracy: 10 }],
  };
  const parsed = RequestSchema.safeParse(leaky);
  assert.ok(parsed.success);
  const note = parsed.data.notes[0] as Record<string, unknown>;
  assert.equal("latitude" in note, false);
  assert.equal("longitude" in note, false);
  assert.equal("horizontalAccuracy" in note, false);
  assert.equal(buildPrompt(parsed.data).includes("42.35"), false);
});

test("RequestSchema rejects more than 100 notes", () => {
  const many = Array.from({ length: MAX_NOTES + 1 }, (_, i) => ({ ...sampleNotes[1], id: `n${i}` }));
  assert.equal(RequestSchema.safeParse({ ...sampleRequest, notes: many }).success, false);
  assert.equal(RequestSchema.safeParse({ ...sampleRequest, notes: many.slice(0, MAX_NOTES) }).success, true);
});

test("RequestSchema rejects an unknown kind, an empty question and a missing signText", () => {
  assert.equal(RequestSchema.safeParse({ ...sampleRequest, notes: [{ ...sampleNotes[1], kind: "todo" }] }).success, false);
  assert.equal(RequestSchema.safeParse({ ...sampleRequest, question: "" }).success, false);
  const { signText: _omitted, ...withoutSign } = sampleNotes[1];
  assert.equal(RequestSchema.safeParse({ ...sampleRequest, notes: [withoutSign] }).success, false);
  assert.equal(RequestSchema.safeParse(null).success, false);
});

test("RequestSchema accepts zero notes and a photo-only parking note", () => {
  assert.equal(RequestSchema.safeParse({ ...sampleRequest, notes: [] }).success, true);
  assert.equal(RequestSchema.safeParse({ ...sampleRequest, notes: [sampleNotes[0]] }).success, true);
});

// MARK: Prompt

test("buildPrompt carries the clock, the zone, every note and the question", () => {
  const prompt = buildPrompt(RequestSchema.parse(sampleRequest));
  assert.ok(prompt.startsWith(SYSTEM));
  assert.ok(prompt.includes("Current time: 2027-01-15T14:00:00-05:00"));
  assert.ok(prompt.includes("Time zone: America/New_York"));
  assert.ok(prompt.includes("Notes (3, newest first):"));
  for (const note of sampleNotes) {
    assert.ok(prompt.includes(`"id":"${note.id}"`), `note ${note.id} present`);
  }
  assert.ok(prompt.includes('"savedAt":"2027-01-15T09:05:00-05:00"'));
  assert.ok(prompt.endsWith('Question: "where did i put my glasses case"'));
});

test("the system prompt pins the contract the phone relies on", () => {
  assert.ok(SYSTEM.includes(NO_MATCH), "exact no-match sentence is in the prompt");
  assert.ok(/when the matching note was saved/i.test(SYSTEM), "always says when");
  assert.ok(/ONLY from the notes/i.test(SYSTEM), "grounded in notes only");
  assert.ok(/one or two short spoken sentences/i.test(SYSTEM));
  assert.ok(SYSTEM.includes('{"answer": string, "matchedNoteIds": string[]}'));
});

// MARK: Fences

test("stripFences removes markdown fences and whitespace", () => {
  const body = '{"answer":"Yesterday evening you told me your glasses case is in the kitchen drawer.","matchedNoteIds":["b2"]}';
  assert.equal(stripFences(`\`\`\`json\n${body}\n\`\`\``), body);
  assert.equal(stripFences(`\`\`\`\n${body}\n\`\`\`  `), body);
  assert.equal(stripFences(`  ${body}\n`), body);
  assert.equal(stripFences(""), "");
});

// MARK: Model output normalization

const knownIds = sampleNotes.map((n) => n.id);

test("a matching answer is returned with its time phrase and known ids", () => {
  const out = normalizeAnswer(
    { answer: "Yesterday evening you told me you put your glasses case in the kitchen drawer.", matchedNoteIds: ["b2"] },
    knownIds,
  );
  assert.deepEqual(out, {
    answer: "Yesterday evening you told me you put your glasses case in the kitchen drawer.",
    matchedNoteIds: ["b2"],
  });
});

test("the no-match sentence is exact and always comes with no ids", () => {
  assert.equal(NO_MATCH, "I don't have a note about that.");
  assert.deepEqual(normalizeAnswer({ answer: NO_MATCH, matchedNoteIds: ["b2"] }, knownIds), NO_MATCH_RESPONSE);
  assert.deepEqual(normalizeAnswer({ answer: `  ${NO_MATCH} `, matchedNoteIds: [] }, knownIds), NO_MATCH_RESPONSE);
});

test("unknown and duplicate note ids are dropped", () => {
  const out = normalizeAnswer({ answer: "Frank is the new neighbor, you said last Tuesday.", matchedNoteIds: ["zzz", "c3", "c3"] }, knownIds);
  assert.deepEqual(out.matchedNoteIds, ["c3"]);
});

test("a missing matchedNoteIds defaults to empty", () => {
  const out = normalizeAnswer({ answer: "This morning at nine you parked at Level 3, Row F." }, knownIds);
  assert.deepEqual(out, { answer: "This morning at nine you parked at Level 3, Row F.", matchedNoteIds: [] });
});

test("malformed or empty model output becomes the spoken fallback", () => {
  assert.equal(normalizeAnswer(null, knownIds), FALLBACK);
  assert.equal(normalizeAnswer("just text", knownIds), FALLBACK);
  assert.equal(normalizeAnswer({}, knownIds), FALLBACK);
  assert.equal(normalizeAnswer({ answer: 42, matchedNoteIds: [] }, knownIds), FALLBACK);
  assert.equal(normalizeAnswer({ answer: "   ", matchedNoteIds: [] }, knownIds), FALLBACK);
  assert.equal(normalizeAnswer({ answer: "ok", matchedNoteIds: "b2" }, knownIds), FALLBACK);
});

test("fallback sentences are the PRD's copy", () => {
  assert.equal(FALLBACK.answer, "I couldn't check my notes just now. Please try again.");
  assert.deepEqual(FALLBACK.matchedNoteIds, []);
  assert.deepEqual(QUOTA_FALLBACK.matchedNoteIds, []);
  assert.ok(RecallSchema.safeParse(FALLBACK).success, "the fallback itself satisfies the response schema");
  assert.ok(RecallSchema.safeParse(NO_MATCH_RESPONSE).success);
});

// MARK: Local answers

test("zero notes is answered without the model", () => {
  const request = RequestSchema.parse({ ...sampleRequest, notes: [] });
  assert.deepEqual(localAnswer(request), NO_MATCH_RESPONSE);
});

test("with notes present the model is consulted", () => {
  assert.equal(localAnswer(RequestSchema.parse(sampleRequest)), null);
});
