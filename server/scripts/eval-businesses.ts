// Live eval: the business matrix through the real /v1/suggest with the real models (jev + OpenRouter).
// In-process app, in-memory DB, PayPal mocked. About 3 in 10 messages are held out: tune prompts on train only.
//   node --env-file=../.env scripts/eval-businesses.ts [train|test|all]
import { createAi } from '../src/ai.ts';
import { BUSINESSES, describe, fits, heldOut, wantText, type Business, type Msg } from '../test/business-matrix-data.ts';
import { openMatrix } from '../test/business-matrix-harness.ts';

const split = (process.argv[2] ?? 'all') as 'train' | 'test' | 'all';
const MAX_CALLS = 300;
const typesafeKey = process.env.TYPESAFE_API_KEY;
const openrouterKey = process.env.OPENROUTER_API_KEY;
if (!typesafeKey || !openrouterKey) {
  console.log('No TYPESAFE_API_KEY or OPENROUTER_API_KEY: skipping the live eval.');
  process.exit(0);
}

// Every paid call goes through fetch: count them, and stop at the cap.
let calls = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = (async (...args: Parameters<typeof fetch>) => {
  if (++calls > MAX_CALLS) throw new Error('call cap reached');
  return realFetch(...args);
}) as typeof fetch;

const m = await openMatrix(createAi({ typesafeKey, openrouterKey }));
type Row = { b: Business; msg: Msg; test: boolean; ok: boolean; got: string };
const rows: Row[] = [];

async function run(b: Business) {
  await m.open(b);
  for (const msg of b.msgs) {
    const test = heldOut(b, msg);
    if ((split === 'train' && test) || (split === 'test' && !test)) continue;
    let got = 'error';
    let ok = false;
    try {
      const chips = await m.ask(b, msg);
      got = describe(chips);
      ok = fits(chips, msg.want);
    } catch (e) {
      got = `error: ${(e as Error).message.slice(0, 60)}`;
    }
    rows.push({ b, msg, test, ok, got });
  }
}

// A few businesses at a time: each one's messages run in order.
const queue = [...BUSINESSES];
await Promise.all(Array.from({ length: 4 }, async () => { for (let b; (b = queue.shift());) await run(b); }));

const pct = (r: Row[]) => (r.length ? `${r.filter((x) => x.ok).length}/${r.length}` : '-');
const pad = (s: string, n: number) => s.padEnd(n);
console.log(`\n${pad('business', 16)} ${pad('train', 7)} ${pad('held-out', 8)}`);
for (const b of BUSINESSES) {
  const r = rows.filter((x) => x.b === b);
  console.log(`${pad(b.id, 16)} ${pad(pct(r.filter((x) => !x.test)), 7)} ${pad(pct(r.filter((x) => x.test)), 8)}`);
}
const train = rows.filter((x) => !x.test);
const test = rows.filter((x) => x.test);
const share = (r: Row[]) => (r.length ? `${Math.round((100 * r.filter((x) => x.ok).length) / r.length)}%` : '-');
console.log(`${pad('ALL', 16)} ${pad(pct(train), 7)} ${pad(pct(test), 8)}   train ${share(train)}, held-out ${share(test)}, paid calls ${Math.min(calls, MAX_CALLS)}`);

console.log('\nMisses (expected → got):');
for (const r of rows.filter((x) => !x.ok)) {
  console.log(`  [${r.test ? 'held-out' : 'train'}] ${r.b.id}: "${r.msg.say}" (${r.msg.from}) → want ${r.msg.want.map(wantText).join(' | ')}; got ${r.got}`);
}
