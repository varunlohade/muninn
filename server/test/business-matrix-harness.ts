// The in-process app for the business matrix: a fresh in-memory DB, the given Ai (real createAi in both the
// mocked test and the live eval), and the test PayPal mock. Each business is its own owner with its own
// description, catalog, one unpaid invoice and one paid one.
import { randomBytes } from 'node:crypto';
import type { Ai } from '../src/ai.ts';
import { createApp } from '../src/app.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import type { PayPalPartner } from '../src/paypal.ts';
import type { Business, Msg } from './business-matrix-data.ts';
import { paidEvent, setup, webhookHeaders } from './helpers.ts';

const noPartner: PayPalPartner = {
  async createReferral() { throw new Error('no partner'); },
  async merchantStatus() { return null; },
  async merchantIdForTracking() { return null; },
};

export type Chip = { kind: string; label: string; payload: Record<string, any> };

export async function openMatrix(ai: Ai) {
  const pp = setup().mockPayPal;
  const db = openDb(':memory:');
  const app = createApp({ db, cipher: createCipher(randomBytes(32)), ai, paypal: { forUser: () => pp, forAccount: () => pp, platform: () => pp, partner: () => noPartner } });
  let k = 0;
  const call = async (token: string | null, method: string, path: string, body: unknown, headers: Record<string, string> = {}) => {
    const r = await app.request(path, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(path.startsWith('/v1/actions') ? { 'X-User-Action': 'tap', 'Idempotency-Key': `matrix-${++k}` } : {}),
        ...headers,
      },
      body: JSON.stringify(body),
    });
    const json = await r.json() as any;
    if (r.status !== 200) throw new Error(`${method} ${path} → ${r.status} ${JSON.stringify(json)}`);
    return json;
  };
  const tokens = new Map<string, string>();

  async function open(b: Business) {
    const userId = db.createUser();
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'matrix');
    tokens.set(b.id, token);
    await call(token, 'PUT', '/v1/profile', { business_name: b.id, tone: 'friendly', currency: b.currency });
    await call(token, 'PUT', '/v1/profile/business', { description: b.description });
    for (const it of b.items) db.addItem(userId, { name: it.name, price_cents: Math.round(it.price * 100), currency: b.currency });
    const first = b.items[0];
    const price = Math.max(first.price, 20);
    await call(token, 'POST', '/v1/actions/invoice', { amount: price, currency: b.currency, item: first.name, client_name: b.unpaid });
    const paid = await call(token, 'POST', '/v1/actions/invoice', { amount: Math.max(price, 500), currency: b.currency, item: first.name, client_name: b.paid });
    await call(null, 'POST', '/webhooks/paypal', paidEvent(paid.id), webhookHeaders);
  }

  /** The chips /v1/suggest gives: a client message goes as copied context, an owner message as typed text. */
  async function ask(b: Business, m: Msg): Promise<Chip[]> {
    const token = tokens.get(b.id)!;
    const body = m.from === 'client' ? { text: '', context: m.say } : { text: m.say };
    return (await call(token, 'POST', '/v1/suggest', body)).chips;
  }

  return { open, ask, db };
}
