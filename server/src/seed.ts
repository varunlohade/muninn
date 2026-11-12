import type { Cipher } from './crypto.ts';
import { randomToken, sha256 } from './crypto.ts';
import type { Db, InvoiceRow } from './db.ts';
import type { PayPal } from './paypal.ts';
import { centsToValue } from './money.ts';

// The "Muninn" demo: a freelance hair stylist who also does brand design.
// Every invoice is a real sandbox PayPal invoice. "Paid" ones use PayPal's record-payment API,
// so no PayPal money moves; they show as paid_via: recorded_payment.
const DAY = 86_400_000;
export const DEMO_LABEL = 'muninn-demo';
export const DEMO_REFERENCE = 'muninn-demo-seed';

export const DEMO_PROFILE = { business_name: 'Rae Okafor Hair & Design', tone: 'warm, brief, uses first names', currency: 'USD' };

export const DEMO_CATALOG: { name: string; price: number; description: string; category: string }[] = [
  { name: 'Haircut', price: 45, description: 'Wash, cut and style', category: 'Hair' },
  { name: 'Blowout', price: 35, description: 'Wash and blow-dry', category: 'Hair' },
  { name: 'Color', price: 120, description: 'All-over color, one shade', category: 'Color' },
  { name: 'Balayage', price: 180, description: 'Hand-painted highlights', category: 'Color' },
  { name: 'Bridal trial', price: 90, description: 'Try your wedding look', category: 'Hair' },
  { name: 'Logo design', price: 350, description: 'Three ideas, two rounds of changes', category: 'Design' },
  { name: 'Brand kit', price: 600, description: 'Logo, colors and fonts', category: 'Design' },
  { name: 'Social templates', price: 150, description: '10 post templates', category: 'Design' },
];

const CLIENTS = {
  maya: ['Maya Lopez', 'maya.lopez@example.com'], jordan: ['Jordan Ray', 'jordan.ray@example.com'],
  priya: ['Priya Shah', 'priya.shah@example.com'], leo: ['Leo Martins', 'leo.martins@example.com'],
  ava: ['Ava Chen', 'ava.chen@example.com'], sam: ['Sam Okafor', 'sam.okafor@example.com'],
  noor: ['Noor Haddad', 'noor.haddad@example.com'], ellis: ['Ellis Grant', 'ellis.grant@example.com'],
} as const;

// dueInDays counts from today, so negative values make an overdue invoice.
type Spec = {
  key: string; client: keyof typeof CLIENTS; item: string;
  issuedDaysAgo: number; dueInDays: number; paidDaysAgo?: number; method?: 'CASH' | 'BANK_TRANSFER';
};

// Offsets are relative to the first run. A re-run reuses what exists and only finishes missing steps.
export const DEMO_INVOICES: Spec[] = [
  { key: 'maya-color', client: 'maya', item: 'Color', issuedDaysAgo: 0, dueInDays: 7, paidDaysAgo: 0, method: 'CASH' },
  { key: 'priya-haircut', client: 'priya', item: 'Haircut', issuedDaysAgo: 0, dueInDays: 7, paidDaysAgo: 0, method: 'CASH' },
  { key: 'leo-logo', client: 'leo', item: 'Logo design', issuedDaysAgo: 5, dueInDays: 7, paidDaysAgo: 1, method: 'BANK_TRANSFER' },
  { key: 'ava-balayage', client: 'ava', item: 'Balayage', issuedDaysAgo: 2, dueInDays: 7, paidDaysAgo: 2, method: 'CASH' },
  { key: 'maya-haircut', client: 'maya', item: 'Haircut', issuedDaysAgo: 4, dueInDays: 7, paidDaysAgo: 4, method: 'CASH' },
  { key: 'noor-templates', client: 'noor', item: 'Social templates', issuedDaysAgo: 8, dueInDays: 7, paidDaysAgo: 6, method: 'BANK_TRANSFER' },
  { key: 'sam-brandkit', client: 'sam', item: 'Brand kit', issuedDaysAgo: 1, dueInDays: 3 },
  { key: 'ellis-bridal', client: 'ellis', item: 'Bridal trial', issuedDaysAgo: 0, dueInDays: 5 },
  { key: 'priya-blowout', client: 'priya', item: 'Blowout', issuedDaysAgo: 2, dueInDays: 2 },
  { key: 'jordan-color', client: 'jordan', item: 'Color', issuedDaysAgo: 11, dueInDays: -4 },
  { key: 'ellis-haircut', client: 'ellis', item: 'Haircut', issuedDaysAgo: 9, dueInDays: -2 },
  { key: 'leo-templates', client: 'leo', item: 'Social templates', issuedDaysAgo: 16, dueInDays: -6 },
];

