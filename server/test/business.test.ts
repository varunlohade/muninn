import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkBrief } from '../src/business.ts';
import { DEMO_INVOICES, ensureDemoUser, seedDemo, todaySpecs } from '../src/seed.ts';
import type { PayPalDisputeDetail, PayPalTxn } from '../src/paypal.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

const DAY = 86_400_000;
const T0 = Date.UTC(2026, 10, 12, 15); // Thursday; the week starts Monday Nov 9, the month Nov 1.
const iso = (t: number) => new Date(t).toISOString().slice(0, 19) + 'Z';
const txn = (id: string, at: number, value: string, fee: string | null, extra: Partial<PayPalTxn> = {}): PayPalTxn => ({
  id, event_code: 'T0006', date: iso(at), status: 'S', amount: { value, currency: 'USD' }, fee: fee ? { value: fee, currency: 'USD' } : null,
  payer_name: 'Maya Lopez', payer_email: 'Maya@Example.com', invoice_id: null, subject: null, ...extra,
});
const dispute = (id: string, status = 'WAITING_FOR_SELLER_RESPONSE'): PayPalDisputeDetail => ({
  id, status, reason: 'MERCHANDISE_OR_SERVICE_NOT_RECEIVED', amount: { value: '60.00', currency: 'USD' },
  due_date: iso(T0 + 1 * DAY), created_at: iso(T0 - 2 * DAY), stage: 'INQUIRY', buyer_name: 'Maya Lopez', transaction_id: 'TX1', messages: [],
});

function world() {
  let t = T0;
  const s = setup({ now: () => t });
  return { ...s, A: s.device(), B: s.device(), clock: { get: () => t, set: (v: number) => { t = v; } } };
}
const get = async (s: ReturnType<typeof world>, token: string, path: string) => {
  const r = await s.call(token, 'GET', path);
  return { status: r.status, json: await r.json() as any };
};

test('integrations: PayPal and supplier payouts connected with encrypted config, others coming soon; per user', async () => {
  const s = world();
  const { json } = await get(s, s.A.token, '/v1/integrations');
  const byId = Object.fromEntries(json.integrations.map((i: any) => [i.id, i]));
  assert.equal(byId.paypal.status, 'connected');
  assert.ok(byId.paypal.capabilities.includes('transactions'));
  assert.equal(byId.paypal.description, 'Demo PayPal (sandbox)');
  for (const id of ['stripe', 'square', 'gmail']) assert.equal(byId[id], undefined);
  assert.equal(byId.contacts.status, 'on_device');
  assert.equal(byId.contacts.description, "Pick a client's email from your contacts. Stays on this phone.");
  for (const id of ['slack', 'google_reviews']) assert.equal(byId[id].status, 'not_connected');
  assert.equal(byId.paypal_payouts.status, 'connected', 'payouts go through the PayPal connection');
  for (const id of ['reminders', 'calendly', 'google_calendar', 'shopify']) {
    assert.equal(byId[id].status, 'coming_soon');
    assert.equal(byId[id].connected_at, null);
  }
  const row = s.db.raw.prepare('SELECT config_enc FROM integrations WHERE user_id = ?').get(s.A.userId) as { config_enc: string };
  assert.ok(row.config_enc.startsWith('v1:') && !row.config_enc.includes('platform'));
  assert.match(s.cipher.decrypt(s.A.userId, row.config_enc), /platform_merchant/);
  assert.throws(() => s.cipher.decrypt(s.B.userId, row.config_enc));

  const n = (u: string) => (s.db.raw.prepare('SELECT COUNT(*) AS n FROM integrations WHERE user_id = ?').get(u) as { n: number }).n;
  assert.equal(n(s.B.userId), 0);
  await get(s, s.B.token, '/v1/integrations');
  assert.equal(n(s.B.userId), 1);
  assert.equal((await s.call(null, 'GET', '/v1/integrations')).status, 401);
});

