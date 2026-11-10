import type { Ai } from './ai.ts';
import type { Db, InvoiceRow, OrderRow } from './db.ts';
import type { PayPalDispute, PayPalProvider, PayPalTxn } from './paypal.ts';
import type { createIntegrations } from './integrations.ts';
import { valueToCents, centsToValue, formatMoney } from './money.ts';
import { clean } from './text.ts';
import { log } from './log.ts';

const DAY = 86_400_000;
const CACHE_MS = 60_000;
export const RANGES = ['today', 'week', 'month'] as const;
export type Range = (typeof RANGES)[number];

export type Txn = {
  id: string; date: string; amount: string; fee: string | null; net: string | null; currency: string;
  payer_name: string | null; payer_email: string | null; status: string;
  invoice_id: string | null; order_id: string | null; source: 'paypal' | 'local';
  // paypal_transaction: from Transaction Search. recorded_payment: an invoice marked paid in PayPal, no PayPal money moved.
  kind: 'paypal_transaction' | 'invoice_payment' | 'recorded_payment' | 'pay_link_payment';
};
type TxnSet = { source: 'paypal' | 'local'; note: 'paypal_empty' | 'paypal_error' | null; txns: Txn[] };
type Totals = Record<string, string>;

const TXN_STATUS: Record<string, string> = { S: 'COMPLETED', P: 'PENDING', V: 'REVERSED', D: 'DENIED', F: 'PARTIALLY_REFUNDED' };
// T00xx: payments received or sent. T11xx: reversals and refunds. Balance moves, transfers and holds are not business income.
const isPayment = (code: string) => /^T(00|11)\d\d$/.test(code);
const OPEN_DISPUTE = (s: string) => s !== 'RESOLVED';

export function rangeStarts(at: number) {
  const d = new Date(at);
  const today = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
  return { today, week: today - ((d.getUTCDay() + 6) % 7) * DAY, month: Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), 1) };
}

const addTo = (t: Map<string, number>, currency: string, cents: number) => t.set(currency, (t.get(currency) ?? 0) + cents);
const toTotals = (t: Map<string, number>): Totals => Object.fromEntries([...t].map(([c, v]) => [c, centsToValue(v)]));
const money = (t: Totals) => Object.entries(t).map(([c, v]) => formatMoney(Math.round(Number(v) * 100), c)).join(' and ');

type Deps = {
  db: Db; ai: Ai; paypal: PayPalProvider; integrations: ReturnType<typeof createIntegrations>;
  dec: (userId: string, v: string | null) => string | null; now: () => number;
};