// --refresh-today: two walk-ins paid today, picked by date, so each demo day has fresh "earned today" numbers.
const TODAY_POOL: Pick<Spec, 'client' | 'item' | 'method'>[] = [
  { client: 'maya', item: 'Blowout', method: 'CASH' }, { client: 'ava', item: 'Haircut', method: 'CASH' },
  { client: 'noor', item: 'Color', method: 'CASH' }, { client: 'sam', item: 'Haircut', method: 'CASH' },
  { client: 'priya', item: 'Bridal trial', method: 'CASH' }, { client: 'jordan', item: 'Blowout', method: 'CASH' },
  { client: 'leo', item: 'Haircut', method: 'CASH' },
];
export function todaySpecs(now: number): Spec[] {
  const day = Math.floor(now / DAY);
  return [0, 1].map((n) => ({
    ...TODAY_POOL[(day * 2 + n) % TODAY_POOL.length], key: `today-${ymd(now)}-${n + 1}`, issuedDaysAgo: 0, dueInDays: 7, paidDaysAgo: 0,
  }));
}

const ymd = (t: number) => new Date(t).toISOString().slice(0, 10);
const startOfDay = (t: number) => Date.parse(`${ymd(t)}T00:00:00Z`);

// Finds the demo user by its device label, or creates it. The token comes back only on creation; only its hash is stored.
export function ensureDemoUser(db: Db): { userId: string; token: string | null } {
  const existing = db.userForDeviceLabel(DEMO_LABEL);
  if (existing) return { userId: existing, token: null };
  const userId = db.createUser();
  const token = randomToken('pkd');
  db.addDevice(userId, sha256(token), DEMO_LABEL);
  return { userId, token };
}

export type SeedResult = { created: number; recorded: number; reused: number };

export async function seedDemo(o: { db: Db; cipher: Cipher; paypal: PayPal; userId: string; now: number; specs?: Spec[] }): Promise<SeedResult> {
  const { db, cipher, paypal, userId, now } = o;
  db.putProfile(userId, DEMO_PROFILE);
  const have = new Set(db.listItems(userId).map((i) => i.name));
  for (const it of DEMO_CATALOG) if (!have.has(it.name)) db.addItem(userId, { name: it.name, price_cents: it.price * 100, currency: 'USD', description: it.description, category: it.category });

  const price = new Map(DEMO_CATALOG.map((i) => [i.name, i.price * 100]));
  const out: SeedResult = { created: 0, recorded: 0, reused: 0 };
  for (const s of o.specs ?? DEMO_INVOICES) {
    const [name, email] = CLIENTS[s.client];
    const cents = price.get(s.item)!;
    const requestId = sha256(`${DEMO_REFERENCE}:${userId}:${s.key}`).slice(0, 36);
    let row = db.invoiceBySeedKey(userId, s.key);
    if (row) out.reused++;
    else {
      const issued = startOfDay(now - s.issuedDaysAgo * DAY);
      const dueDate = ymd(startOfDay(now) + s.dueInDays * DAY);
      const inv = await paypal.createDatedInvoice({
        value: centsToValue(cents), currency: 'USD', item: s.item, clientName: name, clientEmail: email,
        businessName: DEMO_PROFILE.business_name, invoiceDate: ymd(issued), dueDate, reference: DEMO_REFERENCE,
        invoiceNumber: `MD-${requestId.slice(0, 12).toUpperCase()}`,
      }, requestId);
      // Late is measured from the end of the PayPal due date.
      db.insertInvoice({
        id: inv.id, user_id: userId, status: inv.status, amount_cents: cents, currency: 'USD', item: s.item,
        client_name_enc: cipher.encrypt(userId, name), client_email_enc: cipher.encrypt(userId, email), pay_link: inv.payLink,
        due_at: Date.parse(`${inv.dueDate}T00:00:00Z`) + DAY, created_at: issued, source: 'demo_seed', seed_key: s.key,
      });
      row = db.invoiceBySeedKey(userId, s.key)!;
      out.created++;
    }
    if (s.paidDaysAgo !== undefined && !row.paid_at) {
      const paidAt = s.paidDaysAgo === 0 ? Math.max(startOfDay(now) + 60_000, now - 2 * 3600_000) : startOfDay(now - s.paidDaysAgo * DAY) + 15 * 3600_000;
      await paypal.recordPayment(row.id, {
        date: ymd(paidAt), value: centsToValue(cents), currency: 'USD', method: s.method ?? 'CASH', note: `${DEMO_REFERENCE}: recorded payment`,
      }, `${requestId}-pay`);
      // No PayPal capture exists for a recorded payment, so capture_id stays null and it cannot be refunded through PayPal.
      db.setInvoiceStatus(userId, row.id, 'MARKED_AS_PAID', paidAt, null);
      out.recorded++;
    }
  }
  return out;
}

