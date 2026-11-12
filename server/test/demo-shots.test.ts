import { test } from 'node:test';
import assert from 'node:assert/strict';
import { demoShots, ensureDemoUser, seedDemo } from '../src/seed.ts';
import { setup } from './helpers.ts';

const suggest = async (s: ReturnType<typeof setup>, token: string, text: string) =>
  (await (await s.call(token, 'POST', '/v1/suggest', { text })).json()) as { chips: any[]; intent: string };

test('shots: "bill ana $40 every month" and friends give a repeat bill chip, not an invoice', async () => {
  const s = setup({ cls: { intent: 'create_invoice' } });
  const { token } = s.device();
  for (const text of ['bill ana $40 every month', 'charge ana 40 monthly']) {
    const out = await suggest(s, token, text);
    assert.deepEqual(out.chips.map((c) => [c.kind, c.label, c.needs_confirm]), [['subscribe', 'Bill $40/mo · Ana', true]], text);
    assert.deepEqual(out.chips[0].payload, { amount: '40.00', currency: 'USD', interval: 'month', item: 'Repeat payment', client_name: 'Ana', client_email: null });
  }
  assert.equal(s.aiCalls.length, 0, 'regex only');
  // The bare "ana $40 a month" needs Ana to be a known client; "rent $1200 monthly" is never a bill.
  assert.equal((await suggest(s, token, 'rent $1200 monthly')).chips.some((c) => c.kind === 'subscribe'), false);
  await s.call(token, 'POST', '/v1/actions/invoice', { amount: 90, item: 'Color', client_name: 'Ana' });
  assert.deepEqual((await suggest(s, token, 'ana $40 a month')).chips.map((c) => c.label), ['Bill $40/mo · Ana']);
});

test('shots: pause, resume and cancel name Ana\'s plan; with no plan a hint, never silence', async () => {
  const s = setup();
  const { token, userId } = s.device();
  for (const t of ["pause ana's plan", "resume ana's plan", "stop ana's plan for good"]) {
    assert.deepEqual((await suggest(s, token, t)).chips.map((c) => [c.kind, c.label]), [['show', 'Ana has no repeat bill']], t);
  }
  s.db.insertSubscription({ id: 'I-ANA0001', user_id: userId, status: 'ACTIVE', amount_cents: 4000, currency: 'USD', interval: 'month', item: 'Repeat payment',
    client_name_enc: s.cipher.encrypt(userId, 'Ana'), client_email_enc: null, approve_link: null, plan_id: 'P-1', created_at: 1 });
  assert.deepEqual((await suggest(s, token, "pause ana's plan")).chips.map((c) => c.label), ['Pause $40/mo · Ana']);
  assert.deepEqual((await suggest(s, token, "stop ana's plan for good")).chips.map((c) => c.label), ['Cancel $40/mo · Ana']);
  s.db.setSubscriptionStatus(userId, 'I-ANA0001', 'SUSPENDED');
  assert.deepEqual((await suggest(s, token, "resume ana's plan")).chips.map((c) => c.label), ['Resume $40/mo · Ana']);
});

test('shots: "refund sam $20" gives a Refund chip on a captured payment, else a plain hint', async () => {
  const s = setup({ cls: { intent: 'refund' }, ext: { client_name: 'Sam', client_email: null, amount: 20, item: null } });
  const { token, userId } = s.device();
  assert.deepEqual((await suggest(s, token, 'refund sam $20')).chips.map((c) => [c.kind, c.label]), [['show', 'No paid payment from Sam to refund']]);
  s.db.insertOrder({ id: 'ORDER-SAM', user_id: userId, status: 'CREATED', amount_cents: 4500, currency: 'USD', item: 'Haircut',
    client_name_enc: s.cipher.encrypt(userId, 'Sam Okafor'), approve_link: 'l', created_at: 1 });
  s.db.setOrderStatus(userId, 'ORDER-SAM', 'COMPLETED', 2, 'CAP-SAM');
  assert.deepEqual((await suggest(s, token, 'refund sam $20')).chips.map((c) => [c.kind, c.label]), [['refund', 'Refund $20 · Sam Okafor']]);
});

