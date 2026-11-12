// Live eval: natural money requests and normal chat through the real /v1/suggest with the real models (jev + OpenRouter).
// In-process app, in-memory DB, PayPal mocked. Each business is its own owner with its own "what does your business do".
//   node --env-file=../.env scripts/eval-natural.ts [--cache <file.json>] [--only <id,id>]
// --cache replays a model answer already seen for the very same request body, so a re-run pays only for new prompts.
import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createAi } from '../src/ai.ts';
import { createApp } from '../src/app.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import type { PayPalPartner } from '../src/paypal.ts';
import { EVAL, negativeOk, scorePositive, type EvalBusiness } from '../test/natural-eval-data.ts';
import { paidEvent, setup, webhookHeaders } from '../test/helpers.ts';

const arg = (k: string) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : undefined; };
const cacheFile = arg('--cache');
const only = arg('--only')?.split(',');
const MAX_CALLS = 160;
const typesafeKey = process.env.TYPESAFE_API_KEY;
const openrouterKey = process.env.OPENROUTER_API_KEY;
if (!typesafeKey || !openrouterKey) {
  console.log('No TYPESAFE_API_KEY or OPENROUTER_API_KEY: skipping the live eval.');
  process.exit(0);
}

const cache: Record<string, unknown> = cacheFile && existsSync(cacheFile) ? JSON.parse(readFileSync(cacheFile, 'utf8')) : {};
let live = 0;
let replayed = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = (async (url: string | URL | Request, init?: RequestInit) => {
  const key = sha256(`${String(url)}\n${String(init?.body ?? '')}`);
  if (cacheFile && key in cache) {
    replayed++;
    return new Response(JSON.stringify(cache[key]), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  if (++live > MAX_CALLS) throw new Error('call cap reached');
  const res = await realFetch(url, init);
  if (!res.ok || !cacheFile) return res;
  const json = await res.json();
  cache[key] = json;
  return new Response(JSON.stringify(json), { status: 200, headers: { 'Content-Type': 'application/json' } });
}) as typeof fetch;

const noPartner: PayPalPartner = {
  async createReferral() { throw new Error('no partner'); },
  async merchantStatus() { return null; },
  async merchantIdForTracking() { return null; },
};
const pp = setup().mockPayPal;
const db = openDb(':memory:');
const app = createApp({ db, cipher: createCipher(randomBytes(32)), ai: createAi({ typesafeKey, openrouterKey }), paypal: { forUser: () => pp, forAccount: () => pp, platform: () => pp, partner: () => noPartner } });
let k = 0;
async function call(token: string | null, method: string, path: string, body: unknown) {
  const r = await app.request(path, {
    method,
    headers: {
      'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(path.startsWith('/v1/actions') ? { 'X-User-Action': 'tap', 'Idempotency-Key': `natural-${++k}` } : {}),
      ...(path === '/webhooks/paypal' ? webhookHeaders : {}),
    },
    body: JSON.stringify(body),
  });
  const json = await r.json() as any;
  if (r.status !== 200) throw new Error(`${method} ${path} → ${r.status} ${JSON.stringify(json)}`);
  return json;
}

async function open(b: EvalBusiness) {
  const userId = db.createUser();
  const token = randomToken('pkd');
  db.addDevice(userId, sha256(token), 'eval');
  if (b.description) await call(token, 'PUT', '/v1/profile/business', { description: b.description });
  if (b.unpaid) await call(token, 'POST', '/v1/actions/invoice', { amount: 40, currency: 'USD', item: 'Earlier job', client_name: b.unpaid });
  if (b.paid) {
    const paid = await call(token, 'POST', '/v1/actions/invoice', { amount: 60, currency: 'USD', item: 'Earlier job', client_name: b.paid });
    await call(null, 'POST', '/webhooks/paypal', paidEvent(paid.id));
  }
  return token;
}

type Row = { b: string; say: string; pos: boolean; ok: boolean; shown: boolean; fields?: string; got: string; ms: number; path?: string };
const rows: Row[] = [];
for (const b of EVAL) {
  if (only && !only.includes(b.id)) continue;
  const token = await open(b);
  const ask = async (say: string) => {
    const before = live;
    const res = await call(token, 'POST', '/v1/suggest', { text: say }).catch((e) => ({ chips: [], error: (e as Error).message, timings: {} }));
    return { chips: res.chips ?? [], ms: Number(res.timings?.total_ms ?? -1), fresh: live > before, err: res.error };
  };
  for (const pos of b.pos) {
    const r = await ask(pos.say);
    const s = scorePositive(pos, r.chips);
    const bad = (['amount', 'client', 'reason'] as const).filter((f) => s.shown && !s[f]);
    rows.push({ b: b.id, say: pos.say, pos: true, ok: s.ok, shown: s.shown, fields: bad.join(','), got: r.err ?? s.got, ms: r.fresh ? r.ms : -1 });
  }
  for (const say of b.neg) {
    const r = await ask(say);
    const ok = negativeOk(r.chips);
    rows.push({ b: b.id, say, pos: false, ok, shown: !ok, got: r.err ?? (r.chips.map((c: any) => `${c.kind}:${c.label}`).join(' | ') || 'none'), ms: r.fresh ? r.ms : -1 });
  }
}
if (cacheFile) writeFileSync(cacheFile, JSON.stringify(cache));

const pos = rows.filter((r) => r.pos);
const neg = rows.filter((r) => !r.pos);
const shownPos = pos.filter((r) => r.shown);
const falsePos = neg.filter((r) => !r.ok);
const correct = pos.filter((r) => r.ok);
const pct = (a: number, b: number) => (b ? `${a}/${b} (${Math.round((100 * a) / b)}%)` : '-');
console.log('\nPositives:');
console.log(`  chip shown        ${pct(shownPos.length, pos.length)}`);
console.log(`  all fields right  ${pct(correct.length, pos.length)}`);
for (const f of ['amount', 'client', 'reason']) console.log(`  wrong ${f.padEnd(10)} ${shownPos.filter((r) => r.fields?.includes(f)).length}`);
console.log('Negatives:');
console.log(`  no money chip     ${pct(neg.length - falsePos.length, neg.length)}`);
console.log(`  precision (correct chips / all money chips shown) ${pct(correct.length, shownPos.length + falsePos.length)}`);
const ms = rows.map((r) => r.ms).filter((m) => m >= 0).sort((a, b) => a - b);
const q = (p: number) => ms[Math.min(ms.length - 1, Math.floor(p * ms.length))];
if (ms.length) console.log(`Server time on live answers (n=${ms.length}): p50 ${q(0.5)} ms, p90 ${q(0.9)} ms, max ${ms[ms.length - 1]} ms`);
console.log(`Model calls: ${live} live, ${replayed} replayed from cache`);
console.log('\nMisses:');
for (const r of rows.filter((x) => !x.ok)) console.log(`  [${r.b}] ${r.pos ? 'POS' : 'NEG'} "${r.say}"${r.fields ? ` wrong:${r.fields}` : ''} → ${r.got}`);
