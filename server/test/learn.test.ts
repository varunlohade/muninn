import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import type { Extraction } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { createCipher } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { createLearner, learnFrom } from '../src/learn.ts';
import type { PayPal, PayPalPartner, PayPalProvider, PayPalTxn } from '../src/paypal.ts';
import { setup, sleep } from './helpers.ts';

config.paypal.publicUrl = 'https://muninn.test';
config.paypal.partnerMerchantId = 'PARTNER123';

const DAY = 86_400_000;
let n = 0;
const txn = (o: Partial<PayPalTxn> & { value: string }): PayPalTxn => ({
  id: `TX${++n}`, event_code: 'T0006', date: '2026-11-01T10:00:00Z', status: 'S', amount: { value: o.value, currency: 'USD' }, fee: null,
  payer_name: null, payer_email: null, invoice_id: null, subject: null, note: null, items: [], ...o,
});
const SALES = () => [
  txn({ value: '120.00', payer_name: 'Sam Lee', payer_email: 'Sam@Client.test', items: [{ name: 'Logo design', amount: { value: '120.00', currency: 'USD' }, quantity: 1 }] }),
  txn({ value: '140.00', payer_name: 'Sam Lee', payer_email: 'sam@client.test', items: [{ name: 'Logo design', amount: { value: '140.00', currency: 'USD' }, quantity: 1 }] }),
  txn({ value: '60.00', payer_name: 'Ana Ruiz', subject: 'Business cards' }),
  txn({ value: '300.00', payer_name: 'Ana Ruiz', items: [{ name: 'Website', amount: { value: '300.00', currency: 'USD' }, quantity: 1 }] }),
  // Not a sale: money sent out, and a reversed payment.
  txn({ value: '-50.00', event_code: 'T0001', payer_name: 'Supplier Co', subject: 'Paper' }),
  txn({ value: '99.00', status: 'V', payer_name: 'Gone Guy', subject: 'Refunded thing' }),
];

// A Partner Referrals fake: the seller onboards, PayPal confirms them, the app finishes.
function partner() {
  const merchants = new Map<string, string>();
  const p: PayPalPartner = {
    async createReferral(trackingId) { merchants.set(trackingId, 'SELLER12345'); return { actionUrl: 'https://www.sandbox.paypal.com/x' }; },
    async merchantIdForTracking(t) { return merchants.get(t) ?? null; },
    async merchantStatus(merchantId) {
      const trackingId = [...merchants.keys()].at(-1) ?? null;
      return { merchantId, trackingId, paymentsReceivable: true, emailConfirmed: true, primaryEmail: 'seller@shop.test', permissionsGranted: true, currency: 'USD', country: 'US' };
    },
  };
  return p;
}

async function finishConnect(s: ReturnType<typeof setup>, token: string, trackingId: string) {
  const loc = (await s.call(null, 'GET', `/paypal/return?merchantId=${trackingId}&merchantIdInPayPal=SELLER12345&permissionsGranted=true&consentStatus=true`)).headers.get('location') ?? '';
  const code = /code=([0-9a-f]{48})/.exec(loc)?.[1];
  assert.ok(code, loc);
  return s.call(token, 'POST', '/v1/paypal/finish', { code });
}

async function connected(txns: PayPalTxn[], description?: string, ext?: (text: string) => Partial<Extraction>) {
  const merchants: string[] = [];
  const base = partner();
  const p: PayPalPartner = { ...base, async createReferral(t, r) { merchants.push(t); return base.createReferral(t, r); } };
  const s = setup({ partner: p, ext });
  const a = s.device();
  s.ppData.set(a.userId, { txns });
  if (description) assert.equal((await s.call(a.token, 'PUT', '/v1/profile/business', { description })).status, 200);
  assert.equal((await s.call(a.token, 'POST', '/v1/paypal/connect')).status, 200);
  const r = await finishConnect(s, a.token, merchants.at(-1)!);
  assert.equal(r.status, 200);
  return { s, a, finished: r };
}

test('learn: pure reading keeps sales only and gives each item its median price and each client their usual', () => {
  const l = learnFrom(SALES());
  assert.equal(l.payments, 4);
  assert.equal(l.currency, 'USD');
  assert.deepEqual(l.items.map((i) => [i.name, i.amount, i.count]), [['Logo design', '130.00', 2], ['Business cards', '60.00', 1], ['Website', '300.00', 1]]);
  const sam = l.clients.find((c) => c.email === 'sam@client.test')!;
  assert.deepEqual(sam, { name: 'Sam Lee', email: 'sam@client.test', usual: { item: 'Logo design', amount: '130.00', currency: 'USD' } });
  assert.ok(!l.clients.some((c) => c.name === 'Supplier Co' || c.name === 'Gone Guy'));
  assert.equal(l.clients.length, 2, 'Sam twice with two spellings of one email is one client');
});