test('transactions: PayPal rows normalized, non-payments dropped, linked invoice, ranges, cache', async () => {
  const s = world();
  const inv = (await (await s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: 120, item: 'Color', client_name: 'Jordan' })).json()).id;
  s.db.setInvoiceStatus(s.A.userId, inv, 'PAID', T0 - DAY, 'CAP-INV');
  s.ppData.set(s.A.userId, {
    txns: [
      txn('TX-TODAY', T0 - 3600_000, '100.00', '-3.49'),
      txn('CAP-INV', T0 - DAY, '120.00', '-4.09', { payer_name: 'Jordan Ray', payer_email: 'jordan@example.com' }),
      txn('TX-MONTH', Date.UTC(2026, 10, 2), '50.00', '-1.75'),
      txn('BAL', T0 - DAY, '5000.00', null, { event_code: 'T1900', subject: 'Initial balance' }),
    ],
  });
  const today = (await get(s, s.A.token, '/v1/transactions?range=today')).json;
  assert.equal(today.source, 'paypal');
  assert.deepEqual(today.transactions.map((x: any) => x.id), ['TX-TODAY']);
  assert.deepEqual(today.transactions[0], {
    id: 'TX-TODAY', date: iso(T0 - 3600_000), amount: '100.00', fee: '3.49', net: '96.51', currency: 'USD',
    payer_name: 'Maya Lopez', payer_email: 'maya@example.com', status: 'COMPLETED', invoice_id: null, order_id: null, source: 'paypal', kind: 'paypal_transaction',
  });
  const week = (await get(s, s.A.token, '/v1/transactions?range=week')).json.transactions;
  assert.deepEqual(week.map((x: any) => x.id), ['TX-TODAY', 'CAP-INV']);
  assert.equal(week[1].invoice_id, inv);
  assert.equal((await get(s, s.A.token, '/v1/transactions?range=month')).json.transactions.length, 3);
  assert.equal((await get(s, s.A.token, '/v1/transactions?range=year')).status, 400);

  const searches = () => s.calls.filter((c) => c.fn === 'search').length;
  assert.equal(searches(), 1, 'cached for 60 s');
  s.clock.set(T0 + 61_000);
  await get(s, s.A.token, '/v1/transactions');
  assert.equal(searches(), 2);
});

test('transactions: empty or failing PayPal search falls back to our paid invoices, marked local', async () => {
  const s = world();
  const inv = (await (await s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: '45.50', item: 'Haircut', client_name: 'Sam', client_email: 'sam@example.com', confirm_recipient: 'sam@example.com', confirm_amount: '45.50' })).json()).id;
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv), webhookHeaders);
  const r = (await get(s, s.A.token, '/v1/transactions?range=today')).json;
  assert.equal(r.source, 'local');
  assert.equal(r.note, 'paypal_empty');
  assert.deepEqual(r.transactions.map((x: any) => [x.invoice_id, x.amount, x.fee, x.net, x.payer_name, x.payer_email, x.source]),
    [[inv, '45.50', null, null, 'Sam', 'sam@example.com', 'local']]);

  s.ppData.set(s.A.userId, { txns: new Error('PayPal down') });
  s.clock.set(T0 + 61_000);
  const e = (await get(s, s.A.token, '/v1/transactions?range=today')).json;
  assert.equal(e.note, 'paypal_error');
  assert.equal(e.transactions.length, 1);
});

test('transactions: cross-user, B never sees A PayPal rows or A local fallback', async () => {
  const s = world();
  s.ppData.set(s.A.userId, { txns: [txn('TX-A', T0 - 60_000, '75.00', '-2.00')] });
  const inv = (await (await s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: 30, item: 'Trim', client_name: 'Sam' })).json()).id;
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv), webhookHeaders);
  assert.equal((await get(s, s.A.token, '/v1/transactions')).json.transactions.length, 1);
  const b = (await get(s, s.B.token, '/v1/transactions?range=month')).json;
  assert.deepEqual(b.transactions, []);
  assert.ok(s.calls.some((c) => c.fn === 'search' && c.args[0] === s.B.userId), 'B is searched with its own PayPal client');
});

