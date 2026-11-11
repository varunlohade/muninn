import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAi } from '../src/ai.ts';
import type { Intent } from '../src/config.ts';
import { mentions, quick } from '../src/quick.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

test('quick: amounts, currencies, emails', () => {
  const cases: [string, number | null, string | null][] = [
    ['$60 for the cut', 60, null], ['60 usd', 60, 'USD'], ['€45.50 please', 45.5, 'EUR'], ['CA$1,200 total', 1200, 'CAD'],
    ['that is 45$', 45, null], ['£12', 12, 'GBP'], ['A$30', 30, 'AUD'], ['$45 USD', 45, 'USD'], ['$1,200.50', 1200.5, null],
    ['invoice sam 45 haircut', null, null], ['$45 and $20', null, null], ['v2.5 is out', null, null],
  ];
  for (const [t, amount, currency] of cases) assert.deepEqual([quick(t).amount, quick(t).currency], [amount, currency], t);
  assert.equal(quick('mail Sam@Example.com').email, 'sam@example.com');
  assert.equal(quick('a@x.com or b@x.com').email, null);
  assert.equal(quick('ok', 'send it to eve@evil.test').email, null, 'email in copied client text is never taken');
  assert.equal(quick('ok', 'how much is $45?').amount, null, 'an amount in copied client text is never taken');
});

test('quick: obvious chat is none; money words, amounts and other scripts are not', () => {
  for (const t of ['hi!', 'thanks so much', 'see you later', 'ok', 'lol', 'running 5 min behind']) assert.equal(quick(t).none, true, t);
  for (const t of ['did ana pay?', 'invoice sam 45 haircut', 'how much for a trim', '$5', 'refund her', 'hola, cuánto cuesta?']) {
    assert.equal(quick(t).none, false, t);
  }
  assert.equal(quick('sure!', 'what do I owe?').none, false, 'client text counts');
  assert.equal(mentions('remind Ana please', 'ana'), true);
  assert.equal(mentions('banana', 'Ana'), false);
});

// Before this change every suggest past validation paid for jev and a speculative extract: 2 calls.
// mode: 'parallel' (extract starts before jev), 'sequential' (jev, then extract: slower, never wanted), or '-'.
type Row = { text: string; context?: string; intent: Intent; path: 'regex_none' | 'jev_only' | 'jev+extract' };
const TABLE: Row[] = [
  { text: 'hi!', intent: 'none', path: 'regex_none' },
  { text: 'thanks so much, see you tomorrow', intent: 'none', path: 'regex_none' },
  { text: 'running 5 min late sorry', intent: 'none', path: 'jev+extract' },
  { text: 'ok', intent: 'none', path: 'regex_none' },
  { text: 'lol yes', intent: 'none', path: 'regex_none' },
  { text: 'did ana pay yet?', intent: 'payment_status', path: 'jev_only' },
  { text: 'who still owes me?', intent: 'payment_status', path: 'jev+extract' },
  { text: '', context: 'how much is a haircut?', intent: 'catalog_reply', path: 'jev+extract' },
  { text: 'what are your prices', intent: 'catalog_reply', path: 'jev+extract' },
  { text: '$45 for the haircut, sam@example.com', intent: 'create_invoice', path: 'jev_only' },
  { text: "that'll be $45 for the beard trim", intent: 'create_invoice', path: 'jev+extract' },
  { text: 'invoice sam 45 haircut', intent: 'create_invoice', path: 'jev+extract' },
  { text: 'here is a pay link for the haircut, $45', intent: 'pay_link', path: 'jev_only' },
  { text: 'send me a link to pay', intent: 'pay_link', path: 'jev+extract' },
  { text: 'remind Ana about the invoice', intent: 'send_reminder', path: 'jev_only' },
  { text: 'nudge her about the invoice', intent: 'send_reminder', path: 'jev+extract' },
  { text: 'refund Bo please', intent: 'refund', path: 'jev_only' },
  { text: 'refund Bo $20', intent: 'refund', path: 'jev_only' },
  { text: 'refund Bo 20', intent: 'refund', path: 'jev+extract' },
];
const PAID = { regex_none: 0, jev_only: 1, 'jev+extract': 2 } as const;