export function createBusiness({ db, ai, paypal, integrations, dec, now }: Deps) {
  const txnCache = new Map<string, { at: number; set: TxnSet }>();
  const disputeCache = new Map<string, { at: number; list: PayPalDispute[] }>();
  const cached = <T>(m: Map<string, { at: number } & T>, userId: string) => {
    const hit = m.get(userId);
    if (hit && now() - hit.at < CACHE_MS) return hit;
    if (m.size > 10_000) m.clear();
    return null;
  };

  const paypalFor = (userId: string) => {
    integrations.ensureDefaults(userId);
    return integrations.status(userId, 'paypal') === 'connected' ? paypal.forUser(userId) : null;
  };

  function fromPayPal(t: PayPalTxn, invoices: InvoiceRow[], orders: OrderRow[]): Txn | null {
    if (!isPayment(t.event_code)) return null;
    const cents = valueToCents(t.amount.value);
    if (cents === null) return null;
    const feeCents = t.fee ? Math.abs(valueToCents(t.fee.value) ?? 0) : null;
    const inv = invoices.find((r) => r.capture_id === t.id || r.id === t.invoice_id);
    const ord = orders.find((r) => r.capture_id === t.id);
    return {
      id: t.id, date: t.date, amount: centsToValue(cents), currency: t.amount.currency,
      fee: feeCents === null ? null : centsToValue(feeCents), net: centsToValue(cents - (feeCents ?? 0)),
      payer_name: t.payer_name ? clean(t.payer_name) : null, payer_email: t.payer_email?.toLowerCase() ?? null,
      status: TXN_STATUS[t.status] ?? t.status, invoice_id: inv?.id ?? null, order_id: ord?.id ?? null, source: 'paypal',
      kind: 'paypal_transaction',
    };
  }

  function fromLocal(userId: string, since: number): Txn[] {
    const row = (r: InvoiceRow | OrderRow, kind: 'invoice' | 'order'): Txn => ({
      id: r.capture_id ?? r.id, date: new Date(r.paid_at!).toISOString(), amount: centsToValue(r.amount_cents), fee: null, net: null,
      currency: r.currency, payer_name: dec(userId, r.client_name_enc), payer_email: 'client_email_enc' in r ? dec(userId, r.client_email_enc) : null,
      status: r.status, invoice_id: kind === 'invoice' ? r.id : null, order_id: kind === 'order' ? r.id : null, source: 'local',
      kind: kind === 'order' ? 'pay_link_payment' : r.status === 'MARKED_AS_PAID' ? 'recorded_payment' : 'invoice_payment',
    });
    return [
      ...db.listInvoices(userId, 500).filter((r) => r.paid_at && r.paid_at >= since).map((r) => row(r, 'invoice')),
      ...db.listOrders(userId, 500).filter((r) => r.paid_at && r.paid_at >= since).map((r) => row(r, 'order')),
    ].sort((a, b) => b.date.localeCompare(a.date));
  }

  // One window per user covers today, this week and this month. Sandbox search can lag for hours, so an empty
  // or failed PayPal answer falls back to our own paid invoices and orders, marked source: 'local'.
  async function window(userId: string): Promise<TxnSet> {
    const hit = cached(txnCache, userId);
    if (hit) return hit.set;
    const at = now();
    const s = rangeStarts(at);
    const since = Math.min(s.week, s.month);
    let set: TxnSet;
    try {
      const pp = paypalFor(userId);
      const raw = pp ? await pp.searchTransactions(new Date(since), new Date(at)) : [];
      const invoices = db.listInvoices(userId, 500);
      const orders = db.listOrders(userId, 500);
      const txns = raw.map((t) => fromPayPal(t, invoices, orders)).filter((t): t is Txn => t !== null)
        .sort((a, b) => b.date.localeCompare(a.date));
      set = txns.length ? { source: 'paypal', note: null, txns } : { source: 'local', note: 'paypal_empty', txns: fromLocal(userId, since) };
    } catch (e) {
      log('transactions_failed', { user_id: userId, err: (e as Error).message });
      set = { source: 'local', note: 'paypal_error', txns: fromLocal(userId, since) };
    }
    txnCache.set(userId, { at, set });
    return set;
  }

  async function transactions(userId: string, range: Range) {
    const set = await window(userId);
    const since = rangeStarts(now())[range];
    return { ...set, txns: set.txns.filter((t) => Date.parse(t.date) >= since) };
  }

  async function disputes(userId: string): Promise<PayPalDispute[]> {
    const hit = cached(disputeCache, userId);
    if (hit) return hit.list;
    const pp = paypalFor(userId);
    const list = pp ? await pp.listDisputes() : [];
    disputeCache.set(userId, { at: now(), list });
    return list;
  }

  async function dispute(userId: string, id: string) {
    const pp = paypalFor(userId);
    return pp ? pp.getDispute(id) : null;
  }

  async function sendDisputeMessage(userId: string, id: string, message: string, requestId: string): Promise<boolean> {
    const pp = paypalFor(userId);
    if (!pp || !(await pp.getDispute(id))) return false;
    await pp.sendDisputeMessage(id, message, requestId);
    disputeCache.delete(userId);
    return true;
  }

  const unpaidInvoices = (userId: string) =>
    db.listInvoices(userId, 500).filter((r) => !r.paid_at && !['CANCELLED', 'REFUNDED'].includes(r.status));

  async function summary(userId: string) {
    const at = now();
    const s = rangeStarts(at);
    const set = await window(userId);
    const earnedToday = new Map<string, number>();
    const earnedWeek = new Map<string, number>();
    const fees = new Map<string, number>();
    const net = new Map<string, number>();
    for (const t of set.txns) {
      const when = Date.parse(t.date);
      const cents = Math.round(Number(t.amount) * 100);
      if (when >= s.week) {
        if (cents > 0) addTo(earnedWeek, t.currency, cents);
        if (t.fee !== null) addTo(fees, t.currency, Math.round(Number(t.fee) * 100));
        if (t.net !== null) addTo(net, t.currency, Math.round(Number(t.net) * 100));
      }
      if (when >= s.today && cents > 0) addTo(earnedToday, t.currency, cents);
    }

    const unpaid = unpaidInvoices(userId);
    const unpaidAmount = new Map<string, number>();
    for (const r of unpaid) addTo(unpaidAmount, r.currency, r.amount_cents);
    const late = unpaid.filter((r) => at > r.due_at).sort((a, b) => a.due_at - b.due_at);
    const top = late[0];

    let open: PayPalDispute[] | null = null;
    try {
      open = (await disputes(userId)).filter((d) => OPEN_DISPUTE(d.status));
    } catch (e) {
      log('disputes_failed', { user_id: userId, err: (e as Error).message });
    }
    const due = open?.filter((d) => d.due_date).sort((a, b) => a.due_date!.localeCompare(b.due_date!))[0];

    return {
      earned_today: toTotals(earnedToday),
      earned_this_week: toTotals(earnedWeek),
      fees_this_week: toTotals(fees),
      net_this_week: toTotals(net),
      unpaid_count: unpaid.length,
      unpaid_amount: toTotals(unpaidAmount),
      late_count: late.length,
      most_late: top ? {
        invoice_id: top.id, client_name: dec(userId, top.client_name_enc), days_over: Math.floor((at - top.due_at) / DAY),
        amount: centsToValue(top.amount_cents), currency: top.currency,
      } : null,
      open_disputes: open?.length ?? null,
      next_dispute_due: due ? { dispute_id: due.id, due_date: due.due_date } : null,
      source: set.source,
      note: set.note,
      timezone: 'UTC',
    };
  }

  async function clients(userId: string) {
    type Client = { name: string | null; email: string | null; paid: Map<string, number>; open: Map<string, number>; visits: number; last: number; channels: Set<string> };
    const byEmail = new Map<string, Client>();
    const byName = new Map<string, Client>();
    const all: Client[] = [];
    const find = (name: string | null, email: string | null): Client | null => {
      if (!name && !email) return null;
      let c = (email && byEmail.get(email)) || (name && byName.get(name.toLowerCase())) || null;
      if (!c) {
        c = { name, email, paid: new Map(), open: new Map(), visits: 0, last: 0, channels: new Set() };
        all.push(c);
      }
      c.name ??= name;
      c.email ??= email;
      if (email) byEmail.set(email, c);
      if (name) byName.set(name.toLowerCase(), c);
      return c;
    };

    const unpaidIds = new Set(unpaidInvoices(userId).map((r) => r.id));
    for (const r of db.listInvoices(userId, 500)) {
      const c = find(dec(userId, r.client_name_enc), dec(userId, r.client_email_enc));
      if (!c) continue;
      c.channels.add('invoice');
      c.last = Math.max(c.last, r.paid_at ?? r.created_at);
      if (r.paid_at) { addTo(c.paid, r.currency, r.amount_cents); c.visits++; }
      else if (unpaidIds.has(r.id)) addTo(c.open, r.currency, r.amount_cents);
    }
    for (const r of db.listOrders(userId, 500)) {
      const c = find(dec(userId, r.client_name_enc), null);
      if (!c) continue;
      c.channels.add('pay_link');
      c.last = Math.max(c.last, r.paid_at ?? r.created_at);
      if (r.paid_at) { addTo(c.paid, r.currency, r.amount_cents); c.visits++; }
    }
    const set = await window(userId);
    if (set.source === 'paypal') {
      for (const t of set.txns) {
        if (t.invoice_id || t.order_id) continue;
        const cents = Math.round(Number(t.amount) * 100);
        const c = cents > 0 ? find(t.payer_name, t.payer_email) : null;
        if (!c) continue;
        c.channels.add('paypal');
        c.last = Math.max(c.last, Date.parse(t.date));
        addTo(c.paid, t.currency, cents);
        c.visits++;
      }
    }
    return {
      source: set.source,
      clients: all.sort((a, b) => b.last - a.last).map((c) => ({
        name: c.name, email: c.email, total_paid: toTotals(c.paid), open_amount: toTotals(c.open), visits: c.visits,
        last_seen: c.last ? new Date(c.last).toISOString() : null, channels: [...c.channels],
      })),
    };
  }

  async function brief(userId: string) {
    const sum = await summary(userId);
    const facts = briefFacts(sum, now());
    const fallback = briefTemplate(sum, now());
    try {
      const out = await ai.brief(facts.join('\n'));
      const lines = checkBrief(out, facts.join('\n'));
      if (lines) return { lines, source: 'ai' as const, data_source: sum.source };
      log('brief_rejected', { user_id: userId });
    } catch (e) {
      log('brief_failed', { user_id: userId, err: (e as Error).message });
    }
    return { lines: fallback, source: 'template' as const, data_source: sum.source };
  }

  return { transactions, summary, disputes, dispute, sendDisputeMessage, clients, brief };
}

