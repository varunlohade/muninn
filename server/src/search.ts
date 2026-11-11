// Lookup over the owner's own records: "invoice for sam" finds Sam's latest invoice. Read only: it never moves money or sends mail.
import type { CatalogItem, Db, InvoiceRow, OrderRow, SubscriptionRow } from './db.ts';
import { centsToValue, formatMoney } from './money.ts';
import { editDistance, type Lookup } from './quick.ts';

export type Match = 'exact' | 'did_you_mean' | 'ambiguous' | 'none';

/** The client names (or catalog names) that `query` can mean, best tier first. Never a plain substring match. */
export function matchName(query: string, names: string[]): { match: Match; names: string[] } {
  const q = query.trim().toLowerCase().replace(/'s?$/, '');
  const uniq = [...new Map(names.filter(Boolean).map((n) => [n.trim().toLowerCase(), n.trim()])).values()];
  const words = (n: string) => n.toLowerCase().split(/\s+/);
  const pick = (hits: string[], one: Match): { match: Match; names: string[] } | null =>
    hits.length === 0 ? null : hits.length === 1 ? { match: one, names: hits } : { match: 'ambiguous', names: hits.slice(0, 3) };

  // 1. The full name, or one whole word of it ("sam" for "Sam Lee", "lee" for "Sam Lee").
  const exact = (w: string) => {
    const full = uniq.filter((n) => n.toLowerCase() === w);
    if (full.length === 1) return { match: 'exact' as Match, names: full };
    return pick(w.includes(' ') ? [] : uniq.filter((n) => words(n).includes(w)), 'exact');
  };
  const hit = exact(q) ?? (q.length > 3 && q.endsWith('s') ? exact(q.slice(0, -1)) : null);
  if (hit) return hit;
  // 2. The start of each word, in order: "sam" for "Samantha", "ana lo" for "Ana Lopez". Shown as "Did you mean".
  const qw = q.split(/\s+/);
  const prefix = uniq.filter((n) => {
    const nw = words(n);
    return qw.every((w) => w.length >= 2) && (qw.length === 1 ? nw.some((x) => x.startsWith(qw[0])) : qw.length <= nw.length && qw.every((w, i) => nw[i].startsWith(w)));
  });
  const p = pick(prefix, 'did_you_mean');
  if (p) return p;
  // 3. One typo in a name of 4 or more letters, and only when one client fits.
  if (q.replace(/\s/g, '').length < 4) return { match: 'none', names: [] };
  const typo = uniq.filter((n) => editDistance(q, n.toLowerCase()) <= 1 || (!q.includes(' ') && words(n).some((x) => x.length >= 4 && editDistance(q, x) <= 1)));
  return typo.length === 1 ? { match: 'did_you_mean', names: typo } : { match: 'none', names: [] };
}

/**
 * How much a lookup is worth showing, 0 to 1: the phrase (a full lookup phrase 0.6, unsure 0.3) plus the name
 * (exact 0.4, did-you-mean 0.25, several 0.2, unknown 0). 0.8 or more shows with no model call; 0.5 to 0.8 asks jev.
 * "invoice sam" is unsure, but one client with exactly that name settles it (0.7 → shown): the owner has a Sam to look up.
 */
export function importance(sure: boolean, match: Match, clients = 1): number {
  if (!sure && match === 'exact' && clients === 1) return 1;
  return (sure ? 0.6 : 0.3) + { exact: 0.4, did_you_mean: 0.25, ambiguous: 0.2, none: 0 }[match];
}
export const SHOW_AT = 0.8;
export const ASK_AT = 0.5;

export type RecordKind = 'invoice' | 'pay_link' | 'repeat' | 'item';
export type Rec = {
  kind: RecordKind; id: string; title: string; amount: string; currency: string;
  /** unpaid, paid, refunded, cancelled; a repeat bill: pending, active, cancelled; an item: price. */
  state: string; date: string | null; date_label: string | null; link: string | null;
  /** The short line Insert types for the client. */
  line: string;
  /** An unpaid invoice's Nudge chip: the same chip and confirm as /v1/suggest. */
  remind?: { kind: 'remind'; label: string; payload: Record<string, unknown>; needs_confirm: true };
};
export type Candidate = { name: string; records: Rec[]; empty_line: string | null };
export type LookupResult = {
  kind: Lookup['kind']; noun: string | null; query: string; match: Match;
  candidates: Candidate[];
  /** "Nothing from last week. Showing the latest." when a date or amount filter found nothing. */
  note: string | null;
  /** "invoice sam": a lookup that may also mean a new invoice, so the card offers New invoice too. */
  new_invoice: boolean;
};

export const invoiceState = (s: string) => (['PAID', 'MARKED_AS_PAID'].includes(s) ? 'paid' : ['REFUNDED', 'PARTIALLY_REFUNDED', 'MARKED_AS_REFUNDED'].includes(s) ? 'refunded' : s === 'CANCELLED' ? 'cancelled' : 'unpaid');
export const orderState = (s: string) => (s === 'COMPLETED' ? 'paid' : ['REFUNDED', 'PARTIALLY_REFUNDED'].includes(s) ? 'refunded' : 'unpaid');
const subState = (s: string) => (s === 'ACTIVE' ? 'active' : s === 'SUSPENDED' ? 'paused' : ['CANCELLED', 'EXPIRED'].includes(s) ? 'cancelled' : 'pending');
const EVERY: Record<string, string> = { week: 'weekly', month: 'monthly', year: 'yearly' };
const label = (at: number) => new Date(at).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' });
const plural = (noun: string) => (noun === 'delivery' ? 'deliveries' : noun === 'class' ? 'classes' : `${noun}s`);
const cap = (s: string) => s.replace(/(^|\s)\p{L}/gu, (c) => c.toUpperCase());
export const KIND_WORD: Record<RecordKind, string> = { invoice: 'invoice', pay_link: 'pay link', repeat: 'repeat bill', item: 'item' };

type Row = { kind: 'invoice'; r: InvoiceRow } | { kind: 'pay_link'; r: OrderRow } | { kind: 'repeat'; r: SubscriptionRow };

function record(row: Row, name: string): Rec {
  const { r } = row;
  const money = formatMoney(r.amount_cents, r.currency);
  const d = label(r.created_at);
  const base = { id: r.id, title: r.item, amount: centsToValue(r.amount_cents), currency: r.currency, date: new Date(r.created_at).toISOString().slice(0, 10), date_label: d };
  if (row.kind === 'invoice') {
    const state = invoiceState(row.r.status);
    const link = row.r.pay_link;
    const line = state === 'paid' ? `Your invoice for ${money} (${d}) is paid. Thank you!`
      : state === 'refunded' ? `Your ${money} payment (${d}) was refunded.`
        : state === 'cancelled' ? `Your invoice for ${money} (${d}) was cancelled.`
          : link ? `Your invoice for ${money} (${d}) is here: ${link}` : `Your invoice for ${money} (${d}) is still open.`;
    const remind = state === 'unpaid' && !row.r.paid_at
      ? { kind: 'remind' as const, label: `Nudge ${name} · ${money} owed`, payload: { invoice_id: r.id, client_name: name, amount: base.amount, currency: r.currency }, needs_confirm: true as const }
      : undefined;
    return { kind: 'invoice', ...base, state, link, line, ...(remind ? { remind } : {}) };
  }
  if (row.kind === 'pay_link') {
    const state = orderState(row.r.status);
    const link = row.r.approve_link;
    const line = state === 'paid' ? `Your ${money} payment (${d}) came through. Thank you!`
      : state === 'refunded' ? `Your ${money} payment (${d}) was refunded.`
        : link ? `Your pay link for ${money} (${d}) is here: ${link}` : `Your ${money} payment (${d}) is still open.`;
    return { kind: 'pay_link', ...base, state, link, line };
  }
  const state = subState(row.r.status);
  const every = EVERY[row.r.interval] ?? row.r.interval;
  const link = state === 'pending' ? row.r.approve_link : null;
  const line = state === 'active' ? `Your ${every} plan for ${money} is active.` : state === 'paused' ? `Your ${every} plan for ${money} is paused.` : state === 'cancelled' ? `Your ${every} plan for ${money} was cancelled.`
    : link ? `Your ${every} plan for ${money} is here: ${link}` : `Your ${every} plan for ${money} is waiting for approval.`;
  return { kind: 'repeat', ...base, state, link, line };
}

type Deps = { db: Db; dec: (userId: string, v: string | null) => string | null; namer: (userId: string) => (r: { client_name_enc: string | null; client_email_enc?: string | null; item: string }) => string | null };

export function createSearch({ db, dec, namer }: Deps) {
  /** Every record of the owner, newest first, under the client's display name. */
  function byClient(userId: string): Map<string, { name: string; rows: Row[] }> {
    const nameOf = namer(userId);
    const out = new Map<string, { name: string; rows: Row[] }>();
    const add = (row: Row) => {
      const n = nameOf(row.r)?.trim();
      if (!n) return;
      const key = n.toLowerCase();
      if (!out.has(key)) out.set(key, { name: n, rows: [] });
      out.get(key)!.rows.push(row);
    };
    for (const r of db.listInvoices(userId, 500)) add({ kind: 'invoice', r });
    for (const r of db.listOrders(userId, 500)) add({ kind: 'pay_link', r });
    for (const r of db.listSubscriptions(userId, 500)) add({ kind: 'repeat', r });
    for (const c of out.values()) c.rows.sort((a, b) => b.r.created_at - a.r.created_at);
    return out;
  }

  function catalog(items: CatalogItem[], l: Lookup): LookupResult | null {
    const m = matchName(l.name, items.map((i) => i.name));
    if (m.match === 'none') return null;
    const candidates = m.names.map((n) => {
      const it = items.find((i) => i.name.toLowerCase() === n.toLowerCase())!;
      const money = formatMoney(it.price_cents, it.currency);
      const rec: Rec = { kind: 'item', id: it.id, title: it.name, amount: centsToValue(it.price_cents), currency: it.currency, state: 'price', date: null, date_label: null, link: null, line: `${it.name} is ${money}.` };
      return { name: it.name, records: [rec], empty_line: null };
    });
    return { kind: 'catalog', noun: 'item', query: l.name, match: m.match, candidates, note: null, new_invoice: false };
  }

  /** The lookup's result: up to 3 clients, each with its latest record and up to 2 older ones. */
  function find(userId: string, l: Lookup): LookupResult | null {
    if (l.kind === 'catalog') return catalog(db.listItems(userId), l);
    const clients = byClient(userId);
    const m = matchName(l.name, [...clients.values()].map((c) => c.name));
    let note: string | null = null;
    const pickRows = (rows: Row[]) => {
      let out = rows.filter((x) => {
        if (l.noun === 'invoice' || l.noun === 'bill') return x.kind === 'invoice';
        return true;
      });
      if (l.want === 'unpaid') out = out.filter((x) => x.kind === 'invoice' && invoiceState(x.r.status) === 'unpaid' && !x.r.paid_at);
      if (l.want === 'paid') out = out.filter((x) => (x.kind === 'repeat' ? x.r.last_paid_at : x.r.paid_at) !== null);
      const narrow = (keep: (x: Row) => boolean, what: string) => {
        const kept = out.filter(keep);
        if (kept.length) out = kept;
        else if (out.length) note = `Nothing ${what}. Showing the latest.`;
      };
      if (l.range) narrow((x) => x.r.created_at >= l.range!.from && x.r.created_at < l.range!.to, `from ${l.range.words}`);
      if (l.cents !== null) narrow((x) => x.r.amount_cents === l.cents, `for ${formatMoney(l.cents, out[0]?.r.currency ?? 'USD')}`);
      return out.slice(0, 3);
    };
    const noun = l.noun ?? (l.want === 'unpaid' ? 'unpaid invoice' : 'payment');
    const names = m.match === 'none' ? [cap(l.name)] : m.names;
    const candidates = names.map((n) => {
      const c = clients.get(n.toLowerCase());
      const records = c ? pickRows(c.rows).map((row) => record(row, n)) : [];
      // The card shows the name above this line, so the line does not repeat it.
      const empty = l.want === 'unpaid' && c?.rows.length ? 'Owes you nothing right now' : `No ${plural(noun)} yet`;
      return { name: n, records, empty_line: records.length ? null : empty };
    });
    const newInvoice = !l.sure && (noun === 'invoice' || noun === 'bill');
    return { kind: l.kind, noun, query: l.name, match: m.match, candidates, note, new_invoice: newInvoice };
  }

  return { find };
}

/** What the keyboard chip says it found: "Sam's invoice · $120 · unpaid · Nov 9", "Did you mean Samantha? · invoice $120 · unpaid". */
export function chipLabel(r: LookupResult): string {
  if (r.match === 'ambiguous') return `${r.candidates.length} clients match "${cap(r.query)}" · pick one`;
  const c = r.candidates[0];
  const top = c.records[0];
  if (!top) return c.empty_line?.startsWith('No ') ? `${c.empty_line.replace(/ yet$/, '')} for ${c.name} yet` : `${c.name} ${(c.empty_line ?? 'has no records yet').replace(/^O/, 'o')}`;
  const money = formatMoney(Math.round(Number(top.amount) * 100), top.currency);
  if (top.kind === 'item') return r.match === 'did_you_mean' ? `Did you mean ${top.title}? · ${money}` : `${top.title} · ${money}`;
  const what = KIND_WORD[top.kind];
  const parts = r.match === 'did_you_mean'
    ? [`Did you mean ${c.name}?`, `${what} ${money}`, top.state, top.date_label]
    : [`${c.name}'s ${what}`, money, top.state, top.date_label];
  return parts.filter(Boolean).join(' · ');
}