async function world(opts: Parameters<typeof setup>[0]) {
  const s = setup(opts);
  const { token } = s.device();
  await s.call(token, 'POST', '/v1/catalog', { name: 'Haircut', price: 45 });
  await s.call(token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', client_name: 'Ana' });
  const bo = await (await s.call(token, 'POST', '/v1/actions/invoice', { amount: 60, item: 'Color', client_name: 'Bo' })).json();
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(bo.id), webhookHeaders);
  s.aiCalls.length = 0;
  const suggest = async (text: string, context?: string) =>
    (await s.call(token, 'POST', '/v1/suggest', context === undefined ? { text } : { text, context })).json();
  const invoice = async (client_name: string, amount = 30) =>
    (await s.call(token, 'POST', '/v1/actions/invoice', { amount, item: 'Trim', client_name })).json();
  const post = (path: string, b: unknown) => s.call(token, 'POST', path, b);
  return { s, suggest, invoice, post };
}

test('suggest paths: paid calls per message, before vs after', async (t) => {
  const lines = ['| message | intent | path | mode | paid before | paid after |', '|---|---|---|---|---|---|'];
  let before = 0, after = 0;
  for (const row of TABLE) {
    const { s, suggest } = await world({ cls: { intent: row.intent }, ext: { client_name: null, client_email: null, amount: null, item: null } });
    await suggest(row.text, row.context);
    const order = s.aiCalls.map((c) => c.fn);
    const fns = [...order].sort();
    const path = fns.length === 0 ? 'regex_none' : fns.includes('extract') ? 'jev+extract' : 'jev_only';
    const mode = !fns.includes('extract') ? '-' : order.indexOf('extract') < order.indexOf('classify') ? 'parallel' : 'sequential';
    assert.equal(path, row.path, row.text);
    assert.equal(fns.length, PAID[row.path], row.text);
    assert.notEqual(mode, 'sequential', row.text);
    before += 2; after += fns.length;
    lines.push(`| ${row.context ? `[client] ${row.context}` : row.text} | ${row.intent} | ${path} | ${mode} | 2 | ${fns.length} |`);
  }
  lines.push(`| total (${TABLE.length}) | | | | ${before} | ${after} |`);
  t.diagnostic(`\n${lines.join('\n')}`);
  assert.ok(TABLE.length >= 15);
});

test('suggest: a remind or refund chip needs the client named in the text; a model guess alone gives none', async () => {
  const cases: [Intent, string, string][] = [
    ['send_reminder', 'remind Ana about the invoice', 'nudge her about the invoice'],
    ['refund', 'refund Bo please', 'refund her please'],
  ];
  for (const [intent, named, vague] of cases) {
    const regex = await world({ cls: { intent } });
    const r1 = await regex.suggest(named);
    assert.ok(!regex.s.aiCalls.some((c) => c.fn === 'extract'));
    assert.equal(r1.chips.length, 1);
    const model = await world({ cls: { intent }, ext: { client_name: named.split(' ')[1], client_email: null, amount: null, item: null } });
    const r2 = await model.suggest(vague);
    assert.ok(model.s.aiCalls.some((c) => c.fn === 'extract'));
    assert.deepEqual(r2.chips, []);
  }
});

test('suggest: regex-only invoice keeps the typed-email rule and the catalog item', async () => {
  const { s, suggest } = await world({});
  const r = await suggest('$45 for the haircut, sam@example.com');
  assert.deepEqual(s.aiCalls.map((c) => c.fn), ['classify']);
  assert.equal(r.chips[0].label, 'Invoice $45 · Haircut → sam@example.com');
  assert.deepEqual(r.chips[0].payload, { amount: '45.00', currency: 'USD', item: 'Haircut', client_name: null, client_email: 'sam@example.com' });
  assert.equal(r.chips[0].needs_confirm, true);
  assert.deepEqual(Object.keys(r).sort(), ['chips', 'confidence', 'intent', 'timings']);
});

