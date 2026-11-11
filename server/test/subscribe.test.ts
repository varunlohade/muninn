import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createCipher } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { createPayPalProvider, PayPalError } from '../src/paypal.ts';
import { setup, subscriptionPaidEvent, webhookHeaders } from './helpers.ts';

type Sent = { method: string; path: string; body: any; requestId: string | null };

// The real PayPal client against a stub fetch that answers like the sandbox did in the spike.
function stubPayPal(subLinks = [{ rel: 'approve', href: 'https://www.sandbox.paypal.com/webapps/billing/subscriptions?ba_token=BA-1' }]) {
  const sent: Sent[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    const path = new URL(url).pathname;
    const headers = init.headers as Record<string, string>;
    sent.push({ method: String(init.method), path, body: init.body && path !== '/v1/oauth2/token' ? JSON.parse(String(init.body)) : null, requestId: headers['PayPal-Request-Id'] ?? null });
    const json = (j: unknown, status = 201) => new Response(JSON.stringify(j), { status });
    if (path === '/v1/oauth2/token') return json({ access_token: 'tok', expires_in: 3600 }, 200);
    if (path === '/v1/catalogs/products') return json({ id: 'PROD-1' });
    if (path === '/v1/billing/plans') return json({ id: 'P-1', status: 'ACTIVE' });
    if (path === '/v1/billing/subscriptions') return json({ id: 'I-ABC123', status: 'APPROVAL_PENDING', links: subLinks });
    return json({}, 404);
  }) as typeof fetch;
  const pp = createPayPalProvider({ clientId: 'id', clientSecret: 'secret' }).platform();
  return { pp, sent, restore: () => { globalThis.fetch = real; } };
}

const input = { value: '40.00', currency: 'USD', interval: 'month' as const, clientEmail: 'sam@example.com', productRequestId: 'prod-req', planRequestId: 'plan-req' };

test('createSubscription: a new user gets one product, one plan and a subscription with an approve link', async () => {
  const { pp, sent, restore } = stubPayPal();
  try {
    const out = await pp.createSubscription({ ...input, productId: null, planId: null }, 'sub-req');
    assert.deepEqual(out, { id: 'I-ABC123', status: 'APPROVAL_PENDING', approveLink: 'https://www.sandbox.paypal.com/webapps/billing/subscriptions?ba_token=BA-1', productId: 'PROD-1', planId: 'P-1' });
    const calls = sent.filter((s) => s.path !== '/v1/oauth2/token');
    assert.deepEqual(calls.map((s) => [s.path, s.requestId]), [
      ['/v1/catalogs/products', 'prod-req'], ['/v1/billing/plans', 'plan-req'], ['/v1/billing/subscriptions', 'sub-req'],
    ]);
    const plan = calls[1].body;
    assert.equal(plan.product_id, 'PROD-1');
    assert.deepEqual(plan.billing_cycles[0].frequency, { interval_unit: 'MONTH', interval_count: 1 });
    assert.deepEqual(plan.billing_cycles[0].pricing_scheme.fixed_price, { value: '40.00', currency_code: 'USD' });
    assert.equal(plan.billing_cycles[0].total_cycles, 0);
    assert.deepEqual(calls[2].body, { plan_id: 'P-1', subscriber: { email_address: 'sam@example.com' } });
  } finally {
    restore();
  }
});

test('createSubscription: known product and plan are reused, so only the subscription is created', async () => {
  const { pp, sent, restore } = stubPayPal();
  try {
    const out = await pp.createSubscription({ ...input, interval: 'week', clientEmail: null, productId: 'PROD-OLD', planId: 'P-OLD' }, 'sub-req');
    assert.equal(out.planId, 'P-OLD');
    assert.equal(out.productId, 'PROD-OLD');
    const calls = sent.filter((s) => s.path !== '/v1/oauth2/token');
    assert.deepEqual(calls.map((s) => s.path), ['/v1/billing/subscriptions']);
    assert.deepEqual(calls[0].body, { plan_id: 'P-OLD' });
  } finally {
    restore();
  }
});

