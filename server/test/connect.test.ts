import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { config } from '../src/config.ts';
import { sha256 } from '../src/crypto.ts';
import { authAssertion, createPayPalProvider, PARTNER_FEATURES, type MerchantStatus, type PayPalPartner, type Seller } from '../src/paypal.ts';
import { setup, webhookHeaders } from './helpers.ts';

config.paypal.publicUrl = 'https://muninn.test';
config.paypal.partnerMerchantId = 'PARTNER123';

// A fake Partner Referrals API: one seller per tracking id, as PayPal keeps them.
function fakePartner(o: { merchantFor?: (tracking: string) => string | null; status?: Partial<MerchantStatus> } = {}) {
  const calls: { fn: string; args: unknown[] }[] = [];
  const merchants = new Map<string, string>();
  const partner: PayPalPartner = {
    async createReferral(trackingId, returnUrl) {
      calls.push({ fn: 'referral', args: [trackingId, returnUrl] });
      return { actionUrl: `https://www.sandbox.paypal.com/bizsignup/partner/entry?referralToken=${trackingId.slice(-6)}` };
    },
    async merchantIdForTracking(trackingId) {
      calls.push({ fn: 'byTracking', args: [trackingId] });
      return o.merchantFor ? o.merchantFor(trackingId) : merchants.get(trackingId) ?? null;
    },
    async merchantStatus(merchantId) {
      calls.push({ fn: 'status', args: [merchantId] });
      const trackingId = [...merchants].reverse().find(([, m]) => m === merchantId)?.[0] ?? null;
      return { merchantId, trackingId, paymentsReceivable: true, emailConfirmed: true, primaryEmail: 'seller@shop.test', permissionsGranted: true, ...o.status };
    },
  };
  return { partner, calls, onboard: (trackingId: string, merchantId: string) => merchants.set(trackingId, merchantId) };
}

const returnQuery = (tracking: string, merchant: string, extra = 'permissionsGranted=true&consentStatus=true&isEmailConfirmed=true') =>
  `/paypal/return?merchantId=${tracking}&merchantIdInPayPal=${merchant}&${extra}`;

async function startConnect(s: ReturnType<typeof setup>, token: string, calls: { fn: string; args: unknown[] }[]) {
  const r = await s.call(token, 'POST', '/v1/paypal/connect');
  assert.equal(r.status, 200);
  const j = await r.json() as any;
  const tracking = calls.filter((c) => c.fn === 'referral').at(-1)!.args[0] as string;
  return { j, tracking };
}

/** PayPal sends the browser back; the server answers with the app link that carries the one-time code. */
async function returnCode(s: ReturnType<typeof setup>, tracking: string, merchant: string) {
  const loc = (await s.call(null, 'GET', returnQuery(tracking, merchant))).headers.get('location') ?? '';
  const m = /^muninn:\/\/paypal-connected\?code=([0-9a-f]{48})$/.exec(loc);
  assert.ok(m, loc);
  return m[1];
}
const finish = (s: ReturnType<typeof setup>, token: string, code: string) => s.call(token, 'POST', '/v1/paypal/finish', { code });

beforeEach(() => {
  config.paypal.publicUrl = 'https://muninn.test';
  config.paypal.partnerMerchantId = 'PARTNER123';
});