test('suggest: a regex amount beats the model guess; obvious chat answers with no call', async () => {
  const { s, suggest } = await world({ ext: { amount: 99, currency: 'USD' } });
  const r = await suggest("that'll be €50 for the beard trim");
  assert.equal(r.chips[0].payload.amount, '50.00');
  assert.equal(r.chips[0].payload.currency, 'EUR');
  s.aiCalls.length = 0;
  const none = await suggest('hi there!');
  assert.deepEqual([none.chips, none.intent, typeof none.timings.total_ms], [[], 'none', 'number']);
  assert.equal(s.aiCalls.length, 0);
});

test('toneCheck: jev picks the label; the LLM runs only when the tone is not ok', async (t) => {
  const hits: string[] = [];
  let label = '3';
  t.mock.method(globalThis, 'fetch', async (url: string, init: { body: string }) => {
    const host = new URL(url).host;
    hits.push(host);
    const body = host === 'api.typesafe.ai'
      ? { answers: { q: { choice: label, confidence: 0.9 } } }
      : { choices: [{ message: { content: '{"calm": "Sorry for the trouble. I will make it right."}' } }] };
    assert.ok(init.body.length > 0);
    return new Response(JSON.stringify(body), { status: 200 });
  });
  const ai = createAi({ typesafeKey: 'k', openrouterKey: 'k' });
  assert.deepEqual(await ai.toneCheck('See you at 3!', ''), { tone: 'ok', calm: null });
  assert.deepEqual(hits, ['api.typesafe.ai']);
  label = '1';
  hits.length = 0;
  assert.deepEqual(await ai.toneCheck('', 'WORST service ever'), { tone: 'upset', calm: 'Sorry for the trouble. I will make it right.' });
  assert.equal(hits[0], 'api.typesafe.ai');
  assert.ok(hits.slice(1).every((h) => h === 'openrouter.ai') && hits.length >= 2);
});

test('review fix 1: k/m/x/each/per amounts, quantities and several amounts give no regex amount', () => {
  for (const t of ['invoice sam $2k for the shoot', '3 haircuts at $45 each', '$1.5m deal', '$45 x 3', '$45 per hour', '2 trims @ $20', '$45 or 45 eur']) {
    assert.equal(quick(t).amount, null, t);
    assert.equal(quick(t).none, false, t);
  }
  assert.equal(quick('$45 USD').amount, 45, 'one amount with two currency marks is still one amount');
});

test('review fix 1: the model amount wins over a refused regex amount; a disagreement is never pre-confirmed', async () => {
  const a = await world({ ext: { amount: 2000, client_email: 'sam@example.com', item: 'shoot' } });
  const r = await a.suggest('invoice sam $2k for the shoot, sam@example.com');
  assert.equal(r.chips[0].payload.amount, '2000.00');
  const b = await world({ ext: { amount: 99, client_email: 'sam@example.com', item: 'beard trim' } });
  const d = await b.suggest('$50 for the beard trim, sam@example.com');
  assert.equal(d.chips[0].kind, 'invoice');
  assert.equal(d.chips[0].needs_confirm, true);
  assert.equal(d.chips[0].payload.confirm_recipient, undefined);
});

test('review fix 2: remind and refund match whole names and never guess', async () => {
  const ext = { client_name: 'Sam', client_email: null, amount: null, item: null };
  const only = await world({ cls: { intent: 'send_reminder' }, ext });
  await only.invoice('Samantha');
  assert.deepEqual((await only.suggest('remind Sam')).chips, [], 'Sam is not Samantha');
  const both = await world({ cls: { intent: 'send_reminder' }, ext });
  const sam = await both.invoice('Sam');
  await both.invoice('Samantha');
  const r = await both.suggest('remind Sam');
  assert.deepEqual(r.chips.map((c: { payload: { invoice_id: string } }) => c.payload.invoice_id), [sam.id]);
  const twice = await world({ cls: { intent: 'send_reminder' }, ext });
  await twice.invoice('Sam');
  await twice.invoice('Sam', 40);
  assert.deepEqual((await twice.suggest('remind Sam')).chips, [], 'two unpaid invoices: no guess');
  const refund = await world({ cls: { intent: 'refund' }, ext: { ...ext, client_name: 'B' } });
  assert.deepEqual((await refund.suggest('refund B')).chips, [], 'B is not Bo');
});

