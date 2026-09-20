import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  FALLBACK,
  FoodLabelSchema,
  NUTRIENT_KEYS,
  PROMPT,
  legibleNumberOrNull,
  normalizeFoodLabel,
  parseModelOutput,
  stripFences,
} from '../api/food-label.ts';

// Importing the endpoint never needs GEMINI_API_KEY: the Gemini client is
// constructed lazily inside the handler. These tests cover the pure parsing
// and normalization that turns model text into the exact shape the phone
// decodes (FoodLabelResult.swift).

const soupJSON = JSON.stringify({
  found: true,
  productName: "Campbell's Chicken Noodle Soup",
  servingSize: '1 cup (245g)',
  servingsPerContainer: 2.5,
  nutrients: {
    calories: 60,
    totalFatG: 2,
    saturatedFatG: 0.5,
    transFatG: 0,
    cholesterolMg: 15,
    sodiumMg: 890,
    totalCarbohydrateG: 8,
    dietaryFiberG: 1,
    totalSugarsG: 1,
    addedSugarsG: 0,
    proteinG: 3,
    potassiumMg: null,
    phosphorusMg: null,
  },
  ingredients: ['Chicken stock', 'Enriched egg noodles (wheat flour, egg whites, eggs)', 'Chicken meat', 'Salt'],
  containsStatement: 'Contains: wheat, egg, soy',
  mayContainStatement: null,
  claims: [],
  preparation: 'Mix soup + 1 can water.',
  expiration: 'Best by MAR 2027',
  fullText: 'Campbell\'s Condensed Chicken Noodle Soup. Sodium 890mg 39%.',
});

test('stripFences removes markdown fences the model adds anyway', () => {
  assert.equal(stripFences('```json\n{"found": true}\n```'), '{"found": true}');
  assert.equal(stripFences('```\n{"found": true}\n```'), '{"found": true}');
  assert.equal(stripFences('  {"found": true}  '), '{"found": true}');
});

test('a well-formed label passes through with every field intact', () => {
  const result = parseModelOutput(soupJSON);
  assert.equal(result.found, true);
  assert.equal(result.productName, "Campbell's Chicken Noodle Soup");
  assert.equal(result.servingSize, '1 cup (245g)');
  assert.equal(result.servingsPerContainer, 2.5);
  assert.equal(result.nutrients.sodiumMg, 890);
  assert.equal(result.nutrients.saturatedFatG, 0.5);
  assert.equal(result.nutrients.potassiumMg, null);
  assert.deepEqual(result.ingredients, [
    'Chicken stock',
    'Enriched egg noodles (wheat flour, egg whites, eggs)',
    'Chicken meat',
    'Salt',
  ]);
  assert.equal(result.containsStatement, 'Contains: wheat, egg, soy');
  assert.equal(result.mayContainStatement, null);
  assert.equal(result.expiration, 'Best by MAR 2027');
  assert.equal(result.fullText, "Campbell's Condensed Chicken Noodle Soup. Sodium 890mg 39%.");
  assert.ok(FoodLabelSchema.safeParse(result).success);
});

test('fenced output parses the same as bare JSON', () => {
  assert.deepEqual(parseModelOutput('```json\n' + soupJSON + '\n```'), parseModelOutput(soupJSON));
});

test('unparseable output is the FALLBACK, never a throw', () => {
  assert.deepEqual(parseModelOutput('I cannot read this image.'), FALLBACK);
  assert.deepEqual(parseModelOutput(''), FALLBACK);
  assert.deepEqual(parseModelOutput('[1, 2, 3]'), FALLBACK);
  assert.deepEqual(parseModelOutput('null'), FALLBACK);
});

test('FALLBACK is found:false with empty fields and validates against the schema', () => {
  assert.equal(FALLBACK.found, false);
  assert.deepEqual(FALLBACK.ingredients, []);
  assert.deepEqual(FALLBACK.claims, []);
  assert.equal(FALLBACK.fullText, '');
  for (const key of NUTRIENT_KEYS) {
    assert.equal(FALLBACK.nutrients[key], null, key);
  }
  assert.ok(FoodLabelSchema.safeParse(FALLBACK).success);
});

test('found:false from the model becomes the FALLBACK regardless of other fields', () => {
  const result = normalizeFoodLabel({ found: false, productName: 'A menu', fullText: 'Soup of the day $6' });
  assert.deepEqual(result, FALLBACK);
});

test('found:true with nothing legible is not a label', () => {
  const result = normalizeFoodLabel({ found: true, nutrients: {}, ingredients: [], fullText: '' });
  assert.deepEqual(result, FALLBACK);
});