test('createSubscription: no approve link is an error, never a subscription with no link', async () => {
  const { pp, restore } = stubPayPal([]);
  try {
    await assert.rejects(pp.createSubscription({ ...input, productId: 'PROD-1', planId: 'P-1' }, 'sub-req'), PayPalError);
  } finally {
    restore();
  }
});

test('subscriptions table: client fields are encrypted per user, rows are per user, plans are cached per key', () => {
  const db = openDb(':memory:');
  const cipher = createCipher(randomBytes(32));
  const a = db.createUser(), b = db.createUser();
  db.insertSubscription({
    id: 'I-1', user_id: a, status: 'APPROVAL_PENDING', amount_cents: 4000, currency: 'USD', interval: 'month', item: 'Haircut',
    client_name_enc: cipher.encrypt(a, 'Sam'), client_email_enc: cipher.encrypt(a, 'sam@example.com'), approve_link: 'https://x', plan_id: 'P-1', created_at: 1,
  });
  const raw = db.raw.prepare('SELECT client_name_enc, client_email_enc FROM subscriptions').get() as Record<string, string>;
  assert.ok(!raw.client_name_enc.includes('Sam') && !raw.client_email_enc.includes('sam@'));
  assert.equal(cipher.decrypt(a, db.getSubscription(a, 'I-1')!.client_email_enc!), 'sam@example.com');
  assert.equal(db.getSubscription(b, 'I-1'), undefined);
  assert.equal(db.ownerOfSubscription('I-1'), a);

  db.setSubscriptionActive(a, 'I-1', 10);
  db.setSubscriptionActive(a, 'I-1', 20);
  assert.equal(db.addSubscriptionPayment(a, 'I-1', 'SALE-1', 30), true);
  assert.equal(db.addSubscriptionPayment(a, 'I-1', 'SALE-1', 40), false);
  const row = db.getSubscription(a, 'I-1')!;
  assert.deepEqual([row.status, row.activated_at, row.last_paid_at, row.paid_count], ['ACTIVE', 10, 30, 1]);

  assert.equal(db.anyBillingProduct(a), null);
  db.putBillingPlan(a, 'USD:4000:month', 'PROD-1', 'P-1');
  assert.deepEqual({ ...db.getBillingPlan(a, 'USD:4000:month') }, { product_id: 'PROD-1', plan_id: 'P-1' });
  assert.equal(db.anyBillingProduct(a), 'PROD-1');
  assert.equal(db.getBillingPlan(b, 'USD:4000:month'), undefined);
});

const ok = { amount: 40, currency: 'USD', interval: 'month', item: 'Haircut', client_name: 'Sam', client_email: 'sam@example.com' };
const confirmed = { ...ok, confirm_amount: 40, confirm_currency: 'USD', confirm_interval: 'month', confirm_recipient: 'sam@example.com' };

test('subscribe: 409 until amount, currency, interval and the emailed recipient are confirmed; nothing reaches PayPal', async () => {
  const s = setup();
  const { token } = s.device();
  const bad: Record<string, unknown>[] = [
    ok,
    { ...confirmed, confirm_amount: 4 },
    { ...confirmed, confirm_currency: 'EUR' },
    { ...confirmed, confirm_interval: 'week' },
    { ...confirmed, confirm_recipient: 'eve@evil.test' },
    { ...confirmed, confirm_recipient: undefined },
    { amount: 40, interval: 'week', confirm_amount: 40, confirm_interval: 'week' },
  ];
  for (const b of bad) {
    const r = await s.call(token, 'POST', '/v1/actions/subscribe', b);
    assert.equal(r.status, 409, JSON.stringify(b));
    const j = await r.json() as any;
    assert.equal(j.needs_confirm, true);
    assert.equal(j.currency, (b.currency as string | undefined) ?? 'USD');
  }
  assert.equal(s.calls.length, 0);
  assert.equal((await s.call(token, 'POST', '/v1/actions/subscribe', { ...confirmed, interval: 'day', confirm_interval: 'day' })).status, 400);
  assert.equal((await s.call(token, 'POST', '/v1/actions/subscribe', confirmed, { 'X-User-Action': '' })).status, 428);
  assert.equal(s.calls.length, 0);
});