test('shots: several open invoices: the chip takes the latest and names it; the list stays second', async () => {
  const s = setup();
  const { token, userId } = s.device();
  const add = (id: string, cents: number, item: string, at: number) => s.db.insertInvoice({ id, user_id: userId, status: 'SENT', amount_cents: cents, currency: 'USD', item,
    client_name_enc: s.cipher.encrypt(userId, 'Sam'), client_email_enc: s.cipher.encrypt(userId, 'sam@x.com'), pay_link: 'l', due_at: at + 1, created_at: at });
  add('INV2-OLD1', 60000, 'Brand kit', Date.parse('2026-11-01T10:00:00Z'));
  add('INV2-NEW1', 4500, 'Haircut', Date.parse('2026-11-10T10:00:00Z'));
  const mark = (await suggest(s, token, 'mark sam paid')).chips;
  assert.deepEqual(mark.map((c) => [c.kind, c.label]), [['invoice_mark_paid', 'Mark paid $45 · Sam'], ['show', 'Sam has 2 open invoices']]);
  assert.equal(mark[0].payload.question, "Mark Sam's $45 Haircut invoice (Nov 10) paid? No money moves.");
  const cancel = (await suggest(s, token, "cancel sam's invoice")).chips;
  assert.equal(cancel[0].label, 'Cancel invoice $45 · Sam');
  assert.equal(cancel[0].payload.question, "Cancel Sam's $45 Haircut invoice (Nov 10)? PayPal tells Sam. Can't undo.");
});

test('shots: an invoice with no typed reason is for "Services"', async () => {
  const s = setup({ cls: { intent: 'create_invoice' }, ext: { client_name: 'Sam', client_email: 'sam@x.com', amount: 45, item: null } });
  const { token } = s.device();
  const out = await suggest(s, token, 'invoice sam $45 sam@x.com');
  assert.equal(out.chips[0].payload.item, 'Services');
});

test('shots: the demo setup dry run calls no PayPal and writes nothing', async () => {
  const s = setup();
  const { userId } = ensureDemoUser(s.db);
  await seedDemo({ db: s.db, cipher: s.cipher, paypal: s.mockPayPal, userId, now: Date.parse('2026-11-12T10:00:00Z') });
  const before = s.calls.length;
  const count = () => ['invoices', 'orders', 'subscriptions'].map((t) => (s.db.raw.prepare(`SELECT COUNT(*) AS n FROM ${t}`).get() as { n: number }).n);
  const rows = count();
  const lines = await demoShots({ db: s.db, cipher: s.cipher, paypal: s.mockPayPal, userId, now: Date.now(), dryRun: true });
  assert.equal(s.calls.length, before, 'no PayPal call');
  assert.deepEqual(count(), rows, 'no row written');
  assert.ok(lines.every((l) => l.startsWith('DRY ')));
  assert.ok(lines.some((l) => /would cancel .* Brand kit/.test(l)), lines.join('\n'));
  console.log(lines.join('\n'));

  // A real run makes the invoice, the pay link and the plan, and a re-run reuses them.
  await demoShots({ db: s.db, cipher: s.cipher, paypal: s.mockPayPal, userId, now: Date.now(), dryRun: false });
  const again = await demoShots({ db: s.db, cipher: s.cipher, paypal: s.mockPayPal, userId, now: Date.now(), dryRun: false });
  assert.match(again[0], /^sam invoice: ok/);
  assert.ok(again.some((l) => /^sam payment: (ok|captured)/.test(l)), again.join('\n'));
  assert.ok(again.some((l) => /^ana plan: .*ACTIVE/.test(l)), again.join('\n'));
});
