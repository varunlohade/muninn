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

// What each demo invoice costs. Only invoices use these; nothing is stored as a product list.
export const DEMO_PRICES: { name: string; price: number }[] = [
  { name: 'Haircut', price: 45 }, { name: 'Blowout', price: 35 }, { name: 'Color', price: 120 }, { name: 'Balayage', price: 180 },
  { name: 'Bridal trial', price: 90 }, { name: 'Logo design', price: 350 }, { name: 'Brand kit', price: 600 }, { name: 'Social templates', price: 150 },
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
  const price = new Map(DEMO_PRICES.map((i) => [i.name, i.price * 100]));
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
      const item = DEMO_PRICES[Math.floor(pick(`${key}:item`) * DEMO_PRICES.length)];
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

// ---- Demo shots: the PayPal state the recorded demo needs, on the demo user only. Safe to re-run.
// 1. One clear open invoice for Sam; Sam's other open demo invoices are cancelled (no email goes out).
// 2. One PayPal payment from Sam that can be refunded: a $45 pay link a sandbox buyer approves, then captured.
// 3. An ACTIVE $40/month repeat bill for Ana, after a sandbox buyer approves it.
// Steps 2 and 3 need a buyer's approval in the sandbox: the first run prints the link, a re-run finishes the step.
export const SHOT_SAM: readonly [string, string] = CLIENTS.sam;
export const SHOT_ANA: readonly [string, string] = ['Ana Ruiz', 'ana.ruiz@example.com'];
const SHOT_INVOICE_KEY = 'shot-sam-haircut';
const OPEN_PLAN = ['ACTIVE', 'SUSPENDED', 'APPROVAL_PENDING'];

export async function demoShots(o: { db: Db; cipher: Cipher; paypal: PayPal; userId: string; now: number; dryRun: boolean }): Promise<string[]> {
  const { db, cipher, paypal, userId, now, dryRun } = o;
  const out: string[] = [];
  const say = (line: string) => out.push(`${dryRun ? 'DRY ' : ''}${line}`);
  const nameOf = (enc: string | null) => (enc ? cipher.decrypt(userId, enc) : null);
  // "Sam" or "Sam Okafor": the first name is what the owner types.
  const isSam = (enc: string | null) => nameOf(enc)?.trim().split(/\s+/)[0].toLowerCase() === 'sam';
  const reqId = (key: string) => sha256(`${userId}:${key}`).slice(0, 36);
  const [sam, samEmail] = SHOT_SAM;
  const [ana, anaEmail] = SHOT_ANA;

  // 1. Sam's one clear open invoice.
  let shot = db.invoiceBySeedKey(userId, SHOT_INVOICE_KEY);
  if (shot && !shot.paid_at && shot.status !== 'CANCELLED') say(`sam invoice: ok ${shot.id} $45 Haircut (${shot.status})`);
  else if (shot) say(`sam invoice: ${shot.id} is ${shot.status}; delete its row or mark it unpaid to reuse it`);
  else if (dryRun) say('sam invoice: would create a $45 Haircut invoice for Sam Okafor (no email)');
  else {
    const requestId = reqId(`demo-shot:${SHOT_INVOICE_KEY}`);
    const inv = await paypal.createDatedInvoice({
      value: '45.00', currency: 'USD', item: 'Haircut', clientName: sam, clientEmail: samEmail, businessName: DEMO_PROFILE.business_name,
      invoiceDate: ymd(now), dueDate: ymd(now + 7 * DAY), reference: DEMO_REFERENCE, invoiceNumber: `MD-${requestId.slice(0, 12).toUpperCase()}`,
    }, requestId);
    db.insertInvoice({
      id: inv.id, user_id: userId, status: inv.status, amount_cents: 4500, currency: 'USD', item: 'Haircut',
      client_name_enc: cipher.encrypt(userId, sam), client_email_enc: cipher.encrypt(userId, samEmail), pay_link: inv.payLink,
      due_at: Date.parse(`${inv.dueDate}T00:00:00Z`) + DAY, created_at: now, source: 'demo_seed', seed_key: SHOT_INVOICE_KEY,
    });
    shot = db.invoiceBySeedKey(userId, SHOT_INVOICE_KEY)!;
    say(`sam invoice: created ${shot.id} $45 Haircut`);
  }
  // Sam's other open invoices on the demo merchant. A connected account's rows (pp_account set) are never touched.
  const extra = db.listInvoices(userId, 1000).filter((r) => r.id !== shot?.id && !r.paid_at && !['CANCELLED', 'REFUNDED'].includes(r.status)
    && r.pp_account === null && isSam(r.client_name_enc));
  for (const r of extra) {
    if (dryRun) { say(`sam extra: would cancel ${r.id} ${centsToValue(r.amount_cents)} ${r.item}`); continue; }
    if (r.id.startsWith('INV2-')) {
      const now2 = await paypal.getInvoice(r.id);
      if (now2.status !== 'CANCELLED') await paypal.cancelInvoice(r.id, false, reqId(`demo-shot:cancel:${r.id}`));
    }
    db.setInvoiceStatus(userId, r.id, 'CANCELLED', null, null);
    say(`sam extra: cancelled ${r.id} ${centsToValue(r.amount_cents)} ${r.item}`);
  }
  if (!extra.length) say('sam extra: none open');

  // 2. A refundable PayPal payment from Sam: a captured pay link (an order), or an invoice paid through PayPal.
  const samRows = [...db.listInvoices(userId, 1000), ...db.listOrders(userId, 1000)].filter((r) => r.pp_account === null && isSam(r.client_name_enc));
  const refundable = samRows.find((r) => r.paid_at && r.capture_id && r.capture_id !== 'recorded_payment' && !['REFUNDED'].includes(r.status));
  const pending = db.listOrders(userId, 1000).find((r) => r.pp_account === null && isSam(r.client_name_enc) && !r.paid_at && ['CREATED', 'APPROVED'].includes(r.status));
  if (refundable) say(`sam payment: ok ${refundable.id} ${centsToValue(refundable.amount_cents)} captured (${refundable.capture_id})`);
  else if (pending && dryRun) say(`sam payment: would try to capture ${pending.id}; if not approved yet, approve it here with a sandbox buyer: ${pending.approve_link}`);
  else if (pending) {
    try {
      const cap = await paypal.captureOrder(pending.id, `capture-${pending.id}`);
      db.setOrderStatus(userId, pending.id, cap.status, cap.status === 'COMPLETED' ? now : null, cap.captureId);
      say(`sam payment: captured ${pending.id} (${cap.status}, ${cap.captureId})`);
    } catch (e) {
      say(`sam payment: ${pending.id} not approved yet (${(e as Error).message}). Approve with a sandbox buyer, then re-run: ${pending.approve_link}`);
    }
  } else if (dryRun) say('sam payment: would make a $45 Haircut pay link for Sam Okafor and print its approve link');
  else {
    const order = await paypal.createOrder({ value: '45.00', currency: 'USD', item: 'Haircut' }, reqId('demo-shot:sam-order'));
    db.insertOrder({
      id: order.id, user_id: userId, status: order.status, amount_cents: 4500, currency: 'USD', item: 'Haircut',
      client_name_enc: cipher.encrypt(userId, sam), approve_link: order.approveLink, created_at: now,
    });
    say(`sam payment: made ${order.id}. Approve with a sandbox buyer, then re-run: ${order.approveLink}`);
  }

  // 3. Ana's $40 monthly repeat bill.
  const plans = db.listSubscriptions(userId, 1000).filter((r) => r.pp_account === null && nameOf(r.client_name_enc) === ana
    && r.amount_cents === 4000 && r.currency === 'USD' && r.interval === 'month' && OPEN_PLAN.includes(r.status));
  const plan = plans.find((r) => r.status === 'ACTIVE') ?? plans.find((r) => r.status === 'SUSPENDED') ?? plans[0];
  if (plan?.status === 'ACTIVE') say(`ana plan: ok ${plan.id} $40/mo ACTIVE`);
  else if (plan?.status === 'SUSPENDED') say(`ana plan: ${plan.id} is paused; say "resume ana's plan" to restart it`);
  else if (plan && dryRun) say(`ana plan: would check ${plan.id} on PayPal; if not approved yet, approve it with a sandbox buyer: ${plan.approve_link}`);
  else if (plan) {
    const st = await paypal.getSubscription(plan.id);
    if (st.status === 'ACTIVE') {
      db.setSubscriptionActive(userId, plan.id, now);
      say(`ana plan: ${plan.id} is ACTIVE now`);
    } else say(`ana plan: ${plan.id} is ${st.status}. Approve with a sandbox buyer, then re-run: ${plan.approve_link}`);
  } else if (dryRun) say('ana plan: would make a $40/mo repeat bill for Ana Ruiz and print its approve link');
  else {
    const planKey = 'USD:4000:month';
    const cached = db.getBillingPlan(userId, planKey);
    const sub = await paypal.createSubscription({
      value: '40.00', currency: 'USD', interval: 'month', clientEmail: null,
      productId: cached?.product_id ?? db.anyBillingProduct(userId), planId: cached?.plan_id ?? null,
      productRequestId: reqId('billing-product'), planRequestId: reqId(`billing-plan:${planKey}`),
    }, reqId('demo-shot:ana-plan'));
    db.putBillingPlan(userId, planKey, sub.productId, sub.planId);
    db.insertSubscription({
      id: sub.id, user_id: userId, status: sub.status, amount_cents: 4000, currency: 'USD', interval: 'month', item: 'Repeat payment',
      client_name_enc: cipher.encrypt(userId, ana), client_email_enc: cipher.encrypt(userId, anaEmail), approve_link: sub.approveLink,
      plan_id: sub.planId, created_at: now,
    });
    say(`ana plan: made ${sub.id} (${sub.status}). Approve with a sandbox buyer, then re-run: ${sub.approveLink}`);
  }
  return out;
}
