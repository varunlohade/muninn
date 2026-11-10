import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { ExtractionSchema, parseModelJson } from '../src/ai.ts';
import { createCipher, randomToken } from '../src/crypto.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

test('crypto: round trip, random IV, tamper detection, cross-user swap fails', () => {
  const c = createCipher(randomBytes(32));
  const a = c.encrypt('user-a', 'sam@example.com');
  assert.equal(c.decrypt('user-a', a), 'sam@example.com');
  assert.notEqual(c.encrypt('user-a', 'sam@example.com'), a);
  assert.ok(!a.includes('sam'));
  const raw = Buffer.from(a.split(':')[1], 'base64');
  raw[raw.length - 1] ^= 1;
  assert.throws(() => c.decrypt('user-a', `v1:${raw.toString('base64')}`));
  assert.throws(() => c.decrypt('user-b', a));
});

test('auth: missing or unknown token is rejected', async () => {
  const { call } = setup();
  assert.equal((await call(null, 'GET', '/v1/payments')).status, 401);
  assert.equal((await call(randomToken('pkd'), 'GET', '/v1/payments')).status, 401);
  assert.equal((await call('garbage', 'POST', '/v1/suggest', { text: 'hi' })).status, 401);
  assert.equal((await call(null, 'GET', '/health')).status, 200);
});

test('money: bad amounts are rejected before PayPal is called', async () => {
  const { call, calls, device } = setup();
  const { token } = device();
  for (const amount of [-5, 0, '0.00', 10000.01, 1.234, 'abc', '1e3', null]) {
    const r = await call(token, 'POST', '/v1/actions/invoice', { amount, item: 'Haircut' });
    assert.equal(r.status, 400, `amount ${amount}`);
  }
  assert.equal((await call(token, 'POST', '/v1/actions/paylink', { amount: 45, item: 'x', currency: 'XYZ' })).status, 400);
  assert.equal(calls.length, 0);
  assert.equal((await call(token, 'POST', '/v1/actions/invoice', { amount: '10000', item: 'Big job' })).status, 200);
});

