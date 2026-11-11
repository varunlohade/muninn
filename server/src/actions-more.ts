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
import type { Db, SubscriptionRow } from './db.ts';
import { log } from './log.ts';
import { Amount, Currency, centsToValue, formatMoney } from './money.ts';
import type { PayPalProvider } from './paypal.ts';
import { mentions, payoutAsk, planVerb, quick, type PlanVerb } from './quick.ts';
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

export function createMore(d: MoreDeps) {
  const { db } = d;

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

  /** The chips for a more-verb, or null when the text is not one. No paid call. */
  async function suggest(userId: string, text: string): Promise<Chip[] | null> {
    // "pay joe $200" is a payout, never a pay link. Until payouts ship it gets no chip.
    if (payoutAsk(text)) return [];
    const plan = planVerb(text);
    if (plan) {
      const out = planChips(userId, text, plan);
      if (out) return out;
    }
    return null;
  }

  function mount(app: Hono<Env>) {
    app.post('/v1/actions/plan/pause', (c) => planAction(c, 'suspend'));
    app.post('/v1/actions/plan/resume', (c) => planAction(c, 'activate'));
    app.post('/v1/actions/plan/cancel', (c) => planAction(c, 'cancel'));
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