// --history: six full months and this month so far of recorded payments, a rising trend with noise, for the chart's
// projection. Demo user only: onNewUser never calls this, so a new user starts without it. Local rows only (no PayPal
// invoice exists), so nothing here can be reminded, taken back or refunded through PayPal.
export const HISTORY_MONTHS = 6;
// Each month's refunded sale, by months before this one: the first sale of that month, refunded in full.
const HISTORY_REFUNDS = [4, 2];
const pick = (key: string) => parseInt(sha256(key).slice(0, 8), 16) / 2 ** 32;

export type HistoryResult = { created: number; reused: number; refunds: number };

export function seedDemoHistory(o: { db: Db; cipher: Cipher; userId: string; now: number }): HistoryResult {
  const { db, cipher, userId, now } = o;
  const out: HistoryResult = { created: 0, reused: 0, refunds: 0 };
  const today = startOfDay(now);
  const d = new Date(now);
  const clients = Object.keys(CLIENTS) as (keyof typeof CLIENTS)[];
  for (let back = HISTORY_MONTHS; back >= 0; back--) {
    const first = Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - back, 1);
    const month = ymd(first).slice(0, 7);
    // About $2,000 six months ago, rising to about $3,500 last month, give or take 10%.
    const target = Math.round((2000 + 300 * (HISTORY_MONTHS - back)) * (0.9 + 0.2 * pick(`${month}:target`))) * 100;
    let sum = 0;
    for (let n = 0; n < 80 && target - sum >= 3500; n++) {
      const key = `hist-${month}-${n}`;
      const item = DEMO_CATALOG[Math.floor(pick(`${key}:item`) * DEMO_CATALOG.length)];
      const cents = item.price * 100;
      if (sum + cents > target) continue;
      sum += cents;
      const paidAt = first + Math.floor(pick(`${key}:day`) * 27) * DAY + 15 * 3600_000;
      // This month: only the days already gone.
      if (paidAt >= today) continue;
      if (db.invoiceBySeedKey(userId, key)) { out.reused++; continue; }
      const [name, email] = CLIENTS[clients[Math.floor(pick(`${key}:client`) * clients.length)]];
      const id = `DEMO-HIST-${sha256(`${DEMO_REFERENCE}:${userId}:${key}`).slice(0, 16).toUpperCase()}`;
      const created = paidAt - Math.floor(pick(`${key}:wait`) * 4) * DAY;
      db.insertInvoice({
        id, user_id: userId, status: 'MARKED_AS_PAID', amount_cents: cents, currency: 'USD', item: item.name,
        client_name_enc: cipher.encrypt(userId, name), client_email_enc: cipher.encrypt(userId, email), pay_link: null,
        due_at: created + 8 * DAY, created_at: created, source: 'demo_seed', seed_key: key,
      });
      db.setInvoiceStatus(userId, id, 'MARKED_AS_PAID', paidAt, null);
      out.created++;
    }
  }
  for (const back of HISTORY_REFUNDS) {
    const month = ymd(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() - back, 1)).slice(0, 7);
    const inv = db.raw.prepare(`SELECT * FROM invoices WHERE user_id = ? AND seed_key LIKE ? ORDER BY paid_at LIMIT 1`).get(userId, `hist-${month}-%`) as InvoiceRow | undefined;
    if (!inv || db.refundState(userId, inv.id).doneCents > 0) continue;
    db.insertRefund({
      id: `${inv.id}-R`, user_id: userId, target_kind: 'invoice', target_id: inv.id, amount_cents: inv.amount_cents, currency: 'USD',
      capture_id: 'recorded_payment', token_hash: sha256(`${DEMO_REFERENCE}:refund:${inv.id}`), expires_at: 0, status: 'done',
    });
    db.raw.prepare('UPDATE refunds SET created_at = ? WHERE id = ?').run(inv.paid_at! + 3 * DAY, `${inv.id}-R`);
    out.refunds++;
  }
  return out;
}
