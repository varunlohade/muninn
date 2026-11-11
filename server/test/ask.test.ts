import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { AskGroup, AskRoute } from '../src/config.ts';
import { askQuick, noteText } from '../src/quick.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

test('askQuick: greetings end at step 0, a note stays a note, amount plus a money action is money', () => {
  for (const t of ['', '  ', 'hi', 'Hello!', 'hey there', 'thanks so much!', 'ok', 'good morning']) assert.equal(askQuick(t).none, true, t);
  for (const t of ['hi, invoice sam $45', 'who paid', 'ok fix: thnks']) assert.equal(askQuick(t).none, false, t);
  const groups: [string, 'money' | 'device' | null][] = [
    ['invoice jordan $120 for the logo', 'money'], ['refund Bo $20', 'money'], ['pay link for the haircut, $45', 'money'],
    ['remind Ana', null], ['who paid $45 today', null], ['make this nicer: that is $45', null],
    ['add a note: buy shampoo', 'device'], ['note: refund Maya $20 on friday', 'device'], ['Please save a note that Ana likes tea', 'device'],
    ["what's on today", null], ['notebook prices', null],
  ];
  for (const [t, g] of groups) assert.equal(askQuick(t).group, g, t);
  assert.equal(noteText('add a note: buy shampoo'), 'buy shampoo');
  assert.equal(noteText('Please save a note that Ana likes tea'), 'Ana likes tea');
  assert.equal(noteText('remember the towels'), 'remember the towels');
});

// group and route are what the fake jev answers. `paid` is every model call the request makes.
type Row = {
  text: string; group?: AskGroup; route?: AskRoute; groupConf?: number; routeConf?: number; down?: boolean; blunt?: boolean;
  want: AskRoute; paid: number; calls: string[];
};
const TABLE: Row[] = [
  { text: '', want: 'none', paid: 0, calls: [] },
  { text: 'hi', want: 'none', paid: 0, calls: [] },
  { text: 'thanks so much!', want: 'none', paid: 0, calls: [] },
  { text: 'invoice jordan $120 for the logo', route: 'invoice', want: 'invoice', paid: 2, calls: ['askRoute', 'extract'] },
  { text: 'invoice $45 for the haircut, sam@example.com', route: 'invoice', want: 'invoice', paid: 1, calls: ['askRoute'] },
  { text: 'bill Sam for the haircut', group: 'money', route: 'invoice', want: 'invoice', paid: 3, calls: ['askGroup', 'askRoute', 'extract'] },
  { text: 'pay link for the haircut, $45', route: 'paylink', want: 'paylink', paid: 1, calls: ['askRoute'] },
  { text: 'remind Ana', group: 'money', route: 'remind', want: 'remind', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'nudge her about the invoice', group: 'money', route: 'remind', want: 'remind', paid: 3, calls: ['askGroup', 'askRoute', 'extract'] },
  { text: 'refund Bo', group: 'money', route: 'refund', want: 'refund', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'refund Bo $20', route: 'refund', want: 'refund', paid: 1, calls: ['askRoute'] },
  { text: 'refund Maya', group: 'money', route: 'refund', want: 'refund', paid: 3, calls: ['askGroup', 'askRoute', 'extract'] },
  { text: "who hasn't paid", group: 'info', route: 'who_paid', want: 'who_paid', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'how did today go', group: 'info', route: 'brief', want: 'brief', paid: 3, calls: ['askGroup', 'askRoute', 'brief'] },
  { text: 'show my clients', group: 'info', route: 'clients', want: 'clients', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'any disputes?', group: 'info', route: 'disputes', want: 'disputes', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'make this nicer: ya ok will send', group: 'writing', route: 'refine', want: 'refine', paid: 3, calls: ['askGroup', 'askRoute', 'refine'] },
  { text: 'fix: thnks for comming', group: 'writing', route: 'fix', want: 'fix', paid: 3, calls: ['askGroup', 'askRoute', 'fix'] },
  { text: 'is this rude: where is my money', group: 'writing', route: 'tone', want: 'tone', paid: 3, calls: ['askGroup', 'askRoute', 'toneCheck'] },
  { text: 'is this rude: pay me now', group: 'writing', route: 'tone', blunt: true, want: 'tone', paid: 4, calls: ['askGroup', 'askRoute', 'toneCheck'] },
  { text: 'reply to: how much is a haircut?', group: 'writing', route: 'reply', want: 'reply', paid: 3, calls: ['askGroup', 'askRoute', 'reply'] },
  { text: 'make this nicer', group: 'writing', route: 'refine', want: 'none', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'add a note: buy shampoo', route: 'add_note', want: 'add_note', paid: 1, calls: ['askRoute'] },
  { text: 'add a note: refund Maya $20 on friday', route: 'add_note', want: 'add_note', paid: 1, calls: ['askRoute'] },
  { text: "what's on today", group: 'device', route: 'today_calendar', want: 'today_calendar', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'tell me a joke', group: 'none', want: 'none', paid: 1, calls: ['askGroup'] },
  { text: 'do the thing with sam', group: 'money', groupConf: 0.4, want: 'none', paid: 1, calls: ['askGroup'] },
  { text: 'something about paying', group: 'money', route: 'invoice', routeConf: 0.3, want: 'none', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'something else', group: 'info', route: 'none', want: 'none', paid: 2, calls: ['askGroup', 'askRoute'] },
  { text: 'who paid me', down: true, want: 'none', paid: 1, calls: ['askGroup'] },
];