type Summary = Awaited<ReturnType<ReturnType<typeof createBusiness>['summary']>>;

const firstName = (n: string | null) => (n ? n.trim().split(/\s+/)[0] : null);
function dueLabel(iso: string, at: number): string {
  const t = Date.parse(iso);
  if (t - at < 6 * DAY) return new Date(t).toLocaleDateString('en-US', { weekday: 'short', timeZone: 'UTC' });
  return new Date(t).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
}

export function briefFacts(s: Summary, at: number): string[] {
  const f = [
    `Earned today: ${money(s.earned_today) || 'nothing yet'}`,
    `Earned this week: ${money(s.earned_this_week) || 'nothing yet'}`,
  ];
  if (Object.keys(s.fees_this_week).length) f.push(`PayPal fees this week: ${money(s.fees_this_week)}; net this week: ${money(s.net_this_week)}`);
  f.push(`Unpaid invoices: ${s.unpaid_count}${s.unpaid_count ? `, worth ${money(s.unpaid_amount)}` : ''}`);
  f.push(`Late invoices: ${s.late_count}`);
  if (s.most_late) {
    f.push(`Most late: ${firstName(s.most_late.client_name) ?? 'one client'}, ${s.most_late.days_over} days over, ${formatMoney(Math.round(Number(s.most_late.amount) * 100), s.most_late.currency)}`);
  }
  if (s.open_disputes !== null) f.push(`Open PayPal disputes: ${s.open_disputes}`);
  if (s.next_dispute_due?.due_date) f.push(`Next dispute reply due: ${dueLabel(s.next_dispute_due.due_date, at)}`);
  return f;
}

