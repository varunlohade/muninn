// PayPal actions beyond invoices, pay links and refunds. Chips come from plain regex and the owner's own records,
// never from a model. Every action sits under /v1/actions/*, so it gets the tap gate and the per-chip idempotency key.
//
// One grammar: chip "<Verb> <money> · <who>", one confirm question, a done line, and Undo only when PayPal can undo.
// An action chip's payload is { body, confirm, question }: the phone sends `body`, adds `confirm` after the owner's
// confirm tap, and shows `question` on that tap. The server checks every confirm value against its own records
// and answers 409 needs_confirm on any mismatch.
import type { Context, Hono } from 'hono';
import { z } from 'zod';
import type { Chip, Env } from './app.ts';
import type { createBusiness } from './business.ts';
import type { Db, InvoiceRow, SubscriptionRow } from './db.ts';
import { log } from './log.ts';
import { Amount, Currency, centsToValue, formatMoney } from './money.ts';
import type { PayPalProvider } from './paypal.ts';
import { invoiceVerb, mentions, payoutAsk, planVerb, quick, type InvoiceVerb, type PlanVerb } from './quick.ts';
import { clean } from './text.ts';

export type MoreDeps = {
  db: Db; paypal: PayPalProvider; biz: ReturnType<typeof createBusiness>; now: () => number;
  dec: (userId: string, v: string | null) => string | null;
  body: <T extends z.ZodTypeAny>(c: Context<Env>, schema: T) => Promise<z.infer<T>>;
  fail: (status: 400 | 404 | 409, message: string) => Error;
  requestIdFor: (userId: string, key: string) => string;
};

const PER: Record<string, string> = { week: '/wk', month: '/mo', year: '/yr' };
const EVERY: Record<string, string> = { week: 'weekly', month: 'monthly', year: 'yearly' };
const PLAN_STATE: Record<string, string> = { ACTIVE: 'active', SUSPENDED: 'paused', APPROVAL_PENDING: 'waiting for approval', CANCELLED: 'ended' };
const OPEN_PLAN = ['ACTIVE', 'SUSPENDED', 'APPROVAL_PENDING'];

const ConfirmName = z.string().trim().min(1).max(100);
const PlanBody = z.object({
  subscription_id: z.string().regex(/^I-[A-Z0-9]{4,40}$/),
  confirm_client: ConfirmName.optional(), confirm_amount: Amount.optional(), confirm_currency: Currency.optional(),
}).strict();

const InvoiceId = z.string().regex(/^INV2-[A-Z0-9-]{4,60}$/);
const Method = z.enum(['CASH', 'CHECK', 'BANK_TRANSFER', 'WIRE_TRANSFER', 'CREDIT_CARD', 'DEBIT_CARD', 'OTHER']);
const InvoiceConfirm = { confirm_client: ConfirmName.optional(), confirm_amount: Amount.optional(), confirm_currency: Currency.optional() };
const MarkPaidBody = z.object({ invoice_id: InvoiceId, method: Method.default('OTHER'), ...InvoiceConfirm }).strict();
const InvoiceOnlyBody = z.object({ invoice_id: InvoiceId, ...InvoiceConfirm }).strict();
const RecordRefundBody = z.object({ invoice_id: InvoiceId, amount: Amount, method: Method.default('OTHER'), ...InvoiceConfirm }).strict();

// Payments and refunds the owner recorded through Muninn, so Undo and "what is left" never guess.
const TABLES = `
CREATE TABLE IF NOT EXISTS recorded_payments (
  user_id TEXT NOT NULL REFERENCES users(id), invoice_id TEXT NOT NULL, payment_id TEXT NOT NULL, created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, invoice_id));
CREATE TABLE IF NOT EXISTS recorded_refunds (
  refund_id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), invoice_id TEXT NOT NULL, amount_cents INTEGER NOT NULL, created_at INTEGER NOT NULL);
`;

export function createMore(d: MoreDeps) {
  const { db } = d;
  db.raw.exec(TABLES);
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
    const m = PLAN_MOVE[move];
    const pp = d.paypal.forUser(userId);
    // PayPal is the truth: a webhook may not have come in yet.
    const now = await pp.getSubscription(r.id);
    syncPlan(userId, r.id, now.status);
    if (!(m.from as readonly string[]).includes(now.status)) throw d.fail(409, m.not);
    await pp.changeSubscription(r.id, move, m.reason, idemKey(c));
    syncPlan(userId, r.id, m.to);
    log('plan_changed', { user_id: userId, subscription_id: r.id, move });
    const undo = move === 'suspend' ? undoChip('plan_resume', { subscription_id: r.id, ...planConfirm(r, b.confirm_client!) }) : null;
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
    const out = await d.paypal.forUser(userId).recordPayment(r.id, {
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
    const pp = d.paypal.forUser(userId);
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
    await d.paypal.forUser(userId).cancelInvoice(r.id, !!r.client_email_enc, idemKey(c));
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
    const out = await d.paypal.forUser(userId).recordRefund(r.id, { date: today(), value: centsToValue(b.amount), currency: r.currency, method: b.method }, idemKey(c));
    sql('INSERT OR IGNORE INTO recorded_refunds (refund_id, user_id, invoice_id, amount_cents, created_at) VALUES (?, ?, ?, ?, ?)')
      .run(out.refundId || idemKey(c), userId, r.id, b.amount, d.now());
    const status = b.amount === left ? 'MARKED_AS_REFUNDED' : 'PARTIALLY_REFUNDED';
    db.setInvoiceStatus(userId, r.id, status, null, null);
    log('invoice_refund_recorded', { user_id: userId, invoice_id: r.id, status });
    return c.json({ ok: true, invoice_id: r.id, status, line: 'Refund recorded ✓', undo: null });
  }

  /** The chips for a more-verb, or null when the text is not one. No paid call. */
  async function suggest(userId: string, text: string): Promise<Chip[] | null> {
    // "pay joe $200" is a payout, never a pay link. Until payouts ship it gets no chip.
    if (payoutAsk(text)) return [];
    const plan = planVerb(text);
    if (plan) {
      const out = planChips(userId, text, plan);
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
    // Read-only: one repeat bill as PayPal sees it now.
    app.get('/v1/plans/:id', async (c) => {
      const userId = userOf(c);
      const r = db.getSubscription(userId, c.req.param('id'));
      if (!r) throw d.fail(404, 'repeat bill not found');
      const now = await d.paypal.forUser(userId).getSubscription(r.id);
      syncPlan(userId, r.id, now.status);
      const next = now.status === 'ACTIVE' && now.nextBillingAt
        ? ` · next bill ${new Date(now.nextBillingAt).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' })}` : '';
      const name = d.biz.namer(userId)(r) ?? r.item;
      return c.json({ line: `${name} ${planMoney(r)} · ${PLAN_STATE[now.status] ?? now.status.toLowerCase()}${next}`, status: now.status });
    });
  }

  return { suggest, mount };
}