test('learn: after finish, a background import learns clients and items, fills an empty profile, and never sends names to the model', async () => {
  const { s, a, finished } = await connected(SALES());
  assert.deepEqual(await finished.json(), { result: 'connected', account: 's•••@shop.test' }, 'finish answers as before');
  await sleep(20);
  // Three windows of at most 31 days cover the last 90 days, each with cart info.
  const searches = s.calls.filter((c) => c.fn === 'search');
  assert.equal(searches.length, 3);
  let covered = 0;
  for (const c of searches) {
    const [, from, to, opts] = c.args as [string, Date, Date, { cart?: boolean }];
    assert.ok(to.getTime() - from.getTime() <= 31 * DAY);
    assert.deepEqual(opts, { cart: true });
    covered += to.getTime() - from.getTime();
  }
  assert.equal(covered, 90 * DAY);

  const rows = s.db.listLearnedClients(a.userId);
  assert.equal(rows.length, 2);
  const raw = JSON.stringify(rows);
  assert.ok(!raw.includes('Sam') && !raw.includes('client.test') && !raw.includes('Logo'), 'stored encrypted');

  const describe = s.aiCalls.filter((c) => c.fn === 'describe');
  assert.equal(describe.length, 1);
  const sent = String(describe[0].args[0]);
  assert.match(sent, /Logo design/);
  assert.ok(!/Sam|Ana|client\.test|@/.test(sent), 'no payer names or emails reach the model');
  const profile = await (await s.call(a.token, 'GET', '/v1/profile')).json() as any;
  assert.equal(profile.profile.description, 'I make logos and websites for small shops.');

  const learned = await (await s.call(a.token, 'GET', '/v1/paypal/learned')).json() as any;
  assert.equal(learned.learned.clients, 2);
  assert.equal(learned.learned.items, 3);
  assert.equal(learned.learned.currency, 'USD');
  assert.equal(learned.learned.country, 'US');
  assert.equal(learned.learned.line, 'Learned 2 clients and 3 items from PayPal');
  assert.ok(!JSON.stringify(learned).includes('Sam'), 'the summary names no client');
  const st = await (await s.call(a.token, 'GET', '/v1/paypal/status')).json() as any;
  assert.equal(st.learned, 'Learned 2 clients and 3 items from PayPal');
});

test('learn: a description the owner wrote stays, with no model call', async () => {
  const { s, a } = await connected(SALES(), 'I run a print shop');
  await sleep(20);
  assert.equal(s.aiCalls.filter((c) => c.fn === 'describe').length, 0);
  assert.equal((await (await s.call(a.token, 'GET', '/v1/profile')).json() as any).profile.description, 'I run a print shop');
  assert.equal(((await (await s.call(a.token, 'GET', '/v1/paypal/learned')).json()) as any).learned.items, 3);
});

test('learn: the demo account learns nothing, and a second import adds no duplicate clients', async () => {
  const db = openDb(':memory:');
  const cipher = createCipher(randomBytes(32));
  const userId = db.createUser();
  const searched: unknown[] = [];
  const pp = { async searchTransactions(...args: unknown[]) { searched.push(args); return SALES(); } } as unknown as PayPal;
  const paypal = { forAccount: () => pp, forUser: () => pp, platform: () => pp, partner: () => null } as unknown as PayPalProvider;
  const ai = { async describe() { return 'Logos.'; } } as any;
  const l = createLearner({ db, cipher, ai, paypal, now: () => Date.UTC(2026, 10, 12), defaultProfile: { business_name: 'my shop', tone: 'friendly', currency: 'USD' } });
  await l.run(userId, null);
  assert.equal(searched.length, 0);
  assert.equal(l.summary(userId), null);
  await l.run(userId, 'acct');
  await l.run(userId, 'acct');
  assert.equal(db.listLearnedClients(userId).length, 2);
  // Ana later shows up with an email: the same client gets it.
  pp.searchTransactions = async () => [txn({ value: '60.00', payer_name: 'Ana Ruiz', payer_email: 'ana@x.test', subject: 'Business cards' })];
  await l.run(userId, 'acct');
  const clients = l.clients(userId);
  assert.equal(clients.length, 2);
  assert.equal(clients.find((c) => c.name === 'Ana Ruiz')!.email, 'ana@x.test');
});

test('learn: "invoice sam" suggests Sam\'s usual item and price, the pay link confirms, and the model context has items but no names', async () => {
  // The model reads no amount, item or email in "invoice sam", as the real checks leave it.
  const { s, a } = await connected(SALES(), undefined, (text) => ({ client_name: /sam/i.test(text) ? 'Sam' : null, client_email: null, amount: /\$(\d+)/.exec(text) ? Number(/\$(\d+)/.exec(text)![1]) : null, item: null }));
  await sleep(20);
  s.aiCalls.length = 0;
  const r = await (await s.call(a.token, 'POST', '/v1/suggest', { text: 'invoice sam' })).json() as any;
  const inv = r.chips.find((c: any) => c.kind === 'invoice');
  const link = r.chips.find((c: any) => c.kind === 'paylink');
  assert.ok(inv, JSON.stringify(r));
  assert.equal(inv.label, 'Invoice $130 · Logo design → sam@client.test');
  assert.equal(inv.needs_confirm, true);
  assert.deepEqual({ ...inv.payload }, { amount: '130.00', currency: 'USD', item: 'Logo design', client_name: 'Sam', client_email: 'sam@client.test' });
  assert.equal(link.needs_confirm, true, 'a learned price is a suggestion, so the pay link confirms too');
  for (const c of s.aiCalls) {
    const sent = JSON.stringify(c.args);
    assert.ok(!/Sam Lee|Ana|client\.test/.test(sent), `${c.fn} got no learned names`);
  }
  const ext = s.aiCalls.find((c) => c.fn === 'extract');
  assert.ok(ext, "the extract call ran");
  assert.match(String(ext.args[2]), /Usually paid for: Logo design/);
  // A typed amount wins; the reason stays the owner's own words.
  const typed = await (await s.call(a.token, 'POST', '/v1/suggest', { text: 'invoice sam $50' })).json() as any;
  assert.ok(!typed.chips.some((c: any) => c.payload?.item === 'Logo design'), JSON.stringify(typed.chips));
});
