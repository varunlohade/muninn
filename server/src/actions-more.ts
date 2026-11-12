// PayPal actions beyond invoices, pay links and refunds. Chips come from plain regex and the owner's own records,
// never from a model. Every action sits under /v1/actions/*, so it gets the tap gate and the per-chip idempotency key.
//
// One grammar: chip "<Verb> <money> · <who>", one confirm question, a done line, and Undo only when PayPal can undo.
// An action chip's payload is { body, confirm, question }: the phone sends `body`, adds `confirm` after the owner's
// confirm tap, and shows `question` on that tap. The server checks every confirm value against its own records
// and answers 409 needs_confirm on any mismatch.
import type { Context, Hono } from 'hono';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Chip, Env } from './app.ts';
import type { createBusiness } from './business.ts';
import type { Db, InvoiceRow, SubscriptionRow } from './db.ts';
import { config } from './config.ts';
import { log } from './log.ts';
import { Amount, Currency, centsToValue, formatMoney, valueToCents } from './money.ts';
import { PayPalError, type PayPalProvider } from './paypal.ts';
import {
  balanceAsk, chartAsk, disputeVerb, invoiceVerb, mentions, payoutAsk, planVerb, quick, type DisputeVerb, type InvoiceVerb, type PayoutAsk, type PlanVerb,
} from './quick.ts';
import { clean } from './text.ts';

export type MoreDeps = {
  db: Db; paypal: PayPalProvider; biz: ReturnType<typeof createBusiness>; now: () => number;
  dec: (userId: string, v: string | null) => string | null;
  enc: (userId: string, v: string | null | undefined) => string | null;
  body: <T extends z.ZodTypeAny>(c: Context<Env>, schema: T) => Promise<z.infer<T>>;
  fail: (status: 400 | 404 | 409, message: string) => Error;
  requestIdFor: (userId: string, key: string) => string;
  /** The account key new PayPal objects carry: the connected seller's, or null for the demo merchant. */
  accountOf: (userId: string) => string | null;
};

const PER: Record<string, string> = { week: '/wk', month: '/mo', year: '/yr' };
const EVERY: Record<string, string> = { week: 'weekly', month: 'monthly', year: 'yearly' };
const PLAN_STATE: Record<string, string> = { ACTIVE: 'active', SUSPENDED: 'paused', APPROVAL_PENDING: 'waiting for approval', CANCELLED: 'ended' };
const OPEN_PLAN = ['ACTIVE', 'SUSPENDED', 'APPROVAL_PENDING'];

const ConfirmName = z.string().trim().min(1).max(100);
const PlanBody = z.object({
  subscription_id: z.string().regex(/^I-[A-Z0-9]{4,40}$/),
  confirm_client: ConfirmName.optional(), confirm_amount: Amount.optional(), confirm_currency: Currency.optional(),
  // Set only on an Undo chip's body: after this time (ms) the Undo no longer works.
  undo_by: z.number().int().positive().optional(),
}).strict();
const UNDO_TTL_MS = 10 * 60 * 1000;

const InvoiceId = z.string().regex(/^INV2-[A-Z0-9-]{4,60}$/);
const Method = z.enum(['CASH', 'CHECK', 'BANK_TRANSFER', 'WIRE_TRANSFER', 'CREDIT_CARD', 'DEBIT_CARD', 'OTHER']);
const InvoiceConfirm = { confirm_client: ConfirmName.optional(), confirm_amount: Amount.optional(), confirm_currency: Currency.optional() };
const MarkPaidBody = z.object({ invoice_id: InvoiceId, method: Method.default('OTHER'), ...InvoiceConfirm }).strict();
const InvoiceOnlyBody = z.object({ invoice_id: InvoiceId, ...InvoiceConfirm }).strict();
const RecordRefundBody = z.object({ invoice_id: InvoiceId, amount: Amount, method: Method.default('OTHER'), ...InvoiceConfirm }).strict();
const Email = z.string().trim().toLowerCase().email().max(254);
// The strongest confirm: who, how much and which currency, each checked against the body.
const PayoutBody = z.object({
  recipient_name: ConfirmName, recipient_email: Email, amount: Amount, currency: Currency,
  note: z.string().transform(clean).pipe(z.string().min(1).max(100)).optional(),
  confirm_recipient: Email.optional(), confirm_amount: Amount.optional(), confirm_currency: Currency.optional(),
}).strict();
const PayoutCancelBody = z.object({ payout_id: z.string().uuid() }).strict();
const DisputeId = z.string().regex(/^PP-[A-Z0-9-]{3,40}$/);
const DisputeReplyBody = z.object({
  dispute_id: DisputeId, message: z.string().transform(clean).pipe(z.string().min(1).max(2000)), confirm_client: ConfirmName.optional(),
}).strict();
const DisputeAcceptBody = z.object({ dispute_id: DisputeId, ...InvoiceConfirm }).strict();
const DisputeOfferBody = z.object({ dispute_id: DisputeId, amount: Amount, currency: Currency, ...InvoiceConfirm }).strict();
// Not sent, or sent back: these no longer count toward the day's cap.
const PAYOUT_GONE = ['FAILED', 'RETURNED', 'REFUNDED', 'REVERSED', 'BLOCKED', 'DENIED', 'CANCELED'];

// Payments and refunds the owner recorded through Muninn, so Undo and "what is left" never guess.
const TABLES = `
CREATE TABLE IF NOT EXISTS recorded_payments (
  user_id TEXT NOT NULL REFERENCES users(id), invoice_id TEXT NOT NULL, payment_id TEXT NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, invoice_id));
CREATE TABLE IF NOT EXISTS payouts (
  id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name_enc TEXT NOT NULL, email_enc TEXT NOT NULL,
  amount_cents INTEGER NOT NULL, currency TEXT NOT NULL, status TEXT NOT NULL, batch_id TEXT, item_id TEXT, created_at INTEGER NOT NULL,
  pp_account TEXT);
CREATE INDEX IF NOT EXISTS payouts_user ON payouts(user_id, created_at);
CREATE TABLE IF NOT EXISTS recorded_refunds (
  refund_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), invoice_id TEXT NOT NULL, amount_cents INTEGER NOT NULL, created_at INTEGER NOT NULL);
`;