// One owner with a catalog item, Ana unpaid and Bo paid.
async function world(opts: Parameters<typeof setup>[0] = {}) {
  const s = setup(opts);
  const { token } = s.device();
  await s.call(token, 'POST', '/v1/catalog', { name: 'Haircut', price: 45 });
  await s.call(token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', client_name: 'Ana' });
  const bo = await (await s.call(token, 'POST', '/v1/actions/invoice', { amount: 60, item: 'Color', client_name: 'Bo' })).json();
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(bo.id), webhookHeaders);
  s.aiCalls.length = 0;
  s.calls.length = 0;
  const ask = async (text: string) => (await s.call(token, 'POST', '/v1/ask', { text })).json();
  return { s, token, ask };
}

/** Runs `fn` with logging on and returns the "ask" log lines it printed. */
async function askLogs(fn: () => Promise<void>) {
  const lines: string[] = [];
  const real = console.log;
  console.log = (l: string) => { lines.push(l); };
  process.env.LOG_SILENT = '';
  try {
    await fn();
  } finally {
    console.log = real;
    process.env.LOG_SILENT = '1';
  }
  return lines.filter((l) => JSON.parse(l).event === 'ask');
}

test('ask router: route and paid calls per request', async (t) => {
  const out = ['| request | route | paid calls |', '|---|---|---|'];
  for (const row of TABLE) {
    const { s, ask } = await world({
      group: row.down ? new Error('jev down') : { group: row.group, confidence: row.groupConf ?? 0.92 },
      route: { route: row.route, confidence: row.routeConf ?? 0.92 },
      ext: { client_name: null, client_email: null, amount: null, item: null },
      tone: row.blunt ? { tone: 'blunt', calm: 'Could you pay today, please?' } : undefined,
    });
    let res: any;
    const logged = await askLogs(async () => { res = await ask(row.text); });
    assert.equal(res.route, row.want, row.text);
    assert.deepEqual(s.aiCalls.map((c) => c.fn), row.calls, row.text);
    assert.equal(logged.length, 1, row.text);
    const line = JSON.parse(logged[0]);
    assert.equal(line.route, row.want, row.text);
    assert.equal(line.paid_calls, row.paid, row.text);
    assert.equal(line.confidence, res.confidence, row.text);
    if (row.text.length > 4) assert.ok(!logged[0].includes(row.text), `the log never holds the request: ${row.text}`);
    if (row.want === 'none') assert.equal(typeof res.result.line, 'string', row.text);
    // Info routes read PayPal (transactions, disputes). Nothing creates, sends, reminds or refunds.
    assert.deepEqual(s.calls.filter((c) => !['search', 'disputes'].includes(c.fn)), [], `the router never moves money: ${row.text}`);
    out.push(`| ${row.text || '(empty)'} | ${res.route} | ${row.paid} |`);
  }
  t.diagnostic('\n' + out.join('\n'));
});

