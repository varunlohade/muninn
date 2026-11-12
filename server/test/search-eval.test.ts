// Eval: typed phrases from five kinds of business, each with the client or item the lookup chip must find, or null for
// "no lookup chip". It runs the real /v1/suggest with the fake model, whose router never says "lookup", so it measures
// the free regex path alone. Targets: precision >= 95% (a wrong chip is worse than none), recall >= 90%.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { BUSINESSES, seeded } from './search-fixtures.ts';

type Case = [text: string, want: string | null];
const EVAL: Record<keyof typeof BUSINESSES, Case[]> = {
  salon: [
    ['invoice for sam', 'Sam Lee'], ["sam's invoice", 'Sam Lee'], ['did sam pay', 'Sam Lee'], ['what does sam owe', 'Sam Lee'],
    ['hey did sam ever pay lol', 'Sam Lee'], ['invocie for sam', 'Sam Lee'], ['sams invoce', 'Sam Lee'], ["Sam's invoice from last week", 'Sam Lee'],
    ['the $120 one for sam', 'Sam Lee'], ['Did Sam pay?', 'Sam Lee'], ["what's sam's balance", 'Sam Lee'], ['pull up the latest invoice for sam lee', 'Sam Lee'],
    ['has jordan paid yet?', 'Jordan Ray'], ['did jordn pay', 'Jordan Ray'], ['any invoice for jordan?', 'Jordan Ray'],
    ['invoice for samanta', 'Samantha Cruz'], ['did samantha pay', 'Samantha Cruz'],
    ["ana lopez's last booking", 'Ana Lopez'], ['last order from ana', 'Ana Lopez'], ["ana's booking", 'Ana Lopez'],
    ["show me bo's receipt", 'Bo Chen'], ['is bo paid up?', 'Bo Chen'], ['whats the last bill for bo', 'Bo Chen'],
    ['price of balayage', null], ['how much is a haircut', null],
    ['sam is here', null], ['sam said hi', null], ['invoice template ideas', null], ["i'll pay sam tomorrow", null],
    ['invoice sam $45 for a haircut', null], ['invoice for sam for $45', null], ['send the invoice to sam', null], ['sam paid me today', null],
    ['thanks sam, see you next week', null], ['can sam come in at 3', null], ['samantha loved her color', null],
  ],
  restaurant: [
    ['last order from maria', 'Maria Gomez'], ["maria's table", 'Maria Gomez'], ['what did maria order last time', 'Maria Gomez'],
    ['did mria pay', 'Maria Gomez'], ['did theo pay', 'Theo Park'], ['what does theo owe', 'Theo Park'], ['invoice for theo park', 'Theo Park'],
    ['delivery for kenji', 'Kenji Sato'], ["kenji's order", 'Kenji Sato'], ['has kenji paid', 'Kenji Sato'], ['order for kenji pls', 'Kenji Sato'],
    ['price of pad thai', null], ['how much is the tasting menu', null],
    ['table for two at 7', null], ['maria booked a table for 4', null], ['the delivery guy is late', null], ['order more rice', null],
    ['kenji says the pad thai was great', null], ['can you send me the menu', null], ['theo wants to pay by card', null],
  ],
  tutor: [
    ['last session with leo', 'Leo Martins'], ["leo's invoice", 'Leo Martins'], ['did leo pay for the session', 'Leo Martins'],
    ['what does leo owe', 'Leo Martins'], ['leo martins invoice', 'Leo Martins'], ['does noor owe me anything', 'Noor Haddad'],
    ["noor's receipt", 'Noor Haddad'], ["priya's lessons", 'Priya Shah'], ['invoice for priya', 'Priya Shah'],
    ['price of sat class', null], ['how much for a math session', null],
    ['leo has a test friday', null], ['session moved to 4pm', null], ['noor did great today', null], ['class is cancelled tomorrow', null],
    ["i'll invoice priya later", null], ['can leo pay next week', null],
  ],
  contractor: [
    ["dave's invoice from last week", 'Dave Miller'], ["dave's quote", 'Dave Miller'], ['invoice for dave miller', 'Dave Miller'],
    ["dave's $500 invoice", 'Dave Miller'], ['what does dave owe', 'Dave Miller'], ['did dave pay the deposit', 'Dave Miller'],
    ['did rosa pay', 'Rosa Diaz'], ['job for rosa', 'Rosa Diaz'], ['estimate for ellis', 'Ellis Grant'], ['hourly labor price', null],
    ['dave needs a quote for the bathroom', null], ['quote for a new deck', null], ['rosa wants to pay in cash', null], ['job starts monday', null],
    ["i'll send dave the invoice tonight", null], ['invoice template for contractors', null],
  ],
  shop: [
    ["chloe's order", 'Chloe Kim'], ['did chloe kim pay', 'Chloe Kim'], ['did marcus pay', 'Marcus Bell'], ['last order from marcus', 'Marcus Bell'],
    ['did markus pay', 'Marcus Bell'], ["zoe's receipt", 'Zoe Adams'], ['order for zoe adams', 'Zoe Adams'],
    ['price of the lamp', null], ['how much is a mug', null],
    ['order shipped today', null], ['chloe loved the mug', null], ['zoe asked about returns', null], ['the lamp is back in stock', null],
    ['marcus will pay later', null], ['delivery takes 3 days', null],
  ],
};