export function createMore(d: MoreDeps) {
  const { db } = d;
  db.raw.exec(TABLES);
  // pp_account: the connected account that sent the payout, or NULL for the demo merchant. Undo runs on the same one.
  const payoutCols = db.raw.prepare('PRAGMA table_info(payouts)').all() as { name: string }[];
  if (!payoutCols.some((c) => c.name === 'pp_account')) db.raw.exec('ALTER TABLE payouts ADD COLUMN pp_account TEXT');
  const sql = (s: string) => db.raw.prepare(s);

  const chip = (kind: string, label: string, payload: Record<string, unknown>, needsConfirm: boolean): Chip =>
    ({ kind, label: clean(label), payload, needs_confirm: needsConfirm });
  const actionChip = (kind: string, label: string, body: Record<string, unknown>, confirm: Record<string, unknown>, question: string) =>
    chip(kind, label, { body, confirm, question }, true);
  /** Undo sits beside the done line. Its body already holds the values the owner just confirmed. */
  const undoChip = (kind: string, body: Record<string, unknown>) => chip(kind, 'Undo', { body, confirm: {}, question: '' }, false);
  /** A chip that only puts one line in the bar: a list, a status, or why there is no action. */
  const lineChip = (label: string, line: string) => chip('show', label, { line }, false);

  const userOf = (c: Context<Env>) => c.get('userId');
  const idemKey = (c: Context<Env>) => d.requestIdFor(userOf(c), c.req.header('idempotency-key')!);
  const needsConfirm = (c: Context<Env>, recipient: string) => {
    c.set('idemSkip', true);
    return c.json({ error: 'confirm first', needs_confirm: true, recipient }, 409);
  };
  /** The confirm named this client: its shown name or its stored name, case-insensitive. */
  const sameName = (confirmed: string | undefined, names: (string | null)[]) =>
    !!confirmed && names.some((n) => !!n && n.trim().toLowerCase() === confirmed.trim().toLowerCase());
  /** Rows whose client the owner named, by full or first name. */
  const namedIn = <T>(text: string, rows: T[], nameOf: (r: T) => string | null) =>
    rows.filter((r) => {
      const n = nameOf(r);
      return !!n && (mentions(text, n) || mentions(text, n.split(/\s+/)[0]));
    });

  // ---- repeat bills
  const planMoney = (r: SubscriptionRow) => `${formatMoney(r.amount_cents, r.currency)}${PER[r.interval] ?? ''}`;
  const planConfirm = (r: SubscriptionRow, name: string) =>
    ({ confirm_client: name, confirm_amount: centsToValue(r.amount_cents), confirm_currency: r.currency });

  function planChips(userId: string, text: string, verb: PlanVerb): Chip[] | null {
    const nameOf = d.biz.namer(userId);
    const open = db.listSubscriptions(userId, 200).filter((r) => OPEN_PLAN.includes(r.status));
    if (verb === 'list') {
      if (!open.length) return [lineChip('Repeat bills · none yet', 'No repeat bills yet. Try: bill Sam $40 monthly')];
      const rank = (r: SubscriptionRow) => OPEN_PLAN.indexOf(r.status);
      const parts = [...open].sort((a, b) => rank(a) - rank(b)).map((r) =>
        `${nameOf(r) ?? r.item} ${planMoney(r)}${r.status === 'ACTIVE' ? '' : r.status === 'SUSPENDED' ? ' paused' : ' waiting'}`);
      const active = open.filter((r) => r.status === 'ACTIVE').length;
      return [lineChip(`Repeat bills · ${active} active`, parts.slice(0, 2).join(', ') + (parts.length > 2 ? ` +${parts.length - 2}` : ''))];
    }
    let hits = namedIn(text, open, nameOf);
    // Two plans for one client: a typed amount picks one; otherwise nothing is guessed.
    const typed = quick(text).amount;
    if (hits.length > 1 && typed !== null) hits = hits.filter((r) => r.amount_cents === Math.round(typed * 100));
    if (!hits.length) return null;
    const first = nameOf(hits[0]) ?? 'This client';
    if (hits.length > 1) return [lineChip(`${first} has ${hits.length} repeat bills`, `${first} has ${hits.length} repeat bills. Add the amount, like "pause ${first.split(' ')[0]}'s ${formatMoney(hits[0].amount_cents, hits[0].currency)} plan".`)];
    const r = hits[0];
    const name = first;
    const money = planMoney(r);
    const bill = `${name}'s ${formatMoney(r.amount_cents, r.currency)} ${EVERY[r.interval] ?? ''} bill`.replace(/\s+/g, ' ');
    const body = { subscription_id: r.id };
    const confirm = planConfirm(r, name);
    if (verb === 'status') return [chip('plan_status', `${name}'s plan · ${PLAN_STATE[r.status] ?? r.status.toLowerCase()}`, { id: r.id }, false)];
    if (r.status === 'APPROVAL_PENDING') return [lineChip(`${name} hasn't approved yet`, `${name} hasn't approved the ${money} plan yet. Nothing bills until then.`)];
    if (verb === 'pause') {
      if (r.status !== 'ACTIVE') return [lineChip(`${name}'s plan is already paused`, `${name}'s ${money} plan is already paused.`)];
      return [actionChip('plan_pause', `Pause ${money} · ${name}`, body, confirm, `Pause ${bill}? PayPal tells ${name}.`)];
    }
    if (verb === 'resume') {
      if (r.status !== 'SUSPENDED') return [lineChip(`${name}'s plan is already on`, `${name}'s ${money} plan is already on.`)];
      return [actionChip('plan_resume', `Resume ${money} · ${name}`, body, confirm, `Restart ${bill}?`)];
    }
    return [actionChip('plan_cancel', `Cancel ${money} · ${name}`, body, confirm, `End ${bill}? Can't undo.`)];
  }

  const syncPlan = (userId: string, id: string, status: string) => {
    if (status === 'ACTIVE') db.setSubscriptionActive(userId, id, d.now());
    else if (status === 'SUSPENDED' || status === 'CANCELLED') db.setSubscriptionStatus(userId, id, status);
  };

  const PLAN_MOVE = {
    suspend: { from: ['ACTIVE'], to: 'SUSPENDED', line: 'Paused ✓', reason: 'Paused by the business', not: 'this repeat bill is not active' },
    activate: { from: ['SUSPENDED'], to: 'ACTIVE', line: 'Restarted ✓', reason: 'Restarted by the business', not: 'this repeat bill is not paused' },
    cancel: { from: ['ACTIVE', 'SUSPENDED'], to: 'CANCELLED', line: 'Ended ✓', reason: 'Ended by the business', not: 'this repeat bill is not running' },
  } as const;

  async function planAction(c: Context<Env>, move: keyof typeof PLAN_MOVE) {
    const userId = userOf(c);
    const b = await d.body(c, PlanBody);
    const r = db.getSubscription(userId, b.subscription_id);
    if (!r) throw d.fail(404, 'repeat bill not found');
    const shown = d.biz.namer(userId)(r);
    if (!sameName(b.confirm_client, [shown, d.dec(userId, r.client_name_enc)]) || b.confirm_amount !== r.amount_cents || b.confirm_currency !== r.currency) {
      return needsConfirm(c, shown ?? 'the client');
    }
    if (b.undo_by !== undefined && d.now() > b.undo_by) throw d.fail(409, 'This Undo has expired. Type "restart" and the plan name to restart it');
    const m = PLAN_MOVE[move];
    const pp = d.paypal.forAccount(userId, r.pp_account);
    // PayPal is the truth: a webhook may not have come in yet.
    const now = await pp.getSubscription(r.id);
    syncPlan(userId, r.id, now.status);
    if (!(m.from as readonly string[]).includes(now.status)) throw d.fail(409, m.not);
    await pp.changeSubscription(r.id, move, m.reason, idemKey(c));
    syncPlan(userId, r.id, m.to);
    log('plan_changed', { user_id: userId, subscription_id: r.id, move });
    const undo = move === 'suspend' ? undoChip('plan_resume', { subscription_id: r.id, ...planConfirm(r, b.confirm_client!), undo_by: d.now() + UNDO_TTL_MS }) : null;
    return c.json({ ok: true, subscription_id: r.id, status: m.to, line: m.line, undo });
  }

  // ---- invoices: mark paid (Undo), cancel, record a refund made outside PayPal
  const openInvoice = (r: InvoiceRow) => !r.paid_at && !['CANCELLED', 'REFUNDED'].includes(r.status);
  const refundedOutside = (userId: string, id: string) =>
    (sql('SELECT COALESCE(SUM(amount_cents), 0) AS c FROM recorded_refunds WHERE user_id = ? AND invoice_id = ?').get(userId, id) as { c: number }).c;
  /** Paid outside PayPal (recorded), so a refund can only be recorded too. A PayPal payment has a capture to refund. */
  const recordedPaid = (r: InvoiceRow) => !r.capture_id && ['MARKED_AS_PAID', 'PARTIALLY_REFUNDED'].includes(r.status);
  const today = () => new Date(d.now()).toISOString().slice(0, 10);

  function invoiceChips(userId: string, text: string, v: InvoiceVerb): Chip[] | null {
    const nameOf = d.biz.namer(userId);
    const all = db.listInvoices(userId, 200);
    const typed = quick(text).amount;
    const cents = typed === null ? null : Math.round(typed * 100);
    if (v.verb === 'record_refund') {
      const paid = namedIn(text, all.filter((r) => r.paid_at && !['REFUNDED', 'MARKED_AS_REFUNDED'].includes(r.status)), nameOf);
      if (!paid.length) return null;
      const r = paid.length === 1 ? paid[0] : null;
      const name = nameOf(paid[0])!;
      if (!r) return [lineChip(`${name} has ${paid.length} paid invoices`, `${name} has ${paid.length} paid invoices. Open ${name} in Muninn to pick one.`)];
      if (!recordedPaid(r)) return [lineChip(`${name} paid by PayPal`, `${name} paid by PayPal. Say "refund ${name.split(' ')[0]} ${formatMoney(cents ?? r.amount_cents, r.currency)}" to send it back.`)];
      const left = r.amount_cents - refundedOutside(userId, r.id);
      const back = cents ?? left;
      if (back > left) return [lineChip(`Only ${formatMoney(left, r.currency)} left`, `Only ${formatMoney(left, r.currency)} of ${name}'s invoice is left to refund.`)];
      const money = formatMoney(back, r.currency);
      return [actionChip('invoice_refund', `Record refund ${money} · ${name}`,
        { invoice_id: r.id, amount: centsToValue(back), method: v.method ?? 'OTHER' },
        { confirm_client: name, confirm_amount: centsToValue(back), confirm_currency: r.currency },
        `Record a ${money}${v.methodWord ? ` ${v.methodWord}` : ''} refund to ${name}? No money moves.`)];
    }
    const open = namedIn(text, all.filter(openInvoice), nameOf).filter((r) => cents === null || r.amount_cents === cents);
    if (!open.length) return null;
    const name = nameOf(open[0])!;
    if (open.length > 1) return [lineChip(`${name} has ${open.length} open invoices`, `${name} has ${open.length} open invoices. Add the amount, like "mark ${name.split(' ')[0]} paid ${formatMoney(open[0].amount_cents, open[0].currency)}".`)];
    const r = open[0];
    const money = formatMoney(r.amount_cents, r.currency);
    const confirm = { confirm_client: name, confirm_amount: centsToValue(r.amount_cents), confirm_currency: r.currency };
    if (v.verb === 'mark_paid') {
      return [actionChip('invoice_mark_paid', `Mark paid ${money} · ${name}`, { invoice_id: r.id, method: v.method ?? 'OTHER' }, confirm,
        `Mark ${name}'s ${money} invoice paid${v.methodWord ? ` (${v.methodWord})` : ''}? No money moves.`)];
    }
    const told = r.client_email_enc ? `PayPal tells ${name}.` : 'No email goes out.';
    return [actionChip('invoice_cancel', `Cancel invoice ${money} · ${name}`, { invoice_id: r.id }, confirm, `Cancel ${name}'s ${money} invoice? ${told} Can't undo.`)];
  }

  /** The invoice and its 409 answer when the confirm did not show this client, amount and currency. */
  type InvoiceConfirmed = { invoice_id: string; confirm_client?: string; confirm_amount?: number; confirm_currency?: string };
  async function invoiceFor<B extends InvoiceConfirmed>(c: Context<Env>, schema: z.ZodType<B>, amountOf: (r: InvoiceRow, b: B) => number) {
    const userId = userOf(c);
    const b = await d.body(c, schema);
    const r = db.getInvoice(userId, b.invoice_id);
    if (!r) throw d.fail(404, 'invoice not found');
    const shown = d.biz.namer(userId)(r);
    const ok = sameName(b.confirm_client, [shown, d.dec(userId, r.client_name_enc)]) && b.confirm_amount === amountOf(r, b) && b.confirm_currency === r.currency;
    return { userId, b, r, refused: ok ? null : needsConfirm(c, shown ?? 'the client') };
  }
  const confirmOf = (r: InvoiceRow, b: { confirm_client?: string }, cents = r.amount_cents) =>
    ({ confirm_client: b.confirm_client, confirm_amount: centsToValue(cents), confirm_currency: r.currency });

  async function markPaid(c: Context<Env>) {
    const { userId, b, r, refused } = await invoiceFor(c, MarkPaidBody, (r) => r.amount_cents);
    if (refused) return refused;
    if (!openInvoice(r)) throw d.fail(409, r.status === 'CANCELLED' ? 'invoice is cancelled' : 'invoice is already paid');
    const out = await d.paypal.forAccount(userId, r.pp_account).recordPayment(r.id, {
      date: today(), value: centsToValue(r.amount_cents), currency: r.currency, method: b.method, note: 'Marked paid in Muninn',
    }, idemKey(c));
    db.setInvoiceStatus(userId, r.id, 'MARKED_AS_PAID', d.now(), null);
    sql('INSERT OR REPLACE INTO recorded_payments (user_id, invoice_id, payment_id, created_at) VALUES (?, ?, ?, ?)').run(userId, r.id, out.paymentId, d.now());
    log('invoice_marked_paid', { user_id: userId, invoice_id: r.id });
    return c.json({ ok: true, invoice_id: r.id, status: 'MARKED_AS_PAID', line: 'Marked paid ✓', undo: undoChip('invoice_unmark', { invoice_id: r.id, ...confirmOf(r, b) }) });
  }

  async function unmarkPaid(c: Context<Env>) {
    const { userId, r, refused } = await invoiceFor(c, InvoiceOnlyBody, (r) => r.amount_cents);
    if (refused) return refused;
    const rec = sql('SELECT payment_id FROM recorded_payments WHERE user_id = ? AND invoice_id = ?').get(userId, r.id) as { payment_id: string } | undefined;
    if (!rec || r.status !== 'MARKED_AS_PAID') throw d.fail(409, 'only a payment marked in Muninn can be taken back');
    const pp = d.paypal.forAccount(userId, r.pp_account);
    await pp.deleteRecordedPayment(r.id, rec.payment_id, idemKey(c));
    const now = await pp.getInvoice(r.id);
    sql('UPDATE invoices SET status = ?, paid_at = NULL WHERE id = ? AND user_id = ?').run(now.status, r.id, userId);
    sql('DELETE FROM recorded_payments WHERE user_id = ? AND invoice_id = ?').run(userId, r.id);
    log('invoice_unmarked', { user_id: userId, invoice_id: r.id });
    return c.json({ ok: true, invoice_id: r.id, status: now.status, line: 'Back to unpaid ✓', undo: null });
  }

  async function cancelInvoice(c: Context<Env>) {
    const { userId, r, refused } = await invoiceFor(c, InvoiceOnlyBody, (r) => r.amount_cents);
    if (refused) return refused;
    if (!openInvoice(r)) throw d.fail(409, r.status === 'CANCELLED' ? 'invoice is already cancelled' : 'invoice is already paid');
    await d.paypal.forAccount(userId, r.pp_account).cancelInvoice(r.id, !!r.client_email_enc, idemKey(c));
    db.setInvoiceStatus(userId, r.id, 'CANCELLED', null, null);
    log('invoice_cancelled', { user_id: userId, invoice_id: r.id });
    return c.json({ ok: true, invoice_id: r.id, status: 'CANCELLED', line: 'Invoice cancelled ✓', undo: null });
  }

  async function recordRefund(c: Context<Env>) {
    const { userId, b, r, refused } = await invoiceFor(c, RecordRefundBody, (_r, b) => b.amount);
    if (refused) return refused;
    if (!recordedPaid(r)) throw d.fail(409, r.paid_at ? 'paid by PayPal: send a refund instead' : 'invoice is not paid');
    const left = r.amount_cents - refundedOutside(userId, r.id);
    if (b.amount > left) throw d.fail(400, `refund is larger than what is left (${centsToValue(left)})`);
    // The row holds the amount before PayPal is called, so two taps at once cannot both record more than is left.
    const hold = `hold-${randomUUID()}`;
    sql('INSERT INTO recorded_refunds (refund_id, user_id, invoice_id, amount_cents, created_at) VALUES (?, ?, ?, ?, ?)').run(hold, userId, r.id, b.amount, d.now());
    let out: { refundId: string };
    try {
      out = await d.paypal.forAccount(userId, r.pp_account).recordRefund(r.id, { date: today(), value: centsToValue(b.amount), currency: r.currency, method: b.method }, idemKey(c));
    } catch (e) {
      sql('DELETE FROM recorded_refunds WHERE refund_id = ?').run(hold);
      throw e;
    }
    if (out.refundId) sql('UPDATE OR IGNORE recorded_refunds SET refund_id = ? WHERE refund_id = ?').run(out.refundId, hold);
    const status = b.amount === left ? 'MARKED_AS_REFUNDED' : 'PARTIALLY_REFUNDED';
    db.setInvoiceStatus(userId, r.id, status, null, null);
    log('invoice_refund_recorded', { user_id: userId, invoice_id: r.id, status });
    return c.json({ ok: true, invoice_id: r.id, status, line: 'Refund recorded ✓', undo: null });
  }

  // ---- payouts: the owner's money out to a supplier. MONEY. Regex only, the strongest confirm, a cap per day.
  type PayoutRow = {
    id: string; name_enc: string; email_enc: string; amount_cents: number; currency: string; status: string;
    batch_id: string | null; item_id: string | null; pp_account: string | null;
  };
  const dayStart = () => { const t = new Date(d.now()); return Date.UTC(t.getUTCFullYear(), t.getUTCMonth(), t.getUTCDate()); };
  const counted = `created_at >= ? AND status NOT IN (${PAYOUT_GONE.map(() => '?').join(', ')})`;
  const sentToday = (userId: string, currency: string) =>
    (sql(`SELECT COALESCE(SUM(amount_cents), 0) AS c FROM payouts WHERE user_id = ? AND currency = ? AND ${counted}`)
      .get(userId, currency, dayStart(), ...PAYOUT_GONE) as { c: number }).c;
  // Every user without their own PayPal sends from the one demo merchant, so the demo cap also counts across all of them.
  const demoSentToday = (currency: string) =>
    (sql(`SELECT COALESCE(SUM(amount_cents), 0) AS c FROM payouts WHERE pp_account IS NULL AND currency = ? AND ${counted}`)
      .get(currency, dayStart(), ...PAYOUT_GONE) as { c: number }).c;
  /** What this user can still send today in this currency, and the cap that applies. A connected user's own account keeps the full cap. */
  function payoutRoom(userId: string, currency: string): { left: number; cap: number; demo: boolean } {
    if (d.accountOf(userId) !== null) {
      const cap = config.money.payoutDailyCap * 100;
      return { left: cap - sentToday(userId, currency), cap, demo: false };
    }
    const cap = config.money.demoPayoutDailyCap * 100;
    const left = Math.min(cap - sentToday(userId, currency), config.money.demoPayoutPlatformDailyCap * 100 - demoSentToday(currency));
    return { left, cap, demo: true };
  }
  const demoLimit = (currency: string) => `Demo account: up to ${formatMoney(config.money.demoPayoutDailyCap * 100, currency)} a day`;

  /**
   * The email for a payout: the one the owner typed, else the one email the owner's own records hold for exactly
   * this name (earlier payouts and invoices). Never from a model or from copied client text. Null when 0 or 2+.
   */
  function payoutEmail(userId: string, ask: PayoutAsk): { email: string | null; several: boolean } {
    if (ask.email) return { email: ask.email, several: false };
    const want = ask.name.toLowerCase();
    const same = (enc: string | null) => d.dec(userId, enc)?.trim().toLowerCase() === want;
    const emails = new Set([
      ...(sql('SELECT name_enc, email_enc FROM payouts WHERE user_id = ?').all(userId) as { name_enc: string; email_enc: string }[])
        .filter((r) => same(r.name_enc)).map((r) => d.dec(userId, r.email_enc)),
      ...db.listInvoices(userId, 500).filter((r) => same(r.client_name_enc)).map((r) => d.dec(userId, r.client_email_enc)),
    ].filter((e): e is string => !!e).map((e) => e.trim().toLowerCase()));
    return emails.size === 1 ? { email: [...emails][0], several: false } : { email: null, several: emails.size > 1 };
  }

  function payoutChips(userId: string, ask: PayoutAsk): Chip[] {
    const { name } = ask;
    const currency = ask.currency ?? db.getProfile(userId)?.currency ?? 'USD';
    const cents = Math.round(ask.amount * 100);
    const money = formatMoney(cents, currency);
    const { email, several } = payoutEmail(userId, ask);
    if (!email) {
      return [lineChip(several ? `${name} has 2 emails on file` : `Add ${name}'s email to send ${money}`,
        several ? `${name} has more than one email on file. Type the one to pay.` : `Type ${name}'s email to send ${money}, like "pay ${name.toLowerCase()} ${money} ${name.toLowerCase()}@example.com".`)];
    }
    const { left, cap, demo } = payoutRoom(userId, currency);
    if (cents > left) {
      return [lineChip(`Over today's payout limit`, demo
        ? `${demoLimit(currency)}. ${formatMoney(Math.max(0, left), currency)} left today. Connect your PayPal to send more.`
        : `Payouts stop at ${formatMoney(cap, currency)} a day. ${formatMoney(Math.max(0, left), currency)} left today.`)];
    }
    const note = ask.note ? clean(ask.note).slice(0, 100) : '';
    const what = note ? `${money} for ${note}` : money;
    return [actionChip('payout', `Send ${money} · ${name}`,
      { recipient_name: name, recipient_email: email, amount: centsToValue(cents), currency, ...(note ? { note } : {}) },
      { confirm_recipient: email, confirm_amount: centsToValue(cents), confirm_currency: currency },
      demo ? `Send ${name} (${email}) ${what} from the demo PayPal? ${demoLimit(currency)}.` : `Send ${name} (${email}) ${what} from your PayPal?`)];
  }

  async function payout(c: Context<Env>) {
    const userId = userOf(c);
    const b = await d.body(c, PayoutBody);
    if (b.confirm_recipient !== b.recipient_email || b.confirm_amount !== b.amount || b.confirm_currency !== b.currency) {
      return needsConfirm(c, b.recipient_email);
    }
    const { left, demo } = payoutRoom(userId, b.currency);
    if (b.amount > left) throw d.fail(409, `over today's payout limit (${centsToValue(Math.max(0, left))} left)${demo ? `. ${demoLimit(b.currency)}` : ''}`);
    // The row holds the money against the cap before PayPal is called, so two taps at once cannot both pass.
    const id = randomUUID();
    const account = d.accountOf(userId);
    sql(`INSERT INTO payouts (id, user_id, name_enc, email_enc, amount_cents, currency, status, created_at, pp_account) VALUES (?, ?, ?, ?, ?, ?, 'SENDING', ?, ?)`)
      .run(id, userId, d.enc(userId, b.recipient_name), d.enc(userId, b.recipient_email), b.amount, b.currency, d.now(), account);
    const pp = d.paypal.forAccount(userId, account);
    let sent: { batchId: string; status: string };
    try {
      sent = await pp.createPayout({ email: b.recipient_email, value: centsToValue(b.amount), currency: b.currency, note: b.note ?? `Payment from ${db.getProfile(userId)?.business_name ?? 'your client'}` }, idemKey(c));
    } catch (e) {
      // Only a clear PayPal refusal (4xx) means no money left. A timeout or a 5xx may have sent it: the row stays
      // UNKNOWN and keeps counting toward the cap.
      const refused = e instanceof PayPalError && e.upstream !== null && e.upstream >= 400 && e.upstream < 500;
      if (refused) {
        sql('DELETE FROM payouts WHERE id = ? AND user_id = ?').run(id, userId);
        throw e;
      }
      sql("UPDATE payouts SET status = 'UNKNOWN' WHERE id = ? AND user_id = ?").run(id, userId);
      log('payout_unknown', { user_id: userId, payout_id: id, err: (e as Error).message });
      throw d.fail(409, "PayPal didn't confirm this payout. Check your PayPal activity before you send it again");
    }
    // PayPal makes the item a moment later; without it yet, Undo looks again when tapped.
    const item = await pp.getPayoutItem(sent.batchId).catch(() => null);
    const status = item?.status ?? sent.status;
    sql('UPDATE payouts SET status = ?, batch_id = ?, item_id = ? WHERE id = ? AND user_id = ?').run(status, sent.batchId, item?.itemId ?? null, id, userId);
    log('payout_sent', { user_id: userId, payout_id: id, status });
    const canUndo = ['UNCLAIMED', 'PENDING'].includes(status);
    return c.json({ ok: true, payout_id: id, status, line: `Sent ${formatMoney(b.amount, b.currency)} to ${b.recipient_name} ✓`,
      undo: canUndo ? undoChip('payout_cancel', { payout_id: id }) : null });
  }

  async function cancelPayout(c: Context<Env>) {
    const userId = userOf(c);
    const { payout_id } = await d.body(c, PayoutCancelBody);
    const r = sql('SELECT * FROM payouts WHERE id = ? AND user_id = ?').get(payout_id, userId) as PayoutRow | undefined;
    if (!r) throw d.fail(404, 'payout not found');
    if (!r.batch_id) throw d.fail(409, "PayPal didn't confirm this payout. Check your PayPal activity");
    const name = d.dec(userId, r.name_enc) ?? 'They';
    const pp = d.paypal.forAccount(userId, r.pp_account);
    const item = await pp.getPayoutItem(r.batch_id);
    if (item) sql('UPDATE payouts SET status = ?, item_id = ? WHERE id = ?').run(item.status, item.itemId, r.id);
    if (!item || item.status === 'PENDING') throw d.fail(409, 'PayPal is still sending it. Try Undo again in a minute');
    if (item.status !== 'UNCLAIMED') throw d.fail(409, `${name} already has it, so it can't be undone`);
    const out = await pp.cancelPayoutItem(item.itemId, idemKey(c));
    sql('UPDATE payouts SET status = ? WHERE id = ?').run(out.status === 'RETURNED' ? 'RETURNED' : out.status, r.id);
    log('payout_cancelled', { user_id: userId, payout_id: r.id });
    return c.json({ ok: true, payout_id: r.id, status: out.status, line: `Cancelled ✓ · ${formatMoney(r.amount_cents, r.currency)} back in your PayPal`, undo: null });
  }

  // ---- disputes: reply, offer a refund, accept the claim. The buyer and amount always come from PayPal's own dispute.
  type OpenDispute = { id: string; name: string; cents: number | null; currency: string | null; due: string | null; status: string };
  const buyer = (n: string | null | undefined) => clean(n ?? '') || 'The buyer';
  const disputeMoney = (o: { cents: number | null; currency: string | null }) => (o.cents !== null && o.currency ? formatMoney(o.cents, o.currency) : '');
  const dueWord = (iso: string) => {
    const t = Date.parse(iso);
    const at = d.now();
    if (iso.slice(0, 10) === new Date(at).toISOString().slice(0, 10)) return 'today';
    const opts: Intl.DateTimeFormatOptions = t - at < 6 * 86_400_000 ? { weekday: 'short', timeZone: 'UTC' } : { month: 'short', day: 'numeric', timeZone: 'UTC' };
    return new Date(t).toLocaleDateString('en-US', opts);
  };
  /** "Sam $45 · reply by Thu" */
  const disputeLine = (o: OpenDispute) =>
    [`${o.name} ${disputeMoney(o)}`.trim(), o.due ? `reply by ${dueWord(o.due)}` : o.status.replace(/_/g, ' ').toLowerCase()].join(' · ');

  // Each open dispute's detail is one PayPal read, so the whole list is kept a minute per user.
  const openCache = new Map<string, { at: number; list: OpenDispute[] }>();
  const forgetOpen = (userId: string) => { openCache.delete(userId); d.biz.forgetDisputes(userId); };
  async function openDisputes(userId: string): Promise<OpenDispute[]> {
    const hit = openCache.get(userId);
    if (hit && d.now() - hit.at < 60_000) return hit.list;
    if (openCache.size > 10_000) openCache.clear();
    const open = await readOpenDisputes(userId);
    openCache.set(userId, { at: d.now(), list: open });
    return open;
  }
  async function readOpenDisputes(userId: string): Promise<OpenDispute[]> {
    const list = (await d.biz.disputes(userId)).filter((x) => x.status !== 'RESOLVED').slice(0, 5);
    const details = await Promise.all(list.map((x) => d.biz.dispute(userId, x.id).catch(() => null)));
    return list.map((x, i) => ({
      id: x.id, name: buyer(details[i]?.buyer_name), cents: x.amount ? valueToCents(x.amount.value) : null, currency: x.amount?.currency ?? null,
      due: x.due_date, status: x.status,
    }));
  }

  const short = (t: string) => (t.length > 60 ? `${t.slice(0, 57)}…` : t);
  const disputeConfirm = (o: { name: string; cents: number | null; currency: string | null }, cents = o.cents) =>
    ({ confirm_client: o.name, confirm_amount: centsToValue(cents ?? 0), confirm_currency: o.currency });

  /** True when the text names a client on this user's own invoices, pay links or repeat bills. No PayPal call. */
  function namesOwnClient(userId: string, text: string): boolean {
    const nameOf = d.biz.namer(userId);
    const rows = [...db.listInvoices(userId, 500), ...db.listOrders(userId, 500), ...db.listSubscriptions(userId, 500)];
    return namedIn(text, rows, nameOf).length > 0;
  }

  async function disputeChips(userId: string, text: string, v: DisputeVerb): Promise<Chip[] | null> {
    // "tell ana see you at 3" or "offer sam $20" reads PayPal only when the name is one of the owner's own clients.
    if (v.verb !== 'list' && !namesOwnClient(userId, v.verb === 'reply' ? v.name : text)) return null;
    const open = await openDisputes(userId);
    if (v.verb === 'list') {
      if (!open.length) return [lineChip('Disputes · none open', 'No open disputes ✓')];
      const lines = open.map(disputeLine);
      return [lineChip(`Disputes · ${open.length} open`, lines.slice(0, 2).join(', ') + (lines.length > 2 ? ` +${lines.length - 2}` : ''))];
    }
    const hits = v.verb === 'reply'
      ? open.filter((o) => [o.name, o.name.split(/\s+/)[0]].some((n) => n.toLowerCase() === v.name.toLowerCase()))
      : namedIn(text, open, (o) => o.name);
    if (hits.length !== 1) return hits.length ? [lineChip(`${hits[0].name} has ${hits.length} disputes`, `${hits[0].name} has ${hits.length} open disputes. Open Disputes in Muninn to pick one.`)] : null;
    const o = hits[0];
    if (v.verb === 'reply') {
      return [actionChip('dispute_reply', `Reply in dispute · ${o.name}`, { dispute_id: o.id, message: v.message }, { confirm_client: o.name },
        `Send this to ${o.name} in PayPal's dispute? "${short(v.message)}"`)];
    }
    if (o.cents === null || !o.currency) return [lineChip(`Open ${o.name}'s dispute in PayPal`, `PayPal shows no amount for ${o.name}'s dispute. Answer it in PayPal.`)];
    const money = disputeMoney(o);
    if (v.verb === 'accept') {
      return [actionChip('dispute_accept', `Accept claim ${money} · ${o.name}`, { dispute_id: o.id }, disputeConfirm(o),
        `Accept ${o.name}'s claim and refund ${money}? Can't undo.`)];
    }
    const typed = quick(text).amount;
    if (typed === null) return [lineChip(`Type the offer for ${o.name}`, `Type how much to offer, like "offer ${o.name.split(' ')[0].toLowerCase()} $20 back".`)];
    const cents = Math.round(typed * 100);
    if (cents > o.cents) return [lineChip(`More than the ${money} in dispute`, `${o.name}'s dispute is for ${money}. Offer that or less, or accept the claim.`)];
    const offer = formatMoney(cents, o.currency);
    return [actionChip('dispute_offer', `Offer ${offer} · ${o.name}`, { dispute_id: o.id, amount: centsToValue(cents), currency: o.currency }, disputeConfirm(o, cents),
      `Offer ${o.name} a ${offer} refund to close the dispute?`)];
  }

  /** The open dispute as PayPal has it now, for this user only. */
  async function disputeFor(c: Context<Env>, id: string) {
    const userId = userOf(c);
    const det = await d.biz.dispute(userId, id);
    if (!det) throw d.fail(404, 'dispute not found');
    if (det.status === 'RESOLVED') throw d.fail(409, 'this dispute is closed');
    return { userId, det, name: buyer(det.buyer_name), cents: det.amount ? valueToCents(det.amount.value) : null, currency: det.amount?.currency ?? null };
  }

  async function disputeReply(c: Context<Env>) {
    const b = await d.body(c, DisputeReplyBody);
    const { userId, name } = await disputeFor(c, b.dispute_id);
    if (!sameName(b.confirm_client, [name])) return needsConfirm(c, name);
    await d.biz.sendDisputeMessage(userId, b.dispute_id, b.message, idemKey(c));
    forgetOpen(userId);
    log('dispute_message_sent', { user_id: userId, dispute_id: b.dispute_id });
    return c.json({ ok: true, dispute_id: b.dispute_id, line: 'Message sent ✓', undo: null });
  }

  async function disputeAccept(c: Context<Env>) {
    const b = await d.body(c, DisputeAcceptBody);
    const { userId, name, cents, currency } = await disputeFor(c, b.dispute_id);
    if (cents === null || !sameName(b.confirm_client, [name]) || b.confirm_amount !== cents || b.confirm_currency !== currency) return needsConfirm(c, name);
    await d.paypal.forUser(userId).acceptClaim(b.dispute_id, 'Claim accepted. A full refund is on its way.', idemKey(c));
    forgetOpen(userId);
    log('dispute_accepted', { user_id: userId, dispute_id: b.dispute_id });
    return c.json({ ok: true, dispute_id: b.dispute_id, line: 'Claim accepted ✓', undo: null });
  }

  async function disputeOffer(c: Context<Env>) {
    const b = await d.body(c, DisputeOfferBody);
    const { userId, name, cents, currency } = await disputeFor(c, b.dispute_id);
    if (cents === null || b.currency !== currency) throw d.fail(400, 'the offer must be in the dispute currency');
    if (b.amount > cents) throw d.fail(400, `the offer is more than the dispute (${centsToValue(cents)})`);
    if (!sameName(b.confirm_client, [name]) || b.confirm_amount !== b.amount || b.confirm_currency !== b.currency) return needsConfirm(c, name);
    await d.paypal.forUser(userId).makeOffer(b.dispute_id, { note: `Offering ${formatMoney(b.amount, b.currency)} back to settle this.`, value: centsToValue(b.amount), currency: b.currency }, idemKey(c));
    forgetOpen(userId);
    log('dispute_offer_sent', { user_id: userId, dispute_id: b.dispute_id });
    return c.json({ ok: true, dispute_id: b.dispute_id, line: 'Offer sent ✓', undo: null });
  }

  // ---- balance: read-only, for the bar. Never typed into the chat.
  /** "$1,240.50": the bar shows a balance with thousands marks. */
  const big = (cents: number, currency: string) => formatMoney(cents, currency).replace(/\d+(?=\.|$)/, (n) => Number(n).toLocaleString('en-US'));

  async function balanceLine(userId: string): Promise<string> {
    try {
      const all = await d.paypal.forUser(userId).getBalances();
      const shown = [...all].sort((a, b) => Number(b.primary) - Number(a.primary))
        .map((b) => ({ cents: valueToCents(b.available), currency: b.currency }))
        .filter((b): b is { cents: number; currency: string } => b.cents !== null && (b.cents !== 0 || all.length === 1));
      if (shown.length) return `PayPal balance ${shown.slice(0, 3).map((b) => big(b.cents, b.currency)).join(' · ')}`;
    } catch (e) {
      // The balance read needs a permission some accounts (and the sandbox) may not grant. Fall back to this week's net.
      if (!(e instanceof PayPalError)) throw e;
      log('balance_failed', { user_id: userId, err: e.message });
    }
    const net = Object.entries((await d.biz.summary(userId)).net_this_week);
    const money = net.map(([c, v]) => big(valueToCents(v) ?? 0, c)).join(' · ');
    return money ? `PayPal didn't share the balance. Net this week ${money}` : "PayPal didn't share the balance. Nothing came in this week.";
  }

  /** The payout chip for "pay joe $200", or null. Regex and local rows only: no model, no PayPal call. */
  function payoutSuggest(userId: string, text: string): Chip[] | null {
    const ask = payoutAsk(text);
    return ask ? payoutChips(userId, ask) : null;
  }

  /**
   * The chips for a more-verb other than a payout, or null when the text is not one. No model call.
   * `from: 'ask'`: the Ask bar already answers a disputes list itself (its disputes route), so that one is left to it.
   */
  async function suggest(userId: string, text: string, from: 'suggest' | 'ask' = 'suggest'): Promise<Chip[] | null> {
    if (balanceAsk(text)) return [chip('balance', 'Balance', {}, false)];
    // The keyboard draws the chart; the Ask bar has no canvas, so it never gets this chip.
    const chart = from === 'suggest' ? chartAsk(text) : null;
    if (chart) return [chip('chart', 'Sales chart', chart, false)];
    const plan = planVerb(text);
    if (plan) {
      const out = planChips(userId, text, plan);
      if (out) return out;
    }
    const dispute = disputeVerb(text);
    if (dispute && !(from === 'ask' && dispute.verb === 'list')) {
      const out = await disputeChips(userId, text, dispute);
      if (out) return out;
    }
    const inv = invoiceVerb(text);
    if (inv) {
      const out = invoiceChips(userId, text, inv);
      if (out) return out;
    }
    return null;
  }

  function mount(app: Hono<Env>) {
    app.post('/v1/actions/plan/pause', (c) => planAction(c, 'suspend'));
    app.post('/v1/actions/plan/resume', (c) => planAction(c, 'activate'));
    app.post('/v1/actions/plan/cancel', (c) => planAction(c, 'cancel'));
    app.post('/v1/actions/invoice/mark-paid', markPaid);
    app.post('/v1/actions/invoice/unmark-paid', unmarkPaid);
    app.post('/v1/actions/invoice/cancel', cancelInvoice);
    app.post('/v1/actions/invoice/record-refund', recordRefund);
    app.post('/v1/actions/payout', payout);
    app.post('/v1/actions/payout/cancel', cancelPayout);
    app.post('/v1/actions/dispute/reply', disputeReply);
    app.post('/v1/actions/dispute/accept', disputeAccept);
    app.post('/v1/actions/dispute/offer', disputeOffer);
    // Read-only: open disputes with the buyer's name, for the app's Disputes page.
    app.get('/v1/disputes-open', async (c) => {
      const open = await openDisputes(userOf(c));
      return c.json({ disputes: open.map((o) => ({ id: o.id, name: o.name, amount: o.cents === null ? null : centsToValue(o.cents), currency: o.currency, line: disputeLine(o) })) });
    });
    app.get('/v1/balance', async (c) => c.json({ line: await balanceLine(userOf(c)) }));
    // Read-only: one repeat bill as PayPal sees it now.
    app.get('/v1/plans/:id', async (c) => {
      const userId = userOf(c);
      const r = db.getSubscription(userId, c.req.param('id'));
      if (!r) throw d.fail(404, 'repeat bill not found');
      const now = await d.paypal.forAccount(userId, r.pp_account).getSubscription(r.id);
      syncPlan(userId, r.id, now.status);
      const next = now.status === 'ACTIVE' && now.nextBillingAt
        ? ` · next bill ${new Date(now.nextBillingAt).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' })}` : '';
      const name = d.biz.namer(userId)(r) ?? r.item;
      return c.json({ line: `${name} ${planMoney(r)} · ${PLAN_STATE[now.status] ?? now.status.toLowerCase()}${next}`, status: now.status });
    });
  }

  return { payout: payoutSuggest, suggest, mount };
}
