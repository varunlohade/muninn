import { randomUUID } from 'node:crypto';
import { setup } from './helpers.ts';

// Wed 11 Nov 2026, noon UTC. "Last week" is Mon 2 Nov to Sun 8 Nov.
export const NOW = Date.UTC(2026, 10, 11, 12);
const DAY = 86_400_000;
export const daysAgo = (n: number) => NOW - n * DAY;

type Inv = { client: string; cents: number; item: string; at: number; status?: 'SENT' | 'PAID' | 'REFUNDED' | 'CANCELLED'; email?: string };
type Ord = { client: string; cents: number; item: string; at: number; paid?: boolean };
type Sub = { client: string; cents: number; item: string; at: number; interval: 'week' | 'month'; status: 'ACTIVE' | 'APPROVAL_PENDING' };
export type Business = { invoices?: Inv[]; orders?: Ord[]; subs?: Sub[]; catalog?: [string, number][] };

// Five kinds of business. Each has a Sam-like pair, a two-word name and a mix of states, so one rule set has to fit them all.
export const BUSINESSES: Record<'salon' | 'restaurant' | 'tutor' | 'contractor' | 'shop', Business> = {
  salon: {
    invoices: [
      { client: 'Sam Lee', cents: 12000, item: 'Color', at: daysAgo(2) },
      { client: 'Sam Lee', cents: 4500, item: 'Haircut', at: daysAgo(22), status: 'PAID' },
      { client: 'Sam Lee', cents: 6000, item: 'Blowout', at: daysAgo(50), status: 'PAID' },
      { client: 'Samantha Cruz', cents: 9000, item: 'Bridal trial', at: daysAgo(5), status: 'PAID' },
      { client: 'Jordan Ray', cents: 8000, item: 'Color', at: daysAgo(8) },
      { client: 'Bo Chen', cents: 6000, item: 'Color', at: daysAgo(12), status: 'PAID' },
    ],
    orders: [{ client: 'Ana Lopez', cents: 3500, item: 'Blowout', at: daysAgo(7), paid: true }],
    catalog: [['Haircut', 45], ['Balayage', 180], ['Blowout', 35]],
  },
  restaurant: {
    invoices: [{ client: 'Theo Park', cents: 85000, item: 'Catering for 40', at: daysAgo(3) }],
    orders: [
      { client: 'Maria Gomez', cents: 6400, item: 'Table for 4', at: daysAgo(1), paid: true },
      { client: 'Maria Gomez', cents: 3200, item: 'Takeout', at: daysAgo(15), paid: true },
      { client: 'Kenji Sato', cents: 4800, item: 'Delivery', at: daysAgo(2) },
    ],
    catalog: [['Pad thai', 16], ['Tasting menu', 95]],
  },
  tutor: {
    invoices: [
      { client: 'Leo Martins', cents: 7500, item: 'Math session', at: daysAgo(4) },
      { client: 'Leo Martins', cents: 7500, item: 'Math session', at: daysAgo(11), status: 'PAID' },
      { client: 'Noor Haddad', cents: 6000, item: 'SAT class', at: daysAgo(9), status: 'PAID' },
    ],
    subs: [{ client: 'Priya Shah', cents: 20000, item: 'Weekly lessons', at: daysAgo(20), interval: 'month', status: 'ACTIVE' }],
    catalog: [['Math session', 75], ['SAT class', 60]],
  },
  contractor: {
    invoices: [
      { client: 'Dave Miller', cents: 240000, item: 'Kitchen tiles', at: daysAgo(6) },
      { client: 'Dave Miller', cents: 50000, item: 'Deposit', at: daysAgo(30), status: 'PAID' },
      { client: 'Rosa Diaz', cents: 65000, item: 'Deck repair', at: daysAgo(14), status: 'PAID' },
      { client: 'Ellis Grant', cents: 30000, item: 'Fence quote', at: daysAgo(40), status: 'CANCELLED' },
    ],
    catalog: [['Hourly labor', 85]],
  },
  shop: {
    invoices: [{ client: 'Zoe Adams', cents: 5500, item: 'Candle set', at: daysAgo(10), status: 'REFUNDED' }],
    orders: [
      { client: 'Chloe Kim', cents: 3900, item: 'Mug', at: daysAgo(3), paid: true },
      { client: 'Marcus Bell', cents: 12000, item: 'Lamp', at: daysAgo(1) },
    ],
    catalog: [['Candle set', 55], ['Mug', 39], ['Lamp', 120]],
  },
};

/** One owner with `biz` stored the way real actions store it: names encrypted, ids from PayPal. */
export function seeded(biz: Business, opts: Parameters<typeof setup>[0] = {}) {
  const s = setup({ now: () => NOW, ...opts });
  const { userId, token } = s.device();
  const enc = (v: string) => s.cipher.encrypt(userId, v);
  const ids: Record<string, string> = {};
  for (const i of biz.invoices ?? []) {
    const id = `INV2-${randomUUID().slice(0, 8)}`;
    ids[`${i.client}:${i.cents}`] ??= id;
    s.db.insertInvoice({
      id, user_id: userId, status: 'SENT', amount_cents: i.cents, currency: 'USD', item: i.item, client_name_enc: enc(i.client),
      client_email_enc: i.email ? enc(i.email) : null, pay_link: `https://paypal.test/inv/${id}`, due_at: i.at + 7 * DAY, created_at: i.at,
    });
    if (i.status && i.status !== 'SENT') s.db.setInvoiceStatus(userId, id, i.status, i.status === 'CANCELLED' ? null : i.at + DAY, i.status === 'CANCELLED' ? null : `CAP-${id}`);
  }
  for (const o of biz.orders ?? []) {
    const id = `ORDER-${randomUUID().slice(0, 8)}`;
    s.db.insertOrder({ id, user_id: userId, status: 'CREATED', amount_cents: o.cents, currency: 'USD', item: o.item, client_name_enc: enc(o.client), approve_link: `https://paypal.test/approve/${id}`, created_at: o.at });
    if (o.paid) s.db.setOrderStatus(userId, id, 'COMPLETED', o.at + 3_600_000, `CAP-${id}`);
  }
  for (const u of biz.subs ?? []) {
    const id = `I-${randomUUID().slice(0, 8)}`;
    s.db.insertSubscription({
      id, user_id: userId, status: u.status, amount_cents: u.cents, currency: 'USD', interval: u.interval, item: u.item, client_name_enc: enc(u.client),
      client_email_enc: null, approve_link: `https://paypal.test/sub/${id}`, plan_id: 'P-1', created_at: u.at,
    });
  }
  for (const [name, price] of biz.catalog ?? []) s.db.addItem(userId, { name, price_cents: price * 100, currency: 'USD' });
  const suggest = async (text: string) => (await s.call(token, 'POST', '/v1/suggest', { text })).json();
  const ask = async (text: string) => (await s.call(token, 'POST', '/v1/ask', { text })).json();
  /** The lookup chip for typed text, or undefined. */
  const lookup = async (text: string) => ((await suggest(text)).chips as { kind: string; label: string; payload: any; trigger?: string }[]).find((c) => c.kind === 'lookup');
  return { s, userId, token, suggest, ask, lookup, ids };
}