export function briefTemplate(s: Summary, at: number): string[] {
  const lines: string[] = [];
  const today = money(s.earned_today);
  const week = money(s.earned_this_week);
  lines.push(today ? `Brought back ${today} today, ${week} this week.` : week ? `Nothing in yet today. ${week} this week.` : 'Nothing in yet this week.');
  if (s.unpaid_count) {
    let l = `${s.unpaid_count} unpaid ${s.unpaid_count === 1 ? 'invoice' : 'invoices'}, ${money(s.unpaid_amount)} out.`;
    if (s.late_count) {
      const who = firstName(s.most_late?.client_name ?? null);
      l += ` ${s.late_count} late${who && s.most_late ? `, ${who}'s is ${s.most_late.days_over} days over` : ''}.`;
    }
    lines.push(l);
  } else {
    lines.push('Every invoice is paid.');
  }
  if (s.open_disputes) {
    const due = s.next_dispute_due?.due_date ? ` Next reply due ${dueLabel(s.next_dispute_due.due_date, at)}.` : '';
    lines.push(`${s.open_disputes} open ${s.open_disputes === 1 ? 'dispute' : 'disputes'}.${due}`);
  }
  return lines;
}

// Digit tokens and currency amounts only. Words like "no one" or "a few" are not counted.
function numbersIn(text: string): Set<string> {
  const out = new Set<string>();
  for (const m of text.matchAll(/\d[\d,]*(?:\.\d+)?/g)) out.add(String(Number(m[0].replace(/,/g, ''))));
  return out;
}

// The model may only restate numbers from the facts. Any other digit token or amount rejects the brief.
export function checkBrief(out: string, facts: string): string[] | null {
  const lines = out.split('\n').map((l) => clean(l).replace(/^(?:[-*•]|\d[.)])\s+/, '').trim()).filter(Boolean);
  if (lines.length < 1 || lines.length > 3 || lines.some((l) => l.length > 160)) return null;
  const allowed = numbersIn(facts);
  for (const n of numbersIn(lines.join(' '))) if (!allowed.has(n)) return null;
  return lines;
}
