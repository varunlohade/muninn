import { randomUUID } from 'node:crypto';
import type { Ai } from './ai.ts';
import { config } from './config.ts';
import type { Cipher } from './crypto.ts';
import type { Db, LearnedClientRow, Profile } from './db.ts';
import { log } from './log.ts';
import { centsToValue, formatMoney, valueToCents } from './money.ts';
import type { PayPalProvider, PayPalTxn } from './paypal.ts';
import { mentions } from './quick.ts';
import { clean } from './text.ts';

// After the owner connects their own PayPal, Muninn reads the last 90 days of payments once, in the background,
// and learns who pays and for what. Only item names and prices ever reach the model, never payer names or emails.
const DAY = 86_400_000;
const LOOKBACK_DAYS = 90;
// Transaction Search allows at most 31 days per query.
const WINDOW_DAYS = 31;
const MAX_ITEMS = 10;

export type LearnedItem = { name: string; amount: string; currency: string; count: number };
export type Usual = { item: string; amount: string; currency: string };
export type LearnedFacts = { payments: number; currency: string | null; country: string | null; items: LearnedItem[] };
export type LearnedClient = { name: string | null; email: string | null; usual: Usual | null };

/** T00xx are payments; only money coming in, not reversed or denied, tells what the business sells. */
const received = (t: PayPalTxn) => /^T00\d\d$/.test(t.event_code) && !['V', 'D'].includes(t.status) && (valueToCents(t.amount.value) ?? 0) > 0;
const normEmail = (e: string | null | undefined) => (e && /^[^\s@]+@[^\s@]+$/.test(e.trim()) ? e.trim().toLowerCase() : null);
const normName = (n: string | null | undefined) => (n ? clean(n).slice(0, 100) || null : null);
const itemName = (n: string | null | undefined) => (n ? clean(n).slice(0, 60) || null : null);

const median = (xs: number[]) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : Math.round((s[m - 1] + s[m]) / 2);
};
const mostCommon = <T>(xs: T[]): T | null => {
  const n = new Map<T, number>();
  for (const x of xs) n.set(x, (n.get(x) ?? 0) + 1);
  return [...n].sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
};

type Sale = { item: string; cents: number; currency: string };
/** What one payment was for: its cart items, else its subject or note, at the payment's amount. */
function salesOf(t: PayPalTxn): Sale[] {
  const priced = (t.items ?? []).flatMap((it) => {
    const name = itemName(it.name);
    const cents = it.amount ? valueToCents(it.amount.value) : null;
    return name && cents && cents > 0 ? [{ item: name, cents, currency: it.amount!.currency }] : [];
  });
  if (priced.length) return priced;
  const name = itemName(t.subject) ?? itemName(t.note);
  return name ? [{ item: name, cents: valueToCents(t.amount.value)!, currency: t.amount.currency }] : [];
}

/** Item names with the median price of one, most sold first. Pure, so tests can feed it payments directly. */
export function learnFrom(txns: PayPalTxn[]) {
  const seen = new Set<string>();
  const pays = txns.filter((t) => received(t) && !seen.has(t.id) && !!seen.add(t.id));
  const byItem = new Map<string, { name: string; sales: Sale[] }>();
  for (const s of pays.flatMap(salesOf)) {
    const k = s.item.toLowerCase();
    const e = byItem.get(k) ?? { name: s.item, sales: [] };
    e.sales.push(s);
    byItem.set(k, e);
  }
  const priceOf = (sales: Sale[]): Usual & { count: number } => {
    const currency = mostCommon(sales.map((s) => s.currency))!;
    const same = sales.filter((s) => s.currency === currency);
    return { item: sales[0].item, amount: centsToValue(median(same.map((s) => s.cents))), currency, count: sales.length };
  };
  const items: LearnedItem[] = [...byItem.values()].map((e) => ({ ...priceOf(e.sales), name: e.name }))
    .sort((a, b) => b.count - a.count || a.name.localeCompare(b.name)).slice(0, MAX_ITEMS)
    .map(({ name, amount, currency, count }) => ({ name, amount, currency, count }));

  // One client per email, else per name. Their usual: the item they paid for most, at its median price for them.
  const clients = new Map<string, { name: string | null; email: string | null; sales: Sale[] }>();
  for (const t of pays) {
    const name = normName(t.payer_name);
    const email = normEmail(t.payer_email);
    if (!name && !email) continue;
    const k = email ?? `name:${name!.toLowerCase()}`;
    const c = clients.get(k) ?? { name, email, sales: [] };
    if (name && (!c.name || name.length > c.name.length)) c.name = name;
    c.sales.push(...salesOf(t));
    clients.set(k, c);
  }
  return {
    payments: pays.length,
    currency: mostCommon(pays.map((t) => t.amount.currency)),
    items,
    clients: [...clients.values()].map((c): LearnedClient => {
      const top = mostCommon(c.sales.map((s) => s.item.toLowerCase()));
      const usual = top ? priceOf(c.sales.filter((s) => s.item.toLowerCase() === top)) : null;
      return { name: c.name, email: c.email, usual: usual && { item: usual.item, amount: usual.amount, currency: usual.currency } };
    }),
  };
}

