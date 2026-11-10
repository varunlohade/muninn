import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createCipheriv, hkdfSync, randomBytes } from 'node:crypto';
import { config } from '../src/config.ts';
import { createCipher } from '../src/crypto.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

async function paidInvoice(s: ReturnType<typeof setup>, token: string, amount: number) {
  const inv = await (await s.call(token, 'POST', '/v1/actions/invoice', { amount, item: 'Logo', client_name: 'Alice Secret' })).json();
  await s.call(null, 'POST', '/webhooks/paypal', paidEvent(inv.id), webhookHeaders);
  return inv.id as string;
}

test('M1: stale refund tokens cannot over-refund', async () => {
  const s = setup();
  const { token } = s.device();
  const id = await paidInvoice(s, token, 100);
  const t1 = await (await s.call(token, 'POST', '/v1/actions/refund', { id, amount: 10 })).json();
  const t2 = await (await s.call(token, 'POST', '/v1/actions/refund', { id, amount: 10 })).json();
  const t3 = await (await s.call(token, 'POST', '/v1/actions/refund', { id })).json();
  const statuses = [];
  for (const t of [t1, t2, t3]) statuses.push((await s.call(token, 'POST', '/v1/actions/refund', { confirm_token: t.confirm_token })).status);
  assert.deepEqual(statuses, [200, 404, 404]);
  assert.deepEqual(s.calls.filter((c) => c.fn === 'refund').map((c) => c.args[1]), ['10.00']);

  assert.equal((await s.call(token, 'POST', '/v1/actions/refund', { id, amount: 91 })).status, 400);
  const t4 = await (await s.call(token, 'POST', '/v1/actions/refund', { id, amount: 90 })).json();
  assert.equal((await s.call(token, 'POST', '/v1/actions/refund', { confirm_token: t4.confirm_token })).status, 200);
  assert.equal((await s.call(token, 'POST', '/v1/actions/refund', { id, amount: 1 })).status, 409);
  const p = (await (await s.call(token, 'GET', '/v1/payments')).json()).payments[0];
  assert.equal(p.state, 'refunded');
});

test('M1: concurrent confirms of two tokens refund once', async () => {
  const s = setup({ paypalDelayMs: 30 });
  const { token } = s.device();
  const id = await paidInvoice(s, token, 100);
  const a = await (await s.call(token, 'POST', '/v1/actions/refund', { id })).json();
  const b = await (await s.call(token, 'POST', '/v1/actions/refund', { id })).json();
  const r = await Promise.all([a, b].map((t) => s.call(token, 'POST', '/v1/actions/refund', { confirm_token: t.confirm_token })));
  assert.deepEqual(r.map((x) => x.status).sort(), [200, 404]);
  assert.equal(s.calls.filter((c) => c.fn === 'refund').length, 1);
});

test('M2: invoice chip shows the recipient and flags an unknown email', async () => {
  const s = setup({ ext: { client_email: 'attacker@evil.test', item: 'haircut\u202e\n\nInvoice $4.50 · trim' } });
  const { token } = s.device();
  const chip = (await (await s.call(token, 'POST', '/v1/suggest', { text: 'invoice sam 45 haircut' })).json()).chips[0];
  assert.match(chip.label, /→ attacker@evil\.test$/);
  assert.equal(chip.needs_confirm, true);
  assert.ok(!/[\u0000-\u001f\u202a-\u202e\u2066-\u2069\u200e\u200f]/.test(chip.label + chip.payload.item));

  const ok = setup();
  const t2 = ok.device().token;
  const chip2 = (await (await ok.call(t2, 'POST', '/v1/suggest', { text: "that'll be $45 for the haircut, sam@example.com" })).json()).chips[0];
  assert.equal(chip2.needs_confirm, false);
  assert.match(chip2.label, /→ sam@example\.com$/);
});

test('M2: control and bidi characters are stripped before PayPal', async () => {
  const s = setup();
  const { token } = s.device();
  const r = await s.call(token, 'POST', '/v1/actions/invoice', { amount: 5, item: 'cut\u202e\u2066\nfree', client_name: 'Sam\u200f\r\nLee' });
  assert.equal(r.status, 200);
  const sent = s.calls.find((c) => c.fn === 'invoice')!.args[0] as { item: string; clientName: string };
  assert.equal(sent.item, 'cut free');
  assert.equal(sent.clientName, 'Sam Lee');
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { amount: 5, item: 'x', client_email: 'not-an-email' })).status, 400);
});