test('missing nutrient keys read as null, never as zero', () => {
  const result = normalizeFoodLabel({
    found: true,
    productName: 'Beans',
    nutrients: { sodiumMg: 10 },
    ingredients: ['green beans', 'water'],
    fullText: 'Green beans.',
  });
  assert.equal(result.found, true);
  assert.equal(result.nutrients.sodiumMg, 10);
  assert.equal(result.nutrients.totalCarbohydrateG, null);
  assert.equal(result.nutrients.calories, null);
  assert.equal(result.servingsPerContainer, null);
  assert.equal(result.containsStatement, null);
  assert.deepEqual(result.claims, []);
  assert.ok(FoodLabelSchema.safeParse(result).success);
});

test('numbers left as strings with units are parsed; anything that needs a guess is null', () => {
  assert.equal(legibleNumberOrNull(890), 890);
  assert.equal(legibleNumberOrNull(0), 0);
  assert.equal(legibleNumberOrNull(2.5), 2.5);
  assert.equal(legibleNumberOrNull('890mg'), 890);
  assert.equal(legibleNumberOrNull('2.5 g'), 2.5);
  assert.equal(legibleNumberOrNull('60 calories'), 60);
  assert.equal(legibleNumberOrNull('<1g'), null);
  assert.equal(legibleNumberOrNull('trace'), null);
  assert.equal(legibleNumberOrNull('N/A'), null);
  assert.equal(legibleNumberOrNull(''), null);
  assert.equal(legibleNumberOrNull(-5), null);
  assert.equal(legibleNumberOrNull(Number.NaN), null);
  assert.equal(legibleNumberOrNull(Number.POSITIVE_INFINITY), null);
  assert.equal(legibleNumberOrNull(null), null);
  assert.equal(legibleNumberOrNull(undefined), null);
  assert.equal(legibleNumberOrNull(true), null);
  assert.equal(legibleNumberOrNull({}), null);
});

test('a stringly-typed nutrient block is coerced field by field', () => {
  const result = normalizeFoodLabel({
    found: true,
    productName: 'Crackers',
    nutrients: { sodiumMg: '230mg', totalCarbohydrateG: '20 g', addedSugarsG: '<1g', proteinG: 'trace' },
    ingredients: ['wheat flour'],
    fullText: 'Crackers.',
  });
  assert.equal(result.nutrients.sodiumMg, 230);
  assert.equal(result.nutrients.totalCarbohydrateG, 20);
  assert.equal(result.nutrients.addedSugarsG, null);
  assert.equal(result.nutrients.proteinG, null);
});

test('non-string entries in arrays are dropped and strings are trimmed', () => {
  const result = normalizeFoodLabel({
    found: true,
    productName: '  Soup  ',
    ingredients: [' water ', 42, null, '', 'salt'],
    claims: ['Low Sodium', { text: 'organic' }],
    containsStatement: '   ',
    fullText: '  Soup.  ',
  });
  assert.equal(result.productName, 'Soup');
  assert.deepEqual(result.ingredients, ['water', 'salt']);
  assert.deepEqual(result.claims, ['Low Sodium']);
  assert.equal(result.containsStatement, null, 'blank statements become null');
  assert.equal(result.fullText, 'Soup.');
});

test('the response shape matches the Swift Codable mirror key for key', () => {
  const result = parseModelOutput(soupJSON);
  assert.deepEqual(Object.keys(result).sort(), [
    'claims',
    'containsStatement',
    'expiration',
    'found',
    'fullText',
    'ingredients',
    'mayContainStatement',
    'nutrients',
    'preparation',
    'productName',
    'servingSize',
    'servingsPerContainer',
  ]);
  assert.deepEqual(Object.keys(result.nutrients).sort(), [
    'addedSugarsG',
    'calories',
    'cholesterolMg',
    'dietaryFiberG',
    'phosphorusMg',
    'potassiumMg',
    'proteinG',
    'saturatedFatG',
    'sodiumMg',
    'totalCarbohydrateG',
    'totalFatG',
    'totalSugarsG',
    'transFatG',
  ]);
});

test('the prompt carries the essentials: null over guess, per-serving column, units as printed, JSON only', () => {
  assert.match(PROMPT, /over 60/);
  assert.match(PROMPT, /null/);
  assert.match(PROMPT, /wrong sodium number is worse than a missing one/);
  assert.match(PROMPT, /per-serving/i);
  assert.match(PROMPT, /units as printed/i);
  assert.match(PROMPT, /found false/);
  assert.match(PROMPT, /ONLY a JSON object, no markdown fences/);
});

test('the diet rules are never part of the prompt or the response shape', () => {
  // The backend transcribes; the phone judges. Nothing here should know or
  // ask about the wearer's own limits.
  assert.doesNotMatch(PROMPT, /profile|the wearer's limit|their limit/i);
  for (const key of Object.keys(FALLBACK)) {
    assert.doesNotMatch(key, /profile|limit|verdict|fit/i, key);
  }
});