test('actions: default-deny without a tap header; idempotency key replays', async () => {
  const { call, calls, device } = setup();
  const { token } = device();
  const r = await call(token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut' }, { 'X-User-Action': '' });
  assert.equal(r.status, 428);
  const h = { 'Idempotency-Key': 'same-key-123' };
  const a = await (await call(token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut' }, h)).json();
  const b = await (await call(token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut' }, h)).json();
  assert.equal(a.id, b.id);
  assert.equal(calls.filter((c) => c.fn === 'invoice').length, 1);
});

test('suggest: invoice chip from text, no auto-run, low confidence gives no chips', async () => {
  const s = setup();
  const { token } = s.device();
  const r = await (await s.call(token, 'POST', '/v1/suggest', { text: "thanks! that'll be $45 for the haircut, sam@example.com" })).json();
  assert.equal(r.chips[0].kind, 'invoice');
  assert.equal(r.chips[0].label, 'Invoice $45 · Haircut → sam@example.com');
  assert.equal(r.chips[0].needs_confirm, false);
  assert.deepEqual(r.chips[0].payload, { amount: '45.00', currency: 'USD', item: 'Haircut', client_name: 'Sam', client_email: 'sam@example.com', confirm_recipient: 'sam@example.com' });
  assert.ok(typeof r.timings.total_ms === 'number');
  assert.equal(s.calls.length, 0);

  const low = setup({ cls: { confidence: 0.3 } });
  const t2 = low.device().token;
  assert.deepEqual((await (await low.call(t2, 'POST', '/v1/suggest', { text: 'that is $45' })).json()).chips, []);

  const bad = setup({ ext: { amount: 99999 } });
  const t3 = bad.device().token;
  assert.deepEqual((await (await bad.call(t3, 'POST', '/v1/suggest', { text: 'that is $99999' })).json()).chips, []);
});

test('suggest: jev and extraction run in parallel', async () => {
  const s = setup({ delayMs: 150 });
  const { token } = s.device();
  const t = performance.now();
  const r = await (await s.call(token, 'POST', '/v1/suggest', { text: "that'll be $45 for the haircut" })).json();
  assert.equal(r.chips.length, 2);
  assert.ok(performance.now() - t < 280, `took ${performance.now() - t} ms`);
});

test('extraction parsing: fences, "null" strings, string numbers', () => {
  const v = ExtractionSchema.parse(parseModelJson('```json\n{"client": "null", "client_name": "null", "client_email": "", "amount": "$45.00", "currency": "usd", "item": "haircut"}\n```'));
  assert.deepEqual(v, { client_name: null, client_email: null, amount: 45, currency: 'USD', item: 'haircut' });
  assert.equal(ExtractionSchema.parse({ amount: 'lots' }).amount, null);
});

test('storage: client name and email are ciphertext in SQLite', async () => {
  const { call, db, device } = setup();
  const { token } = device();
  await call(token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', client_name: 'Sam Lee', client_email: 'sam@example.com', confirm_recipient: 'sam@example.com' });
  const row = db.raw.prepare('SELECT * FROM invoices').get() as Record<string, unknown>;
  assert.ok(String(row.client_email_enc).startsWith('v1:'));
  assert.ok(!JSON.stringify(row).includes('sam@example.com'));
  assert.ok(!JSON.stringify(row).includes('Sam Lee'));
});

test('per-user isolation: B cannot read, list, remind or refund A data (404)', async () => {
  const s = setup();
  const A = s.device();
  const B = s.device();
  const inv = await (await s.call(A.token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', client_name: 'Sam' })).json();
  const item = (await (await s.call(A.token, 'POST', '/v1/catalog', { name: 'Haircut', price: 45 })).json()).item;
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv.id), webhookHeaders);

  assert.equal((await (await s.call(B.token, 'GET', '/v1/payments')).json()).payments.length, 0);
  assert.equal((await (await s.call(B.token, 'GET', '/v1/catalog')).json()).items.length, 0);
  assert.equal((await s.call(B.token, 'POST', '/v1/actions/remind', { invoice_id: inv.id })).status, 404);
  assert.equal((await s.call(B.token, 'POST', '/v1/actions/refund', { id: inv.id })).status, 404);
  assert.equal((await s.call(B.token, 'PUT', `/v1/catalog/${item.id}`, { name: 'Mine', price: 1 })).status, 404);
  assert.equal((await s.call(B.token, 'DELETE', `/v1/catalog/${item.id}`)).status, 404);
  assert.deepEqual((await (await s.call(B.token, 'GET', '/v1/summary')).json()).earned_today, {});

  const step1 = await (await s.call(A.token, 'POST', '/v1/actions/refund', { id: inv.id })).json();
  assert.equal((await s.call(B.token, 'POST', '/v1/actions/refund', { confirm_token: step1.confirm_token })).status, 404);
  assert.equal(s.calls.filter((c) => c.fn === 'refund' || c.fn === 'remind').length, 0);

  const row = s.db.raw.prepare('SELECT client_name_enc FROM invoices WHERE id = ?').get(inv.id) as { client_name_enc: string };
  assert.equal(s.cipher.decrypt(A.userId, row.client_name_enc), 'Sam');
  assert.throws(() => s.cipher.decrypt(B.userId, row.client_name_enc));
});

test('refund: two steps, token works once, unpaid cannot be refunded', async () => {
  const s = setup();
  const { token } = s.device();
  const inv = await (await s.call(token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut' })).json();
  assert.equal((await s.call(token, 'POST', '/v1/actions/refund', { id: inv.id })).status, 409);
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv.id), webhookHeaders);
  assert.equal((await s.call(token, 'POST', '/v1/actions/refund', { id: inv.id, amount: 46 })).status, 400);
  const step1 = await (await s.call(token, 'POST', '/v1/actions/refund', { id: inv.id, amount: '20.50' })).json();
  assert.match(step1.summary, /Refund \$20\.50/);
  assert.equal(s.calls.filter((c) => c.fn === 'refund').length, 0);
  const done = await (await s.call(token, 'POST', '/v1/actions/refund', { confirm_token: step1.confirm_token })).json();
  assert.equal(done.refund_id, 'REF1');
  assert.deepEqual(s.calls.find((c) => c.fn === 'refund')!.args.slice(0, 3), ['CAPX', '20.50', 'USD']);
  assert.equal((await s.call(token, 'POST', '/v1/actions/refund', { confirm_token: step1.confirm_token })).status, 404);
});

test('webhook: bad signature rejected, unknown ids ignored, paid shows in summary', async () => {
  const bad = setup({ verify: false });
  assert.equal((await bad.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-X'), webhookHeaders)).status, 401);
  assert.equal((await bad.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-X'))).status, 401);

  const s = setup();
  const { token } = s.device();
  assert.equal((await (await s.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-UNKNOWN'), webhookHeaders)).json()).handled, false);
  const inv = await (await s.call(token, 'POST', '/v1/actions/invoice', { amount: '45.50', item: 'Haircut' })).json();
  let p = (await (await s.call(token, 'GET', '/v1/payments')).json()).payments;
  assert.equal(p[0].state, 'unpaid');
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv.id), webhookHeaders);
  p = (await (await s.call(token, 'GET', '/v1/payments')).json()).payments;
  assert.equal(p[0].state, 'paid');
  const sum = await (await s.call(token, 'GET', '/v1/summary')).json();
  assert.deepEqual(sum.earned_today, { USD: '45.50' });
  assert.equal(sum.unpaid_count, 0);
});

test('limits: oversized body rejected', async () => {
  const s = setup();
  const { token } = s.device();
  const r = await s.call(token, 'POST', '/v1/suggest', { text: 'x'.repeat(20_000) });
  assert.equal(r.status, 413);
});