async function seededA() {
  const s = world();
  s.clock.set(T0 - 11 * DAY);
  await s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: 80, item: 'Color', client_name: 'Jordan Ray', client_email: 'jordan@example.com', confirm_recipient: 'jordan@example.com', confirm_amount: 80 });
  s.clock.set(T0);
  await s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: 40, item: 'Trim', client_name: 'Sam' });
  s.ppData.set(s.A.userId, {
    txns: [txn('TX1', T0 - 3600_000, '1284.00', '-45.10'), txn('TX2', T0 - 2 * DAY, '100.00', '-3.49', { payer_name: 'Lee Park', payer_email: 'lee@example.com' })],
    disputes: [dispute('PP-D-1001'), dispute('PP-D-1002', 'RESOLVED')],
  });
  // A runs on the shared demo merchant; the disputes are on TX1, a payment A's own repeat bill took.
  s.db.raw.prepare('INSERT INTO subscription_payments (sale_id, user_id, subscription_id, paid_at) VALUES (?, ?, ?, ?)').run('TX1', s.A.userId, 'I-SUB1', T0);
  return s;
}

test('summary v2: earned, fees, net, unpaid, late and disputes from real data; B sees zeros', async () => {
  const s = await seededA();
  const a = (await get(s, s.A.token, '/v1/summary')).json;
  assert.deepEqual(a.earned_today, { USD: '1284.00' });
  assert.deepEqual(a.earned_this_week, { USD: '1384.00' });
  assert.deepEqual(a.fees_this_week, { USD: '48.59' });
  assert.deepEqual(a.net_this_week, { USD: '1335.41' });
  assert.equal(a.unpaid_count, 2);
  assert.deepEqual(a.unpaid_amount, { USD: '120.00' });
  assert.equal(a.late_count, 1);
  assert.deepEqual([a.most_late.client_name, a.most_late.days_over, a.most_late.amount], ['Jordan Ray', 4, '80.00']);
  assert.equal(a.open_disputes, 1);
  assert.equal(a.next_dispute_due.dispute_id, 'PP-D-1001');
  assert.equal(a.source, 'paypal');

  const b = (await get(s, s.B.token, '/v1/summary')).json;
  assert.deepEqual([b.earned_today, b.earned_this_week, b.unpaid_count, b.late_count, b.open_disputes, b.most_late], [{}, {}, 0, 0, 0, null]);
});

test('disputes: list and detail; B gets 404 for A dispute; bad id is 404', async () => {
  const s = await seededA();
  const list = (await get(s, s.A.token, '/v1/disputes')).json.disputes;
  assert.deepEqual(list.map((d: any) => [d.id, d.status]), [['PP-D-1001', 'WAITING_FOR_SELLER_RESPONSE'], ['PP-D-1002', 'RESOLVED']]);
  assert.deepEqual(Object.keys(list[0]).sort(), ['amount', 'created_at', 'due_date', 'id', 'reason', 'stage', 'status']);
  const one = await get(s, s.A.token, '/v1/disputes/PP-D-1001');
  assert.equal(one.status, 200);
  assert.equal(one.json.dispute.buyer_name, 'Maya Lopez');
  assert.equal((await get(s, s.B.token, '/v1/disputes/PP-D-1001')).status, 404);
  assert.deepEqual((await get(s, s.B.token, '/v1/disputes')).json.disputes, []);
  assert.equal((await get(s, s.A.token, '/v1/disputes/..%2F..%2Finvoices')).status, 404);
});

test('disputes: on the shared demo merchant a user sees and answers only disputes on their own payments', async () => {
  const s = await seededA();
  // B shares the demo merchant, so PayPal returns A's disputes to B's calls too.
  s.ppData.set(s.B.userId, s.ppData.get(s.A.userId)!);
  assert.deepEqual((await get(s, s.B.token, '/v1/disputes')).json.disputes, []);
  assert.equal((await get(s, s.B.token, '/v1/disputes/PP-D-1001')).status, 404);
  assert.equal((await get(s, s.B.token, '/v1/summary')).json.open_disputes, 0);
  const h = { 'X-User-Action': 'tap', 'Idempotency-Key': 'dispute-msg-shared' };
  assert.equal((await s.call(s.B.token, 'POST', '/v1/disputes/PP-D-1001/message', { message: 'hi there' }, h)).status, 404);
  assert.equal(s.calls.filter((c) => c.fn === 'dispute_message').length, 0);
  assert.equal((await get(s, s.A.token, '/v1/disputes')).json.disputes.length, 2);
});