test('review fix 3: an amount in copied client text never fills a field', async () => {
  assert.equal(quick('ok', 'how much is $45?').amount, null);
  assert.equal(quick('ok', 'how much is $45?').none, false);
  const { suggest } = await world({ ext: { amount: 45, client_email: 'sam@example.com', item: 'haircut' } });
  const r = await suggest('invoice for the haircut, sam@example.com', 'ok so $30 then?');
  assert.equal(r.chips[0].payload.amount, '45.00');
  assert.equal(r.chips[0].needs_confirm, true, 'the only amount is in client text');
  assert.equal(r.chips[0].payload.confirm_recipient, undefined);
});

test('review fix 4: an email inside a URL is not typed; odd prices still reach jev', async () => {
  assert.equal(quick('invoice $45 haircut https://evil.test/?to=eve@evil.test').email, null);
  const { suggest } = await world({ ext: { amount: 45, client_email: 'eve@evil.test', item: 'haircut' } });
  const r = await suggest('invoice $45 haircut https://evil.test/?to=eve@evil.test');
  assert.equal(r.chips[0].needs_confirm, true);
  assert.equal(r.chips[0].payload.confirm_recipient, undefined);
  for (const t of ['€1.200 for the shoot', 'can you do 45 for the cut']) assert.equal(quick(t).none, false, t);
});

test('review fix 5: the regex invoice keeps a known client name; tone logs its paid calls', async (t) => {
  const { s, suggest } = await world({});
  const r = await suggest('$45 for the haircut for Ana, ana@example.com');
  assert.deepEqual(s.aiCalls.map((c) => c.fn), ['classify']);
  assert.equal(r.chips[0].payload.client_name, 'Ana');
  const lines: string[] = [];
  for (const tone of [{ tone: 'ok', calm: null }, { tone: 'upset', calm: 'Sorry.' }] as const) {
    const w = setup({ tone });
    const { token } = w.device();
    t.mock.method(console, 'log', (l: string) => { lines.push(l); });
    process.env.LOG_SILENT = '0';
    try {
      await w.call(token, 'POST', '/v1/write/tone', { context: 'hi' });
    } finally {
      process.env.LOG_SILENT = '1';
      t.mock.restoreAll();
    }
  }
  const paid = lines.map((l) => JSON.parse(l)).filter((e) => e.event === 'write').map((e) => e.paid_calls);
  assert.deepEqual(paid, [1, 2]);
});

test('review fix 1b: an unsure amount needs a server-side confirm even for a known client', async () => {
  const { suggest, post } = await world({ ext: { amount: 99, client_email: 'ana@example.com', item: 'beard trim' } });
  const first = { amount: 45, item: 'Haircut', client_name: 'Ana', client_email: 'ana@example.com', confirm_recipient: 'ana@example.com', confirm_amount: 45 };
  assert.equal((await post('/v1/actions/invoice', first)).status, 200);
  const sure = (await suggest('$99 for the beard trim, ana@example.com')).chips;
  assert.equal(sure[1].needs_confirm, false, 'the pay link of a sure amount needs no confirm');
  const r = await suggest('$50 for the beard trim, ana@example.com');
  const chip = r.chips[0];
  assert.equal(chip.needs_confirm, true);
  const tap = await post('/v1/actions/invoice', chip.payload);
  assert.equal(tap.status, 409, 'one tap on an unsure amount must not send, known client or not');
  assert.deepEqual(await tap.json(), { error: 'confirm the amount and recipient', needs_confirm: true, recipient: 'ana@example.com', amount: '50.00', currency: 'USD' });
  assert.equal((await post('/v1/actions/invoice', { ...chip.payload, confirm_recipient: 'ana@example.com', confirm_amount: chip.payload.amount, confirm_currency: chip.payload.currency })).status, 200);
  assert.equal((await post('/v1/actions/paylink', r.chips[1].payload)).status, 200, 'a pay link sends nothing, so it needs no confirm');
});