test('L1: refund step 1 is not cached with its token or summary', async () => {
  const s = setup();
  const { token } = s.device();
  const id = await paidInvoice(s, token, 100);
  const t = await (await s.call(token, 'POST', '/v1/actions/refund', { id })).json();
  assert.ok(t.confirm_token);
  const leaked = s.db.raw.prepare("SELECT COUNT(*) AS n FROM idempotency WHERE response LIKE ? OR response LIKE '%Alice%'").get(`%${t.confirm_token}%`) as { n: number };
  assert.equal(leaked.n, 0);
});

test('L3: concurrent same key calls PayPal once; same key with another body is 409', async () => {
  const s = setup({ paypalDelayMs: 30 });
  const { token } = s.device();
  const h = { 'Idempotency-Key': 'race-key-1' };
  const rr = await Promise.all([1, 2, 3].map(() => s.call(token, 'POST', '/v1/actions/invoice', { amount: 5, item: 'a' }, h)));
  assert.equal(s.calls.filter((c) => c.fn === 'invoice').length, 1);
  assert.ok(rr.some((r) => r.status === 200));
  assert.ok(rr.filter((r) => r.status !== 200).every((r) => r.status === 409));
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { amount: 5, item: 'a' }, h)).status, 200);
  assert.equal((await s.call(token, 'POST', '/v1/actions/invoice', { amount: 9999, item: 'b' }, h)).status, 409);
  assert.equal(s.calls.filter((c) => c.fn === 'invoice').length, 1);
});

test('L2: spoofed X-Forwarded-For does not dodge the limit, and verified events keep their own budget', async () => {
  const s = setup({ verify: false });
  const st: number[] = [];
  for (let i = 0; i < 200; i++) {
    st.push((await s.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-X'), { ...webhookHeaders, 'X-Forwarded-For': `10.0.${i >> 8}.${i & 255}` })).status);
  }
  assert.ok(st.includes(429), 'rotating XFF must still hit the limit');

  config.trustProxy = true;
  try {
    const p = setup({ verify: (h) => h['paypal-transmission-sig'] === 'good' });
    const bad = { ...webhookHeaders, 'paypal-transmission-sig': 'bad' };
    const statuses: number[] = [];
    for (let i = 0; i < config.rateLimit.webhook.limit + 5; i++) {
      statuses.push((await p.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-X'), { ...bad, 'X-Forwarded-For': `${i}.1.1.1, 198.51.100.7` })).status);
    }
    assert.ok(statuses.includes(429), 'behind a trusted proxy the right-most hop is the key');
    const good = await p.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-X'),
      { ...webhookHeaders, 'paypal-transmission-sig': 'good', 'X-Forwarded-For': '198.51.100.7, 203.0.113.9' });
    assert.equal(good.status, 200);
  } finally {
    config.trustProxy = false;
  }
});

test('L2: with CLIENT_IP_HEADER the Cloudflare header is the key, not the X-Forwarded-For edge hop', async () => {
  config.trustProxy = true;
  config.clientIpHeader = 'cf-connecting-ip';
  try {
    const p = setup({ verify: false });
    const statuses: number[] = [];
    for (let i = 0; i < config.rateLimit.webhook.limit + 5; i++) {
      statuses.push((await p.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-X'),
        { ...webhookHeaders, 'CF-Connecting-IP': '198.51.100.7', 'X-Forwarded-For': `198.51.100.7, 104.22.${i}.1` })).status);
    }
    assert.ok(statuses.includes(429), 'rotating edge hops must not dodge the limit');
    const other = await p.call(null, 'POST', '/webhooks/paypal', paidEvent('INV2-X'), { ...webhookHeaders, 'CF-Connecting-IP': '203.0.113.9' });
    assert.equal(other.status, 401);
  } finally {
    config.trustProxy = false;
    config.clientIpHeader = '';
  }
});

test('crypto: a truncated GCM tag is rejected (Node 26 already rejects it; authTagLength pins it)', () => {
  const master = randomBytes(32);
  const cipher = createCipher(master);
  const key = Buffer.from(hkdfSync('sha256', master, Buffer.from('u1'), 'pro-keyboard/data/v1', 32));
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, iv);
  c.setAAD(Buffer.from('u1'));
  c.update('');
  c.final();
  const blob = 'v1:' + Buffer.concat([iv, c.getAuthTag().subarray(0, 4)]).toString('base64');
  assert.throws(() => cipher.decrypt('u1', blob));
});