test('disputes: message needs a tap and an idempotency key; B cannot message A dispute', async () => {
  const s = await seededA();
  const path = '/v1/disputes/PP-D-1001/message';
  const sent = () => s.calls.filter((c) => c.fn === 'dispute_message');
  assert.equal((await s.call(s.A.token, 'POST', path, { message: 'Shipped Tuesday, tracking attached.' })).status, 428);
  assert.equal((await s.call(s.A.token, 'POST', path, { message: 'hi' }, { 'X-User-Action': 'tap' })).status, 400);
  assert.equal(sent().length, 0);
  const h = { 'X-User-Action': 'tap', 'Idempotency-Key': 'dispute-msg-1' };
  const ok = await s.call(s.A.token, 'POST', path, { message: 'Shipped Tuesday.‮' }, h);
  assert.equal(ok.status, 200);
  assert.equal((await s.call(s.A.token, 'POST', path, { message: 'Shipped Tuesday.‮' }, h)).status, 200);
  assert.deepEqual(sent().map((c) => c.args.slice(0, 3)), [[s.A.userId, 'PP-D-1001', 'Shipped Tuesday.']]);
  assert.equal((await s.call(s.B.token, 'POST', path, { message: 'hi' }, { 'X-User-Action': 'tap', 'Idempotency-Key': 'dispute-msg-b' })).status, 404);
  assert.equal(sent().length, 1);
});

test('brief: model lines pass when every number is in the facts, else the template', async () => {
  const good = await seededA();
  const r = (await get(good, good.A.token, '/v1/brief')).json;
  assert.equal(r.source, 'ai');
  const facts = good.aiCalls.find((c) => c.fn === 'brief')!.args[0] as string;
  assert.match(facts, /\$1284/);
  assert.equal(facts, 'Earned today: $1284\nMost late invoice: Jordan, $80, 4 days over\nNext invoice due: Sam, $40, due Nov 19');
  assert.ok(!/: 0\b|disputes/.test(facts), 'zero facts are skipped');
  assert.ok(!/Ray|example\.com/.test(facts), 'only first names reach the model');

  for (const out of ['Brought back $1,300 today.', '3 invoices are late.', 'Brought back $1284 today. Jordan is 5 days over.']) {
    let t = T0;
    const s = setup({ now: () => t, brief: out });
    const A = s.device();
    s.ppData.set(A.userId, { txns: [txn('TX1', T0 - 3600_000, '1284.00', '-45.10')] });
    const b = await (await s.call(A.token, 'GET', '/v1/brief')).json() as any;
    assert.equal(b.source, 'template', out);
    assert.deepEqual(b.lines, ['Brought back $1284 today.']);
  }
  const err = setup({ brief: new Error('timeout') });
  const e = await (await err.call(err.device().token, 'GET', '/v1/brief')).json() as any;
  assert.deepEqual([e.source, e.lines], ['template', ['Quiet day so far. Nothing is late.']]);
  assert.equal(err.aiCalls.filter((c) => c.fn === 'brief').length, 0, 'no facts, no model call');
});

test('brief: cross-user, B facts carry none of A numbers or names', async () => {
  const s = await seededA();
  await get(s, s.A.token, '/v1/brief');
  const b = (await get(s, s.B.token, '/v1/brief')).json;
  assert.equal(s.aiCalls.filter((c) => c.fn === 'brief').length, 1, 'B has no facts, so only A reached the model');
  assert.ok(!/1284|Jordan|80/.test(b.lines.join(' ')));
});