test('subscribe: a confirmed repeat bill returns the approve link; the row is stored encrypted for this user only', async () => {
  const s = setup();
  const a = s.device(), b = s.device();
  const r = await s.call(a.token, 'POST', '/v1/actions/subscribe', confirmed);
  assert.equal(r.status, 200);
  const j = await r.json() as any;
  assert.deepEqual({ ...j, paypal_ms: 0 }, {
    id: 'I-TEST1', status: 'APPROVAL_PENDING', approve_link: 'https://paypal.test/sub/1', amount: '40.00', currency: 'USD', interval: 'month', item: 'Haircut', paypal_ms: 0,
  });
  const [call] = s.calls;
  assert.equal(call.fn, 'subscribe');
  assert.deepEqual((call.args[0] as any), {
    value: '40.00', currency: 'USD', interval: 'month', clientEmail: 'sam@example.com', productId: null, planId: null,
    productRequestId: (call.args[0] as any).productRequestId, planRequestId: (call.args[0] as any).planRequestId,
  });
  const row = s.db.getSubscription(a.userId, 'I-TEST1')!;
  assert.equal(s.cipher.decrypt(a.userId, row.client_email_enc!), 'sam@example.com');
  assert.equal(s.db.getSubscription(b.userId, 'I-TEST1'), undefined);

  // No email: the recipient needs no confirm, the amount, currency and interval still do.
  const noEmail = { amount: 25, interval: 'week', confirm_amount: 25, confirm_currency: 'USD', confirm_interval: 'week' };
  assert.equal((await s.call(a.token, 'POST', '/v1/actions/subscribe', noEmail)).status, 200);
});

test('subscribe: one product per user, one plan per amount, interval and currency', async () => {
  const s = setup();
  const a = s.device(), b = s.device();
  const sub = async (token: string, amount: number, interval = 'month') =>
    (await s.call(token, 'POST', '/v1/actions/subscribe', { amount, interval, confirm_amount: amount, confirm_currency: 'USD', confirm_interval: interval })).status;
  assert.equal(await sub(a.token, 40), 200);
  assert.equal(await sub(a.token, 40), 200);
  assert.equal(await sub(a.token, 40, 'week'), 200);
  assert.equal(await sub(b.token, 40), 200);
  const ids = s.calls.map((c) => { const i = c.args[0] as any; return [i.productId, i.planId]; });
  assert.deepEqual(ids, [[null, null], ['PROD-TEST-1', 'P-TEST-1'], ['PROD-TEST-1', null], [null, null]]);
  const reqIds = s.calls.map((c) => (c.args[0] as any).productRequestId);
  assert.equal(reqIds[0], reqIds[2]);
  assert.notEqual(reqIds[0], reqIds[3]);
});

test('subscribe: the same key replays the stored answer with one PayPal call; lookup-only never runs it', async () => {
  const s = setup();
  const { token } = s.device();
  const h = { 'Idempotency-Key': 'sub-key-0001' };
  const first = await (await s.call(token, 'POST', '/v1/actions/subscribe', confirmed, h)).json();
  const again = await s.call(token, 'POST', '/v1/actions/subscribe', confirmed, h);
  assert.equal(again.status, 200);
  assert.deepEqual(await again.json(), first);
  assert.equal(s.calls.length, 1);
  const look = await s.call(token, 'POST', '/v1/actions/subscribe', confirmed, { ...h, 'X-User-Action': '', 'Idempotency-Lookup': '1' });
  assert.deepEqual(await look.json(), first);
  const unknown = await s.call(token, 'POST', '/v1/actions/subscribe', confirmed, { 'Idempotency-Key': 'sub-key-0002', 'X-User-Action': '', 'Idempotency-Lookup': '1' });
  assert.equal(unknown.status, 404);
  assert.equal((await s.call(token, 'POST', '/v1/actions/subscribe', { ...confirmed, amount: 41, confirm_amount: 41 }, h)).status, 409);
  assert.equal(s.calls.length, 1);
  // A 409 confirm answer is not stored: the same key works once the owner confirms.
  const k = { 'Idempotency-Key': 'sub-key-0003' };
  assert.equal((await s.call(token, 'POST', '/v1/actions/subscribe', ok, k)).status, 409);
  assert.equal((await s.call(token, 'POST', '/v1/actions/subscribe', confirmed, k)).status, 200);
});