type Score = { total: number; positives: number; tp: number; fp: number; fn: number; tn: number; precision: number; recall: number; misses: string[] };

async function score(cases: { biz: keyof typeof BUSINESSES; text: string; want: string | null }[]): Promise<Score> {
  let tp = 0, fp = 0, fn = 0, tn = 0;
  const misses: string[] = [];
  const worlds = new Map<string, ReturnType<typeof seeded>>();
  for (const { biz, text, want } of cases) {
    if (!worlds.has(biz)) worlds.set(biz, seeded(BUSINESSES[biz]));
    const chip = await worlds.get(biz)!.lookup(text);
    const got: string | undefined = chip?.payload.candidates[0]?.name;
    if (want === null) {
      if (chip) { fp++; misses.push(`FALSE CHIP ${biz}: "${text}" → ${chip.label}`); } else tn++;
    } else if (got === want) tp++;
    else if (chip) { fp++; fn++; misses.push(`WRONG ${biz}: "${text}" → ${chip.label}`); }
    else { fn++; misses.push(`MISSED ${biz}: "${text}"`); }
  }
  for (const [biz, w] of worlds) assert.deepEqual(w.s.calls, [], `${biz}: a lookup never calls PayPal`);
  const positives = cases.filter((c) => c.want !== null).length;
  return { total: cases.length, positives, tp, fp, fn, tn, precision: tp / (tp + fp), recall: tp / (tp + fn), misses };
}

const report = (t: { diagnostic(m: string): void }, s: Score) => {
  t.diagnostic(`phrases ${s.total}: positives ${s.positives}, negatives ${s.total - s.positives}`);
  t.diagnostic(`tp ${s.tp} fp ${s.fp} fn ${s.fn} tn ${s.tn} precision ${(s.precision * 100).toFixed(1)}% recall ${(s.recall * 100).toFixed(1)}%`);
  for (const m of s.misses) t.diagnostic(m);
};

test('search eval: precision and recall over typed phrases from five businesses', async (t) => {
  const cases = (Object.entries(EVAL) as [keyof typeof BUSINESSES, Case[]][]).flatMap(([biz, list]) => list.map(([text, want]) => ({ biz, text, want })));
  const s = await score(cases);
  report(t, s);
  assert.ok(s.total >= 80, `at least 80 phrases, got ${s.total}`);
  assert.ok(s.precision >= 0.95, `precision ${s.precision}`);
  assert.ok(s.recall >= 0.9, `recall ${s.recall}`);
});

// Held out: 60 phrases another agent wrote from the client lists alone, without seeing these rules. Reported, and held
// to the precision target only: a missed lookup costs a tap, a false chip costs trust.
test('search eval, held out: precision over phrases written blind', async (t) => {
  const cases = JSON.parse(readFileSync(new URL('./search-heldout.json', import.meta.url), 'utf8'));
  const s = await score(cases);
  report(t, s);
  assert.ok(s.precision >= 0.95, `precision ${s.precision}`);
});