test('checkBrief: digits and number words must appear in the facts', () => {
  const facts = 'Earned today: $1284\nLate invoices: 3\nMost late: Jordan, 4 days over, $80';
  assert.deepEqual(checkBrief('Brought back $1,284 today.\n3 invoices are late, Jordan is 4 days over.', facts),
    ['Brought back $1,284 today.', '3 invoices are late, Jordan is 4 days over.']);
  assert.deepEqual(checkBrief('- 3 late, Jordan owes $80.', facts), ['3 late, Jordan owes $80.']);
  assert.deepEqual(checkBrief('No one paid late fees. A few clients are new.', facts), ['No one paid late fees. A few clients are new.']);
  assert.equal(checkBrief('2 invoices are late.', facts), null);
  assert.equal(checkBrief('Jordan owes $80.01.', facts), null);
  assert.equal(checkBrief('We earned $1284 today.', facts), null);
  assert.equal(checkBrief('Our late list: 3.', facts), null);
  assert.equal(checkBrief('Brought back $1284.50 today.', facts), null);
  assert.equal(checkBrief('a\nb\nc\nd', facts), null);
  assert.equal(checkBrief('', facts), null);
});

test('clients: aggregate invoices and unlinked PayPal payers; B sees none of A clients', async () => {
  const s = await seededA();
  const inv = (await (await s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: 60, item: 'Cut', client_name: 'Maya Lopez', client_email: 'maya@example.com', confirm_recipient: 'maya@example.com', confirm_amount: 60 })).json()).id;
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv), webhookHeaders);
  const { clients, source } = (await get(s, s.A.token, '/v1/clients')).json;
  assert.equal(source, 'paypal');
  const by = Object.fromEntries(clients.map((c: any) => [c.name, c]));
  assert.deepEqual(by['Maya Lopez'].total_paid, { USD: '1344.00' });
  assert.equal(by['Maya Lopez'].visits, 2);
  assert.deepEqual(by['Maya Lopez'].channels.sort(), ['invoice', 'paypal']);
  assert.deepEqual(by['Jordan Ray'].open_amount, { USD: '80.00' });
  assert.deepEqual(by['Jordan Ray'].total_paid, {});
  assert.equal(by['Lee Park'].email, 'lee@example.com');
  assert.equal(by.Sam.visits, 0);
  assert.deepEqual((await get(s, s.B.token, '/v1/clients')).json.clients, []);
});

test('seed: 12 real-shaped invoices, 6 recorded payments, re-run is a no-op; B sees none of it', async () => {
  const s = world();
  const run = () => seedDemo({ db: s.db, cipher: s.cipher, paypal: s.mockPayPal, userId: s.A.userId, now: T0 });
  assert.deepEqual(await run(), { created: 12, recorded: 6, reused: 0 });
  assert.deepEqual(await run(), { created: 0, recorded: 0, reused: 12 });
  assert.equal(s.calls.filter((c) => c.fn === 'dated_invoice').length, DEMO_INVOICES.length);
  assert.equal(s.calls.filter((c) => c.fn === 'record_payment').length, 6);
  assert.ok(s.calls.filter((c) => c.fn === 'dated_invoice').every((c) => (c.args[0] as any).reference === 'muninn-demo-seed'));

  const sum = (await get(s, s.A.token, '/v1/summary')).json;
  assert.deepEqual(sum.earned_today, { USD: '165.00' });
  assert.equal(sum.unpaid_count, 6);
  assert.equal(sum.late_count, 3);
  assert.equal(sum.most_late.client_name, 'Leo Martins');
  assert.equal(sum.source, 'local');
  const pay = (await get(s, s.A.token, '/v1/payments')).json.payments;
  const paid = pay.filter((p: any) => p.state === 'paid');
  assert.equal(paid.length, 6);
  assert.ok(paid.every((p: any) => p.paid_via === 'recorded_payment' && p.seeded && p.origin === 'paypal_invoice'));
  const tx = (await get(s, s.A.token, '/v1/transactions?range=month')).json.transactions;
  assert.ok(tx.length > 0 && tx.every((t: any) => t.kind === 'recorded_payment'));
  assert.equal((await get(s, s.A.token, '/v1/clients')).json.clients.length, 8);
  assert.equal((await s.call(s.A.token, 'POST', '/v1/actions/refund', { id: paid[0].id })).status, 409, 'recorded payments have no capture to refund');

  assert.deepEqual((await get(s, s.B.token, '/v1/clients')).json.clients, []);
  assert.equal((await get(s, s.B.token, '/v1/summary')).json.late_count, 0);
  assert.equal((await get(s, s.B.token, '/v1/payments')).json.payments.length, 0);
});