test('connect: makes a partner referral with a random tracking id and returns the PayPal sign-up link', async () => {
  const p = fakePartner();
  const s = setup({ partner: p.partner });
  const a = s.device();
  const { j, tracking } = await startConnect(s, a.token, p.calls);
  assert.match(j.action_url, /^https:\/\/www\.sandbox\.paypal\.com\//);
  assert.equal(j.return_scheme, 'muninn');
  assert.match(tracking, /^mu[0-9a-f]{32}$/);
  assert.ok(!tracking.includes(a.userId));
  assert.equal(p.calls[0].args[1], 'https://muninn.test/paypal/return');
  const row = s.db.getPayPalConnection(a.userId)!;
  assert.equal(row.status, 'pending');
  assert.equal(row.tracking_hash, sha256(tracking));
  // A second tap makes a new tracking id; the first one stops working.
  const again = await startConnect(s, a.token, p.calls);
  assert.notEqual(again.tracking, tracking);
  assert.equal(s.db.payPalConnectionByTracking(sha256(tracking)), undefined);
});

test('connect: 503 when the server has no public URL or partner id, 401 without a token', async () => {
  const p = fakePartner();
  const s = setup({ partner: p.partner });
  const a = s.device();
  config.paypal.publicUrl = '';
  assert.equal((await s.call(a.token, 'POST', '/v1/paypal/connect')).status, 503);
  assert.equal((await s.call(null, 'POST', '/v1/paypal/connect')).status, 401);
  assert.equal(p.calls.length, 0);
});

test('return: PayPal confirms the merchant, the app gets a one-time code, and the owner finishes with it', async () => {
  const p = fakePartner();
  const s = setup({ partner: p.partner });
  const a = s.device();
  const { tracking } = await startConnect(s, a.token, p.calls);
  p.onboard(tracking, 'SELLER12345');
  const code = await returnCode(s, tracking, 'SELLER12345');
  // The return link alone connects nothing.
  assert.equal((await (await s.call(a.token, 'GET', '/v1/paypal/status')).json() as any).connected, false);
  assert.equal(s.db.getPayPalConnection(a.userId)!.code_hash, sha256(code), 'only the hash of the code is stored');
  assert.deepEqual(await (await s.call(a.token, 'POST', '/v1/paypal/pending', { code })).json(), { account: 's•••@shop.test' });
  const done = await finish(s, a.token, code);
  assert.equal(done.status, 200);
  assert.deepEqual(await done.json(), { result: 'connected', account: 's•••@shop.test' });
  assert.equal((await finish(s, a.token, code)).status, 404, 'the code works once');
  const st = await (await s.call(a.token, 'GET', '/v1/paypal/status')).json() as any;
  assert.deepEqual(st, { connected: true, demo: false, pending: false, email_confirmed: true, payments_receivable: true, account: 's•••@shop.test' });
  // Stored encrypted: the merchant id and email are not in the row as plain text.
  const row = s.db.getPayPalConnection(a.userId)!;
  assert.ok(!JSON.stringify(row).includes('SELLER12345') && !JSON.stringify(row).includes('seller@shop.test'));
  const list = await (await s.call(a.token, 'GET', '/v1/integrations')).json() as any;
  assert.equal(list.integrations.find((i: any) => i.id === 'paypal').description, 'PayPal connected · s•••@shop.test');
  // The same return link a second time does nothing more.
  assert.equal((await s.call(null, 'GET', returnQuery(tracking, 'SELLER12345'))).headers.get('location'), 'muninn://paypal-connected?result=failed');
});

test('return: an unknown or expired tracking id, a merchant PayPal does not confirm, or a declined consent never connects', async () => {
  let t = Date.now();
  const p = fakePartner();
  const s = setup({ partner: p.partner, now: () => t });
  const a = s.device();
  const loc = async (q: string) => (await s.call(null, 'GET', q)).headers.get('location');
  const { tracking } = await startConnect(s, a.token, p.calls);
  p.onboard(tracking, 'SELLER12345');
  const before = p.calls.length;
  assert.equal(await loc(returnQuery(`mu${'0'.repeat(32)}`, 'SELLER12345')), 'muninn://paypal-connected?result=failed');
  assert.equal(await loc(returnQuery('not-a-tracking-id', 'SELLER12345')), 'muninn://paypal-connected?result=failed');
  assert.equal(p.calls.length, before, 'unknown tracking ids reach no PayPal call');
  // The query names another merchant than the one PayPal has for this tracking id.
  assert.equal(await loc(returnQuery(tracking, 'ATTACKER999')), 'muninn://paypal-connected?result=failed');
  assert.equal(await loc(returnQuery(tracking, 'SELLER12345', 'permissionsGranted=false&consentStatus=true')), 'muninn://paypal-connected?result=declined');
  assert.equal(s.db.getPayPalConnection(a.userId)!.status, 'pending');
  t += config.paypal.connectTtlMs + 1;
  assert.equal(await loc(returnQuery(tracking, 'SELLER12345')), 'muninn://paypal-connected?result=failed');
  assert.equal((await (await s.call(a.token, 'GET', '/v1/paypal/status')).json() as any).connected, false);
});

test('return: a user cannot take a merchant that another user connected, and permissions must be granted to this app', async () => {
  const p = fakePartner();
  const s = setup({ partner: p.partner });
  const a = s.device(), b = s.device();
  const ta = (await startConnect(s, a.token, p.calls)).tracking;
  const tb = (await startConnect(s, b.token, p.calls)).tracking;
  p.onboard(ta, 'SELLER12345');
  assert.equal((await finish(s, a.token, await returnCode(s, ta, 'SELLER12345'))).status, 200);
  // b's own tracking id, but the same PayPal merchant: refused.
  p.onboard(tb, 'SELLER12345');
  const taken = await finish(s, b.token, await returnCode(s, tb, 'SELLER12345'));
  assert.equal(taken.status, 409);
  assert.equal((await taken.json() as any).result, 'taken');
  assert.equal(s.db.getPayPalConnection(b.userId)!.status, 'pending');
  // b's tracking id never connects a.
  assert.equal(s.db.getPayPalConnection(a.userId)!.tracking_hash, sha256(ta));

  const q = fakePartner({ status: { permissionsGranted: false } });
  const s2 = setup({ partner: q.partner });
  const c = s2.device();
  const tc = (await startConnect(s2, c.token, q.calls)).tracking;
  q.onboard(tc, 'SELLER77777');
  assert.equal((await s2.call(null, 'GET', returnQuery(tc, 'SELLER77777'))).headers.get('location'), 'muninn://paypal-connected?result=declined');
});

test('login CSRF: a sign-up link someone else completes never connects their PayPal to the sender', async () => {
  let t = Date.now();
  const p = fakePartner();
  const s = setup({ partner: p.partner, now: () => t });
  const attacker = s.device(), victim = s.device();
  const { tracking } = await startConnect(s, attacker.token, p.calls);
  // The victim signs in to PayPal on the attacker's link; the return lands on the victim's phone.
  p.onboard(tracking, 'VICTIM12345');
  const code = await returnCode(s, tracking, 'VICTIM12345');
  assert.equal((await finish(s, victim.token, code)).status, 404, 'the code only works for the user who started this Connect');
  assert.equal((await s.call(victim.token, 'POST', '/v1/paypal/pending', { code })).status, 404);
  assert.equal(s.db.getPayPalConnection(attacker.userId)!.status, 'pending');
  assert.equal((await finish(s, attacker.token, 'f'.repeat(48))).status, 404, 'a guessed code finds nothing');
  assert.equal((await s.call(null, 'POST', '/v1/paypal/finish', { code })).status, 401, 'finish needs the app sign-in');
  // A code that waited too long is dead even for its owner.
  t += config.paypal.connectCodeTtlMs + 1;
  assert.equal((await finish(s, attacker.token, code)).status, 404);
  assert.equal((await (await s.call(attacker.token, 'GET', '/v1/paypal/status')).json() as any).connected, false);
});

test('demo fallback: a user with no PayPal connected runs on the demo merchant, and money answers say demo', async () => {
  const s = setup({ partner: fakePartner().partner });
  const a = s.device();
  const st = await (await s.call(a.token, 'GET', '/v1/paypal/status')).json() as any;
  assert.deepEqual(st, { connected: false, demo: true, pending: false, email_confirmed: false, payments_receivable: false, account: null });
  const inv = await (await s.call(a.token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', client_name: 'Sam' })).json() as any;
  assert.equal(inv.demo, true);
  assert.equal(s.db.getInvoice(a.userId, inv.id)!.pp_account, null);
  const list = await (await s.call(a.token, 'GET', '/v1/integrations')).json() as any;
  assert.equal(list.integrations.find((i: any) => i.id === 'paypal').description, 'Demo PayPal (sandbox)');
});

test('connected: new invoices carry the seller account and say demo false; disconnect goes back to demo', async () => {
  const p = fakePartner();
  const s = setup({ partner: p.partner });
  const a = s.device();
  const { tracking } = await startConnect(s, a.token, p.calls);
  p.onboard(tracking, 'SELLER12345');
  await finish(s, a.token, await returnCode(s, tracking, 'SELLER12345'));
  const inv = await (await s.call(a.token, 'POST', '/v1/actions/invoice', { amount: 45, item: 'Haircut', client_name: 'Sam' })).json() as any;
  assert.equal(inv.demo, false);
  assert.equal(s.db.getInvoice(a.userId, inv.id)!.pp_account, s.db.getPayPalConnection(a.userId)!.merchant_hash);
  assert.equal((await s.call(a.token, 'POST', '/v1/paypal/connect')).status, 409);
  const d = await (await s.call(a.token, 'POST', '/v1/paypal/disconnect')).json() as any;
  assert.deepEqual(d, { connected: false, demo: true });
  assert.equal(s.db.getPayPalConnection(a.userId), undefined);
});

test('webhooks: ONBOARDING.COMPLETED only records the check; PARTNER-CONSENT.REVOKED disconnects; unverified events change nothing', async () => {
  const p = fakePartner();
  let verified = true;
  const s = setup({ partner: p.partner, verify: () => verified });
  const a = s.device();
  const { tracking } = await startConnect(s, a.token, p.calls);
  p.onboard(tracking, 'SELLER12345');
  const hook = (event: unknown) => s.call(null, 'POST', '/webhooks/paypal', event, webhookHeaders);
  const onboarded = { event_type: 'MERCHANT.ONBOARDING.COMPLETED', resource: { merchant_id: 'SELLER12345', tracking_id: tracking } };
  const revoked = { event_type: 'MERCHANT.PARTNER-CONSENT.REVOKED', resource: { merchant_id: 'SELLER12345' } };

  verified = false;
  assert.equal((await hook(onboarded)).status, 401);
  assert.equal(s.db.getPayPalConnection(a.userId)!.status, 'pending');
  verified = true;
  assert.deepEqual(await (await hook(onboarded)).json(), { ok: true, handled: true });
  assert.equal(s.db.getPayPalConnection(a.userId)!.status, 'pending', 'a webhook never connects; the owner finishes in the app');
  assert.equal((await finish(s, a.token, await returnCode(s, tracking, 'SELLER12345'))).status, 200);

  verified = false;
  assert.equal((await hook(revoked)).status, 401);
  assert.equal(s.db.getPayPalConnection(a.userId)!.status, 'connected');
  verified = true;
  assert.deepEqual(await (await hook(revoked)).json(), { ok: true, handled: true });
  assert.equal(s.db.getPayPalConnection(a.userId), undefined);
  const st = await (await s.call(a.token, 'GET', '/v1/paypal/status')).json() as any;
  assert.equal(st.demo, true);
  assert.deepEqual(await (await hook(revoked)).json(), { ok: true, handled: false });
});

// ---- the real PayPal client, against a stub fetch

type Sent = { method: string; path: string; headers: Record<string, string>; body: any };
function stubFetch() {
  const sent: Sent[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (async (url: string, init: RequestInit) => {
    const u = new URL(url);
    const headers = init.headers as Record<string, string>;
    sent.push({ method: String(init.method), path: u.pathname + u.search, headers, body: init.body && u.pathname !== '/v1/oauth2/token' ? JSON.parse(String(init.body)) : null });
    const json = (j: unknown, status = 201) => new Response(JSON.stringify(j), { status });
    if (u.pathname === '/v1/oauth2/token') return json({ access_token: 'tok', expires_in: 3600 }, 200);
    if (u.pathname === '/v2/invoicing/invoices') return json({ id: 'INV2-SELL-0001', status: 'DRAFT' });
    if (u.pathname.endsWith('/send')) return json({ rel: 'payer-view', href: 'https://www.sandbox.paypal.com/invoice/p/#INV2-SELL-0001' }, 200);
    if (u.pathname === '/v2/checkout/orders') return json({ id: 'ORDER1', status: 'CREATED', links: [{ rel: 'approve', href: 'https://www.sandbox.paypal.com/checkoutnow?token=ORDER1' }] });
    if (u.pathname.endsWith('/refund')) return json({ id: 'REF1', status: 'COMPLETED' });
    if (u.pathname === '/v2/customer/partner-referrals') return json({ links: [{ rel: 'self', href: 'https://api-m.sandbox.paypal.com/v2/customer/partner-referrals/X' }, { rel: 'action_url', href: 'https://www.sandbox.paypal.com/bizsignup/partner/entry?referralToken=X' }] });
    if (u.pathname.startsWith('/v1/customer/partners/PARTNER123/merchant-integrations/')) {
      return json({ merchant_id: 'SELLER12345', tracking_id: 'mu1', payments_receivable: true, primary_email_confirmed: false, primary_email: 'seller@shop.test',
        oauth_integrations: [{ integration_type: 'OAUTH_THIRD_PARTY', oauth_third_party: [{ partner_client_id: 'client-id', scopes: [] }] }] }, 200);
    }
    if (u.pathname === '/v1/customer/partners/PARTNER123/merchant-integrations') return json({ merchant_id: 'SELLER12345' }, 200);
    return json({}, 404);
  }) as typeof fetch;
  return { sent, restore: () => { globalThis.fetch = real; } };
}

const seller: Seller = { merchantId: 'SELLER12345', email: 'seller@shop.test', account: 'acct-1' };
const decode = (jwt: string) => jwt.split('.').slice(0, 2).map((p) => JSON.parse(Buffer.from(p, 'base64').toString('utf8')));

test('auth assertion: unsigned JWT with the platform client id as iss and the seller as payer_id', () => {
  const jwt = authAssertion('client-id', 'SELLER12345');
  assert.ok(jwt.endsWith('.'));
  assert.deepEqual(decode(jwt), [{ alg: 'none' }, { iss: 'client-id', payer_id: 'SELLER12345' }]);
});

test('provider: a connected seller’s invoice goes to PayPal with PayPal-Auth-Assertion and the seller as invoicer', async () => {
  const { sent, restore } = stubFetch();
  try {
    const provider = createPayPalProvider({ clientId: 'client-id', clientSecret: 's' }, (u) => (u === 'user-a' ? seller : null));
    const out = await provider.forUser('user-a').createAndSendInvoice({ value: '45.00', currency: 'USD', item: 'Haircut', clientName: 'Sam', clientEmail: 'sam@example.com', businessName: 'Ana Cuts' }, 'req-1');
    assert.deepEqual(out, { id: 'INV2-SELL-0001', status: 'SENT', payLink: 'https://www.sandbox.paypal.com/invoice/p/#INV2-SELL-0001' });
    const calls = sent.filter((x) => x.path !== '/v1/oauth2/token');
    assert.deepEqual(calls.map((x) => [x.method, x.path, x.headers['PayPal-Request-Id']]), [
      ['POST', '/v2/invoicing/invoices', 'req-1-create'], ['POST', '/v2/invoicing/invoices/INV2-SELL-0001/send', 'req-1-send'],
    ]);
    for (const x of calls) assert.deepEqual(decode(x.headers['PayPal-Auth-Assertion'])[1], { iss: 'client-id', payer_id: 'SELLER12345' });
    assert.deepEqual(calls[0].body.invoicer, { business_name: 'Ana Cuts', email_address: 'seller@shop.test' });
  } finally {
    restore();
  }
});

test('provider: objects made on the demo merchant stay on it after the user connects; another account is refused', async () => {
  const { sent, restore } = stubFetch();
  try {
    const provider = createPayPalProvider({ clientId: 'client-id', clientSecret: 's' }, (u) => (u === 'user-a' ? seller : null));
    await provider.forAccount('user-a', null).refundCapture('CAP1', '10.00', 'USD', 'r1');
    await provider.forUser('user-b').createOrder({ value: '5.00', currency: 'USD', item: 'Tip' }, 'o1');
    await provider.forAccount('user-a', 'acct-1').refundCapture('CAP2', '10.00', 'USD', 'r2');
    const calls = sent.filter((x) => x.path !== '/v1/oauth2/token');
    assert.deepEqual(calls.map((x) => [x.path, 'PayPal-Auth-Assertion' in x.headers]), [
      ['/v2/payments/captures/CAP1/refund', false], ['/v2/checkout/orders', false], ['/v2/payments/captures/CAP2/refund', true],
    ]);
    assert.throws(() => provider.forAccount('user-a', 'acct-other'), /no longer connected/);
    assert.throws(() => provider.forAccount('user-b', 'acct-1'), /no longer connected/);
  } finally {
    restore();
  }
});

test('provider partner: one referral asks for every feature; merchant status reads the integration for this app', async () => {
  const { sent, restore } = stubFetch();
  try {
    const partner = createPayPalProvider({ clientId: 'client-id', clientSecret: 's' }).partner();
    const { actionUrl } = await partner.createReferral('mu1', 'https://muninn.test/paypal/return');
    assert.equal(actionUrl, 'https://www.sandbox.paypal.com/bizsignup/partner/entry?referralToken=X');
    const ref = sent.find((x) => x.path === '/v2/customer/partner-referrals')!;
    assert.equal('PayPal-Auth-Assertion' in ref.headers, false);
    assert.equal(ref.body.tracking_id, 'mu1');
    assert.equal(ref.body.partner_config_override.return_url, 'https://muninn.test/paypal/return');
    assert.deepEqual(ref.body.operations[0].api_integration_preference.rest_api_integration.third_party_details.features, [...PARTNER_FEATURES]);
    assert.deepEqual([...PARTNER_FEATURES].sort(), ['ACCESS_MERCHANT_INFORMATION', 'ADVANCED_TRANSACTIONS_SEARCH', 'BILLING_AGREEMENT', 'INVOICE_READ_WRITE', 'PAYMENT',
      'PAYOUTS', 'PAYPAL_BALANCE', 'READ_SELLER_DISPUTE', 'REFUND', 'TRACKING_SHIPMENT_READWRITE', 'UPDATE_SELLER_DISPUTE']);
    assert.equal(await partner.merchantIdForTracking('mu1'), 'SELLER12345');
    assert.ok(sent.some((x) => x.path === '/v1/customer/partners/PARTNER123/merchant-integrations?tracking_id=mu1'));
    assert.deepEqual(await partner.merchantStatus('SELLER12345'), {
      merchantId: 'SELLER12345', trackingId: 'mu1', paymentsReceivable: true, emailConfirmed: false, primaryEmail: 'seller@shop.test', permissionsGranted: true,
    });
    assert.equal(await partner.merchantStatus('OTHER000001'), null);
  } finally {
    restore();
  }
});
