import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { createCipher } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { createPayPalProvider, PayPalError } from '../src/paypal.ts';

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
  db.addSubscriptionPayment(a, 'I-1', 30);
  const row = db.getSubscription(a, 'I-1')!;
  assert.deepEqual([row.status, row.activated_at, row.last_paid_at, row.paid_count], ['ACTIVE', 10, 30, 1]);

  assert.equal(db.anyBillingProduct(a), null);
  db.putBillingPlan(a, 'USD:4000:month', 'PROD-1', 'P-1');
  assert.deepEqual({ ...db.getBillingPlan(a, 'USD:4000:month') }, { product_id: 'PROD-1', plan_id: 'P-1' });
  assert.equal(db.anyBillingProduct(a), 'PROD-1');
  assert.equal(db.getBillingPlan(b, 'USD:4000:month'), undefined);
});