test('webhook: ACTIVATED marks the repeat bill active, each new PAYMENT.SALE.COMPLETED counts once, unverified events change nothing', async () => {
  let verified = true;
  const s = setup({ verify: () => verified });
  const a = s.device();
  await s.call(a.token, 'POST', '/v1/actions/subscribe', confirmed);
  const hook = async (event: unknown) => (await (await s.call(null, 'POST', '/webhooks/paypal', event, webhookHeaders)).json() as any).handled;

  verified = false;
  assert.equal((await s.call(null, 'POST', '/webhooks/paypal', { event_type: 'BILLING.SUBSCRIPTION.ACTIVATED', resource: { id: 'I-TEST1' } }, webhookHeaders)).status, 401);
  assert.equal(s.db.getSubscription(a.userId, 'I-TEST1')!.status, 'APPROVAL_PENDING');
  verified = true;

  assert.equal(await hook({ event_type: 'BILLING.SUBSCRIPTION.ACTIVATED', resource: { id: 'I-TEST1' } }), true);
  assert.equal(s.db.getSubscription(a.userId, 'I-TEST1')!.status, 'ACTIVE');
  assert.equal(await hook(subscriptionPaidEvent('I-TEST1', 'SALE-1')), true);
  assert.equal(await hook(subscriptionPaidEvent('I-TEST1', 'SALE-1')), true);
  assert.equal(await hook(subscriptionPaidEvent('I-TEST1', 'SALE-2')), true);
  const row = s.db.getSubscription(a.userId, 'I-TEST1')!;
  assert.equal(row.paid_count, 2);
  assert.ok(row.last_paid_at);
  assert.equal(await hook(subscriptionPaidEvent('I-UNKNOWN', 'SALE-3')), false);
  assert.equal(await hook({ event_type: 'BILLING.SUBSCRIPTION.ACTIVATED', resource: { id: 'I-UNKNOWN' } }), false);
});

test('webhook: CANCELLED and SUSPENDED set the status, and a later sale never makes the repeat bill active again', async () => {
  const s = setup();
  const a = s.device();
  await s.call(a.token, 'POST', '/v1/actions/subscribe', confirmed);
  await s.call(a.token, 'POST', '/v1/actions/subscribe', { ...confirmed, amount: 50, confirm_amount: 50 });
  const [second, first] = s.db.listSubscriptions(a.userId).map((r) => r.id);
  const hook = async (event: unknown) => (await (await s.call(null, 'POST', '/webhooks/paypal', event, webhookHeaders)).json() as any).handled;
  const status = (id: string) => s.db.getSubscription(a.userId, id)!.status;

  for (const id of [first, second]) assert.equal(await hook({ event_type: 'BILLING.SUBSCRIPTION.ACTIVATED', resource: { id } }), true);
  assert.equal(await hook({ event_type: 'BILLING.SUBSCRIPTION.CANCELLED', resource: { id: first } }), true);
  assert.equal(await hook({ event_type: 'BILLING.SUBSCRIPTION.SUSPENDED', resource: { id: second } }), true);
  assert.deepEqual([status(first), status(second)], ['CANCELLED', 'SUSPENDED']);

  assert.equal(await hook(subscriptionPaidEvent(first, 'SALE-LATE-1')), true);
  assert.equal(await hook(subscriptionPaidEvent(second, 'SALE-LATE-2')), true);
  assert.deepEqual([status(first), status(second)], ['CANCELLED', 'SUSPENDED']);
  // A late or replayed ACTIVATED never brings either one back.
  for (const id of [first, second]) assert.equal(await hook({ event_type: 'BILLING.SUBSCRIPTION.ACTIVATED', resource: { id } }), true);
  assert.deepEqual([status(first), status(second)], ['CANCELLED', 'SUSPENDED']);
  assert.equal(await hook({ event_type: 'BILLING.SUBSCRIPTION.CANCELLED', resource: { id: 'I-UNKNOWN' } }), false);
});