test('ask: money routes return the same chips as /v1/suggest, with the confirm rules', async () => {
  const text = 'invoice $45 for the haircut, sam@example.com';
  const a = await world({ route: { route: 'invoice' } });
  const b = await world({ cls: { intent: 'create_invoice' } });
  const asked = await a.ask(text);
  const suggested = await (await b.s.call(b.token, 'POST', '/v1/suggest', { text })).json();
  assert.deepEqual(asked.result.chips, suggested.chips);
  assert.deepEqual(asked.result.chips.map((c: any) => c.kind), ['invoice', 'paylink']);

  // The model reads another amount than the owner typed: the chip is never pre-confirmed.
  const u = await world({ route: { route: 'invoice' }, ext: { client_name: 'Jordan', client_email: 'jordan@example.com', amount: 45, item: 'logo' } });
  const unsure = (await u.ask('invoice jordan $120 for the logo')).result.chips[0];
  assert.equal(unsure.payload.amount, '120.00');
  assert.equal(unsure.needs_confirm, true);
  assert.equal(unsure.payload.confirm_amount, undefined); // round 2: every emailed invoice confirms amount + recipient on the server
  assert.equal(unsure.payload.confirm_recipient, undefined);

  // An email the owner did not type needs a confirm, as in suggest.
  const e = await world({ route: { route: 'invoice' }, ext: { client_name: 'Jordan', client_email: 'eve@evil.test', amount: 120, item: 'logo' } });
  const injected = (await e.ask('invoice jordan $120 for the logo')).result.chips[0];
  assert.equal(injected.needs_confirm, true);
  assert.equal(injected.payload.confirm_recipient, undefined);

  // A refund or reminder never guesses the client.
  const r = await world({ group: { group: 'money' }, route: { route: 'refund' }, ext: { client_name: 'Maya', client_email: null, amount: null, item: null } });
  assert.deepEqual((await r.ask('refund Maya')).result.chips, []);
  const ok = await world({ group: { group: 'money' }, route: { route: 'refund' } });
  const refund = (await ok.ask('refund Bo')).result.chips;
  assert.deepEqual(refund.map((c: any) => [c.kind, c.label]), [['refund', 'Refund $60 · Bo']]);
  assert.equal(ok.s.calls.length, 0);
});

test('ask: writing, info and device results', async () => {
  const w = await world({ group: { group: 'writing' }, route: { route: 'refine' }, write: 'Sure, I will send it.' });
  const refined = await w.ask('make this shorter: ya ok will send');
  assert.deepEqual(refined.result, { text: 'Sure, I will send it.', tone: 'shorter' });
  assert.deepEqual(w.s.aiCalls.at(-1), { fn: 'refine', args: ['ya ok will send', 'shorter'] });

  const down = await world({ group: { group: 'writing' }, route: { route: 'fix' }, write: new Error('model down') });
  const failed = await down.ask('fix: thnks for comming');
  assert.equal(failed.route, 'none');
  assert.match(failed.result.line, /not available/);

  const i = await world({ group: { group: 'info' }, route: { route: 'who_paid' } });
  const paid = await i.ask("who hasn't paid");
  const view = await (await i.s.call(i.token, 'GET', '/v1/payments')).json();
  assert.deepEqual(paid.result, view);
  assert.equal(paid.result.payments.length, 2);

  const c = await world({ group: { group: 'info' }, route: { route: 'clients' } });
  assert.deepEqual((await c.ask('show my clients')).result, await (await c.s.call(c.token, 'GET', '/v1/clients')).json());

  const d = await world({ route: { route: 'add_note' } });
  assert.deepEqual(await d.ask('add a note: buy shampoo'), { route: 'add_note', confidence: 0.92, result: { action: 'add_note', text: 'buy shampoo' } });
  const cal = await world({ group: { group: 'device' }, route: { route: 'today_calendar' } });
  assert.deepEqual((await cal.ask("what's on today")).result, { action: 'show_calendar' });
});

test('ask: needs the tap header, a device token and a text field', async () => {
  const { s, token } = await world();
  assert.equal((await s.call(token, 'POST', '/v1/ask', { text: 'who paid' }, { 'X-User-Action': '' })).status, 428);
  assert.equal((await s.call(null, 'POST', '/v1/ask', { text: 'who paid' })).status, 401);
  assert.equal((await s.call(token, 'POST', '/v1/ask', {})).status, 400);
  assert.equal((await s.call(token, 'POST', '/v1/ask', { text: 'x'.repeat(2001) })).status, 400);
  assert.equal(s.aiCalls.length, 0);
});