test('seed --refresh-today: two paid-today invoices per date, idempotent, new ones the next day', async () => {
  const s = world();
  const base = { db: s.db, cipher: s.cipher, paypal: s.mockPayPal, userId: s.A.userId };
  await seedDemo({ ...base, now: T0 });
  const today = (at: number) => seedDemo({ ...base, now: at, specs: todaySpecs(at) });
  assert.deepEqual(await today(T0), { created: 2, recorded: 2, reused: 0 });
  assert.deepEqual(await today(T0 + 3600_000), { created: 0, recorded: 0, reused: 2 });
  const sum = (await get(s, s.A.token, '/v1/summary')).json;
  assert.notDeepEqual(sum.earned_today, { USD: '165.00' });
  s.clock.set(T0 + DAY);
  assert.deepEqual(await today(T0 + DAY), { created: 2, recorded: 2, reused: 0 });
  const brief = (await get(s, s.A.token, '/v1/brief')).json;
  assert.match(brief.lines[0], /^Earned today: \$\d+/);
});

test('ensureDemoUser: token only on creation, stored as a hash', () => {
  const s = world();
  const first = ensureDemoUser(s.db);
  assert.match(first.token!, /^pkd_/);
  assert.deepEqual(ensureDemoUser(s.db), { userId: first.userId, token: null });
  const rows = JSON.stringify(s.db.raw.prepare('SELECT * FROM devices').all());
  assert.ok(!rows.includes(first.token!));
});

test('clients: one person per email, best name wins, name-only rows attach; plus aliases stay apart; B sees none', async () => {
  const s = world();
  const inv = (b: Record<string, unknown>) => s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', confirm_amount: 45, ...b });
  await inv({ client_name: 'Sam' });
  await inv({ client_name: 'Sam Okafor', client_email: 'Sam.Okafor@Example.com', confirm_recipient: 'Sam.Okafor@Example.com' });
  await inv({ client_name: 'Sam', client_email: 'sam.okafor@example.com', confirm_recipient: 'sam.okafor@example.com' });
  await inv({ client_email: 'sam.okafor+work@example.com', confirm_recipient: 'sam.okafor+work@example.com' });
  const { clients } = (await get(s, s.A.token, '/v1/clients')).json;
  const sam = clients.filter((c: any) => c.email === 'sam.okafor@example.com');
  assert.equal(sam.length, 1);
  assert.equal(sam[0].name, 'Sam Okafor');
  assert.deepEqual(sam[0].open_amount, { USD: '135.00' }, 'the name-only "Sam" invoice attaches too');
  assert.deepEqual(clients.map((c: any) => c.name).sort(), ['Sam Okafor', 'sam.okafor+work']);
  assert.deepEqual((await get(s, s.B.token, '/v1/clients')).json.clients, []);
});

test('payments: missing name falls back to the known client, then the email local part, never the item', async () => {
  const s = world();
  const inv = (b: Record<string, unknown>) => s.call(s.A.token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', confirm_amount: 45, ...b });
  await inv({ client_name: 'Maya Lopez', client_email: 'maya@example.com', confirm_recipient: 'maya@example.com' });
  await inv({ client_email: 'maya@example.com', confirm_recipient: 'maya@example.com' });
  await inv({ client_email: 'lee@example.com', confirm_recipient: 'lee@example.com' });
  await inv({ client_name: 'Haircut' });
  await inv({});
  const names = (await get(s, s.A.token, '/v1/payments')).json.payments.map((p: any) => p.client_name);
  assert.deepEqual(names.sort(), [null, null, 'Maya Lopez', 'Maya Lopez', 'lee'].sort());
  assert.ok(!names.includes('Haircut'));
  assert.deepEqual((await get(s, s.B.token, '/v1/payments')).json.payments, []);
});