type Deps = { db: Db; cipher: Cipher; ai: Ai; paypal: PayPalProvider; now: () => number; defaultProfile: Profile };

export function createLearner({ db, cipher, ai, paypal, now, defaultProfile }: Deps) {
  const enc = (userId: string, v: string | null) => (v ? cipher.encrypt(userId, v) : null);
  const dec = (userId: string, v: string | null) => {
    if (!v) return null;
    try {
      return cipher.decrypt(userId, v);
    } catch {
      log('decrypt_failed', { user_id: userId });
      return null;
    }
  };
  const nameKey = (userId: string, n: string) => cipher.lookupHash('learned-name', `${userId}:${n.toLowerCase()}`);
  const emailKey = (userId: string, e: string) => cipher.lookupHash('learned-email', `${userId}:${e}`);
  const running = new Set<string>();
  // Bumped by forget(), so an import still running when the owner disconnects stores nothing.
  const generation = new Map<string, number>();

  /** Adds each client once: a stored client with the same email, else the same name, is updated in place. */
  function upsertClients(userId: string, found: LearnedClient[]) {
    const rows = db.listLearnedClients(userId);
    for (const c of found) {
      const nh = c.name ? nameKey(userId, c.name) : null;
      const eh = c.email ? emailKey(userId, c.email) : null;
      const old = (eh && rows.find((r) => r.email_hash === eh)) || (nh && rows.find((r) => r.name_hash === nh && (!r.email_hash || !eh))) || null;
      const row: LearnedClientRow = {
        id: old?.id ?? randomUUID(),
        name_hash: nh ?? old?.name_hash ?? null, name_enc: c.name ? enc(userId, c.name) : old?.name_enc ?? null,
        email_hash: eh ?? old?.email_hash ?? null, email_enc: c.email ? enc(userId, c.email) : old?.email_enc ?? null,
        usual_enc: c.usual ? enc(userId, JSON.stringify(c.usual)) : old?.usual_enc ?? null,
      };
      db.putLearnedClient(userId, row, now());
      if (!old) rows.push(row);
      else Object.assign(old, row);
    }
  }

  /**
   * Reads the last 90 days from the owner's own PayPal and stores what it learned. The demo account (null) is
   * everyone's, so it teaches nothing. Never throws: a failure is logged and the owner just types as before.
   */
  async function run(userId: string, account: string | null, seller: { currency?: string | null; country?: string | null } = {}) {
    if (!account || running.has(userId)) return;
    running.add(userId);
    const gen = generation.get(userId) ?? 0;
    try {
      const pp = paypal.forAccount(userId, account);
      const end = now();
      const txns: PayPalTxn[] = [];
      for (let to = end; to > end - LOOKBACK_DAYS * DAY; to -= WINDOW_DAYS * DAY) {
        const from = Math.max(end - LOOKBACK_DAYS * DAY, to - WINDOW_DAYS * DAY);
        txns.push(...await pp.searchTransactions(new Date(from), new Date(to), { cart: true }));
      }
      const l = learnFrom(txns);
      if ((generation.get(userId) ?? 0) !== gen) return log('paypal_learn_dropped', { user_id: userId });
      upsertClients(userId, l.clients);
      const facts: LearnedFacts = { payments: l.payments, currency: seller.currency ?? l.currency, country: seller.country ?? null, items: l.items };
      db.putLearnedFacts(userId, cipher.encrypt(userId, JSON.stringify(facts)), now());
      let described = false;
      // The profile gets a description only while the owner has not written one. The model sees item names and prices only.
      if (l.items.length && !db.getDescriptionEnc(userId)) {
        const out = clean(await ai.describe(l.items.map((i) => `${i.name}: about ${formatMoney(Math.round(Number(i.amount) * 100), i.currency)}`).join('\n')));
        const text = out.slice(0, 300);
        if (text && !text.includes('@') && !db.getDescriptionEnc(userId)) {
          db.setDescriptionEnc(userId, cipher.encrypt(userId, text), { ...defaultProfile, currency: usable(facts.currency) ?? defaultProfile.currency });
          described = true;
        }
      }
      log('paypal_learned', { user_id: userId, payments: l.payments, clients: l.clients.length, items: l.items.length, described });
    } catch (e) {
      log('paypal_learn_failed', { user_id: userId, err: (e as Error).message });
    } finally {
      running.delete(userId);
    }
  }

  const usable = (c: string | null) => (c && (config.money.currencies as readonly string[]).includes(c) ? c : null);

  function facts(userId: string): LearnedFacts | null {
    const raw = dec(userId, db.getLearnedFacts(userId)?.facts_enc ?? null);
    return raw ? JSON.parse(raw) as LearnedFacts : null;
  }

  function clients(userId: string): LearnedClient[] {
    return db.listLearnedClients(userId).map((r) => {
      const usual = dec(userId, r.usual_enc);
      return { name: dec(userId, r.name_enc), email: dec(userId, r.email_enc), usual: usual ? JSON.parse(usual) as Usual : null };
    });
  }

  /** The one learned client the owner's text names, by full name, else by a first name only one client has. */
  function named(userId: string, text: string): LearnedClient | null {
    const all = clients(userId).filter((c) => c.name);
    const full = all.filter((c) => mentions(text, c.name!));
    if (full.length) return full.length === 1 ? full[0] : null;
    const first = all.filter((c) => mentions(text, c.name!.split(/\s+/)[0]));
    return first.length === 1 ? first[0] : null;
  }

  /** Learned items and currency for the model's context. No client names or emails. Empty when nothing was learned. */
  function context(userId: string): string {
    const f = facts(userId);
    if (!f?.items.length) return '';
    const items = f.items.slice(0, 5).map((i) => `${i.name} (usually ${formatMoney(Math.round(Number(i.amount) * 100), i.currency)})`).join('; ');
    return `Usually paid for: ${items}.${f.currency ? ` Main currency: ${f.currency}.` : ''}`;
  }

  function summary(userId: string) {
    const got = db.getLearnedFacts(userId);
    if (!got) return null;
    const f = facts(userId);
    const n = db.listLearnedClients(userId).length;
    const items = f?.items.length ?? 0;
    const plural = (k: number, w: string) => `${k} ${w}${k === 1 ? '' : 's'}`;
    return {
      clients: n, items, payments: f?.payments ?? 0, currency: f?.currency ?? null, country: f?.country ?? null,
      learned_at: new Date(got.learned_at).toISOString(),
      line: n || items ? `Learned ${plural(n, 'client')} and ${plural(items, 'item')} from PayPal` : 'No PayPal sales in the last 90 days to learn from',
      top_items: f?.items.slice(0, 5).map((i) => ({ name: i.name, amount: i.amount, currency: i.currency })) ?? [],
    };
  }

  /** Disconnect or a revoke: what was learned from that PayPal goes, and an import still running stores nothing. */
  function forget(userId: string) {
    generation.set(userId, (generation.get(userId) ?? 0) + 1);
    if (generation.size > 10_000) generation.clear();
    db.removeLearned(userId);
  }

  return { run, forget, facts, clients, named, context, summary };
}
