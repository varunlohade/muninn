import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { config } from './config.ts';
import { randomToken, sha256, type Cipher } from './crypto.ts';
import type { CatalogItem, Db, InvoiceRow, OrderRow } from './db.ts';
import type { Ai, Extraction } from './ai.ts';
import { PayPalError, type PayPalProvider } from './paypal.ts';
import { Amount, Currency, amountToCents, centsToValue, formatMoney } from './money.ts';
import { log } from './log.ts';
import { clean } from './text.ts';
import { getConnInfo } from '@hono/node-server/conninfo';

export type Deps = { db: Db; cipher: Cipher; ai: Ai; paypal: PayPalProvider; now?: () => number };
type Env = { Variables: { userId: string; idemSkip?: boolean } };
type Chip = { kind: string; label: string; payload: Record<string, unknown>; needs_confirm: boolean };

const DAY = 86_400_000;
const DEFAULT_PROFILE = { business_name: 'my shop', tone: 'friendly and short', currency: 'USD' };

class HttpError extends Error {
  status: 400 | 401 | 404 | 409 | 428 | 429;
  constructor(status: HttpError['status'], message: string) {
    super(message);
    this.status = status;
  }
}

function createLimiter({ limit, windowMs }: { limit: number; windowMs: number }) {
  const hits = new Map<string, { n: number; reset: number }>();
  const entry = (key: string) => {
    const now = Date.now();
    let h = hits.get(key);
    if (!h || h.reset <= now) {
      if (hits.size > 10_000) hits.clear();
      h = { n: 0, reset: now + windowMs };
      hits.set(key, h);
    }
    return h;
  };
  return {
    over: (key: string) => entry(key).n >= limit,
    hit: (key: string) => ++entry(key).n > limit,
    retryAfter: (key: string) => String(Math.max(1, Math.ceil((entry(key).reset - Date.now()) / 1000))),
  };
}

function rateLimiter(bucket: keyof typeof config.rateLimit, keyOf: (c: Context<Env>) => string): MiddlewareHandler<Env> {
  const limiter = createLimiter(config.rateLimit[bucket]);
  return async (c, next) => {
    const key = keyOf(c);
    if (limiter.hit(key)) {
      c.header('Retry-After', limiter.retryAfter(key));
      return c.json({ error: 'rate limited' }, 429);
    }
    await next();
  };
}

function clientIp(c: Context<Env>): string {
  if (config.trustProxy) {
    const hops = (c.req.header('x-forwarded-for') ?? '').split(',').map((h) => h.trim()).filter(Boolean);
    if (hops.length) return hops[hops.length - 1];
  }
  try {
    return getConnInfo(c).remote.address ?? 'direct';
  } catch {
    return 'direct';
  }
}

const CleanText = (max: number) => z.string().transform(clean).pipe(z.string().min(1).max(max));
const ClientName = CleanText(100).nullish();
const ClientEmail = z.string().trim().toLowerCase().email().max(254).nullish();
const Item = CleanText(120);
const TextBody = z.object({ text: z.string().trim().min(1).max(config.maxTextChars) }).strict();
const InvoiceBody = z.object({
  amount: Amount, currency: Currency.optional(), item: Item, client_name: ClientName, client_email: ClientEmail, confirm_recipient: ClientEmail,
}).strict();
const PayLinkBody = z.object({ amount: Amount, currency: Currency.optional(), item: Item, client_name: ClientName }).strict();
const RemindBody = z.object({ invoice_id: z.string().min(1).max(64) }).strict();
const RefundBody = z.union([
  z.object({ confirm_token: z.string().min(10).max(100) }).strict(),
  z.object({ id: z.string().min(1).max(64), amount: Amount.optional() }).strict(),
]);
const ProfileBody = z.object({
  business_name: CleanText(80), tone: CleanText(200), currency: Currency.default('USD'),
}).strict();
const ItemBody = z.object({ name: Item, price: Amount, currency: Currency.default('USD') }).strict();

export function createApp(deps: Deps) {
  const { db, cipher, ai, paypal } = deps;
  const now = deps.now ?? Date.now;
  const app = new Hono<Env>();

  // Clean stored text that reaches PayPal or the model, in case it was written before clean() covered it.
  for (const it of db.allItems()) {
    const name = clean(it.name);
    if (name && name !== it.name) db.updateItem(it.user_id, it.id, { name, price_cents: it.price_cents, currency: it.currency });
  }
  for (const p of db.allProfiles()) {
    const fixed = { business_name: clean(p.business_name) || p.business_name, tone: clean(p.tone) || p.tone, currency: p.currency };
    if (fixed.business_name !== p.business_name || fixed.tone !== p.tone) db.putProfile(p.user_id, fixed);
  }

  const enc = (userId: string, v: string | null | undefined) => (v ? cipher.encrypt(userId, v) : null);
  const dec = (userId: string, v: string | null) => {
    if (!v) return null;
    try {
      return cipher.decrypt(userId, v);
    } catch {
      log('decrypt_failed', { user_id: userId });
      return null;
    }
  };
  const body = async <T extends z.ZodTypeAny>(c: Context<Env>, schema: T): Promise<z.infer<T>> => {
    let raw: unknown;
    try {
      raw = await c.req.json();
    } catch {
      throw new HttpError(400, 'body must be JSON');
    }
    return schema.parse(raw);
  };
  const profileOf = (userId: string) => db.getProfile(userId) ?? DEFAULT_PROFILE;
  const catalogText = (items: CatalogItem[]) => items.map((i) => `${i.name} ${formatMoney(i.price_cents, i.currency)}`).join('; ');
  const requestIdFor = (userId: string, key: string) => sha256(`${userId}:${key}`).slice(0, 36);

  app.use('*', secureHeaders());
  app.use('*', cors({ origin: (origin) => (config.corsOrigins.includes(origin) ? origin : null), allowMethods: ['GET', 'POST', 'PUT', 'DELETE'] }));
  app.use('/v1/*', bodyLimit({ maxSize: config.bodyLimitBytes, onError: (c) => c.json({ error: 'body too large' }, 413) }));
  app.use('/webhooks/*', bodyLimit({ maxSize: 64 * 1024, onError: (c) => c.json({ error: 'body too large' }, 413) }));

  app.onError((err, c) => {
    if (err instanceof z.ZodError) return c.json({ error: 'invalid request', issues: err.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`) }, 400);
    if (err instanceof HttpError) return c.json({ error: err.message }, err.status);
    if (err instanceof PayPalError) {
      log('paypal_error', { path: c.req.path, err: err.message });
      return c.json({ error: 'PayPal request failed', detail: err.message }, 502);
    }
    log('error', { path: c.req.path, err: (err as Error).message });
    return c.json({ error: 'internal error' }, 500);
  });

  app.get('/health', (c) => c.json({ ok: true }));

  // ---- auth: every /v1 route resolves the user from the device token, never from the body
  app.use('/v1/*', async (c, next) => {
    const m = /^Bearer (pkd_[A-Za-z0-9_-]{20,100})$/.exec(c.req.header('authorization') ?? '');
    const userId = m ? db.userForTokenHash(sha256(m[1])) : undefined;
    if (!userId) return c.json({ error: 'unauthorized' }, 401);
    c.set('userId', userId);
    await next();
  });
  const byUser = (c: Context<Env>) => c.get('userId');
  app.use('/v1/suggest', rateLimiter('suggest', byUser));
  app.use('/v1/reply', rateLimiter('suggest', byUser));
  app.use('/v1/actions/*', rateLimiter('actions', byUser));
  app.use('/v1/*', rateLimiter('other', byUser));

  // ---- actions are default-deny: an explicit tap header plus an idempotency key
  app.use('/v1/actions/*', async (c, next) => {
    if (c.req.header('x-user-action') !== 'tap') return c.json({ error: 'actions run only from an explicit user tap' }, 428);
    const key = c.req.header('idempotency-key') ?? '';
    if (!/^[A-Za-z0-9_-]{8,64}$/.test(key)) return c.json({ error: 'Idempotency-Key header required (8-64 chars)' }, 400);
    const userId = c.get('userId');
    const raw = await c.req.text();
    const prior = db.reserveIdem(userId, key, c.req.path, sha256(raw));
    if (prior) {
      if (prior.route !== c.req.path || prior.body_hash !== sha256(raw)) return c.json({ error: 'Idempotency-Key reused with a different request' }, 409);
      if (prior.status !== 'done' || !prior.response) return c.json({ error: 'request with this Idempotency-Key is in progress' }, 409);
      return c.json(JSON.parse(prior.response), 200);
    }
    let stored = false;
    try {
      await next();
      if (c.res.status === 200 && !c.get('idemSkip')) {
        db.completeIdem(userId, key, await c.res.clone().text());
        stored = true;
      }
    } finally {
      if (!stored) db.releaseIdem(userId, key);
    }
  });
  const idemKey = (c: Context<Env>) => requestIdFor(c.get('userId'), c.req.header('idempotency-key')!);

  // ---- suggest
  app.post('/v1/suggest', async (c) => {
    const userId = c.get('userId');
    const { text } = await body(c, TextBody);
    const t0 = performance.now();
    const timings: Record<string, number> = {};
    const done = (chips: Chip[], intent: string, confidence: number) => {
      timings.total_ms = Math.round(performance.now() - t0);
      log('suggest', { user_id: userId, intent, confidence, chips: chips.length, ...timings });
      return c.json({ chips, intent, confidence, timings });
    };

    const items = db.listItems(userId);
    const profile = profileOf(userId);
    // Speculative: extraction runs alongside jev, so the total is about max(jev, extract), not the sum.
    const extracting = ai.extract(text, catalogText(items)).then(
      (ext) => { timings.extract_ms = Math.round(performance.now() - t0); return ext; },
      (e) => { timings.extract_ms = Math.round(performance.now() - t0); log('extract_failed', { err: (e as Error).message }); return null; },
    );

    let cls;
    try {
      cls = await ai.classify(text);
    } catch (e) {
      timings.classify_ms = Math.round(performance.now() - t0);
      log('classify_failed', { err: (e as Error).message });
      return done([], 'error', 0);
    }
    timings.classify_ms = cls.ms;
    if (cls.intent === 'none' || cls.confidence < config.jev.minConfidence) return done([], cls.intent, cls.confidence);

    let ext: Extraction | null = null;
    if (['create_invoice', 'pay_link', 'send_reminder', 'refund'].includes(cls.intent)) {
      ext = await extracting;
      if (!ext) return done([], cls.intent, cls.confidence);
    }

    const chips = buildChips(userId, cls.intent, ext, text, items, profile.currency);
    return done(chips, cls.intent, cls.confidence);
  });

  const chip = (kind: string, label: string, payload: Record<string, unknown>, needsConfirm = false): Chip =>
    ({ kind, label: clean(label), payload, needs_confirm: needsConfirm });
  const cleanOrNull = (v: string | null | undefined, max: number) => (v ? clean(v).slice(0, max) || null : null);

  const knownClient = (userId: string, email: string) => db.listInvoices(userId, 200).some((r) => dec(userId, r.client_email_enc) === email);

  function buildChips(userId: string, intent: string, rawExt: Extraction | null, text: string, items: CatalogItem[], defaultCurrency: string): Chip[] {
    const ext = rawExt && { ...rawExt, item: cleanOrNull(rawExt.item, 120), client_name: cleanOrNull(rawExt.client_name, 100) };
    const lower = text.toLowerCase();
    const match = items.find((i) => lower.includes(i.name.toLowerCase()) || (ext?.item && ext.item.toLowerCase().includes(i.name.toLowerCase())));
    const currency = (config.money.currencies as readonly string[]).includes(ext?.currency ?? '') ? ext!.currency! : match?.currency ?? defaultCurrency;

    if (intent === 'create_invoice' || intent === 'pay_link') {
      const cents = ext?.amount != null ? amountToCents(ext.amount) : match?.price_cents ?? null;
      if (cents === null) return [];
      const item = ext?.item ? ext.item.charAt(0).toUpperCase() + ext.item.slice(1) : match?.name ?? 'Payment';
      const money = formatMoney(cents, currency);
      const base = { amount: centsToValue(cents), currency, item, client_name: ext?.client_name ?? null };
      const email = ext?.client_email ?? null;
      const recipient = email ?? ext?.client_name ?? null;
      // The model can inject an email. Only an email the owner typed, or a known client, is pre-confirmed.
      const confirmed = email ? lower.includes(email) || knownClient(userId, email) : true;
      const invoice = chip('invoice', `Invoice ${money} · ${item}${recipient ? ` → ${recipient}` : ''}`,
        { ...base, client_email: email, ...(email && confirmed ? { confirm_recipient: email } : {}) }, !confirmed);
      const link = chip('paylink', `Pay link ${money} · ${item}`, base);
      return intent === 'create_invoice' ? [invoice, link] : [link, invoice];
    }
    if (intent === 'payment_status') {
      const unpaid = db.unpaidCount(userId);
      return [chip('payments', `Who paid? · ${unpaid} unpaid`, {})];
    }
    if (intent === 'send_reminder') {
      const want = ext?.client_name?.toLowerCase();
      const unpaid = db.listInvoices(userId).filter((r) => !r.paid_at && r.status !== 'CANCELLED');
      const hit = unpaid.find((r) => !want || (dec(userId, r.client_name_enc) ?? '').toLowerCase().includes(want)) ?? null;
      if (!hit) return [];
      const name = dec(userId, hit.client_name_enc) ?? hit.item;
      return [chip('remind', `Remind ${name} · ${formatMoney(hit.amount_cents, hit.currency)}`, { invoice_id: hit.id })];
    }
    if (intent === 'refund') {
      const want = ext?.client_name?.toLowerCase();
      const cents = ext?.amount != null ? amountToCents(ext.amount) : null;
      const left = (r: InvoiceRow | OrderRow) => r.amount_cents - db.refundState(userId, r.id).doneCents;
      const paid = [...db.listInvoices(userId), ...db.listOrders(userId)].filter((r) => r.paid_at && r.capture_id && r.status !== 'REFUNDED' && left(r) > 0);
      const hit = paid.find((r) => (!want || (dec(userId, r.client_name_enc) ?? '').toLowerCase().includes(want)) && (cents === null || cents <= left(r)));
      if (!hit) return [];
      const refundCents = cents ?? left(hit);
      const who = dec(userId, hit.client_name_enc) ?? hit.item;
      return [chip('refund', `Refund ${formatMoney(refundCents, hit.currency)} · ${who}`, { id: hit.id, amount: centsToValue(refundCents) })];
    }
    if (intent === 'catalog_reply') {
      return items.length ? [chip('reply', 'Reply with prices', {})] : [];
    }
    return [];
  }

  // ---- money actions
  app.post('/v1/actions/invoice', async (c) => {
    const userId = c.get('userId');
    const b = await body(c, InvoiceBody);
    if (b.client_email && b.confirm_recipient !== b.client_email && !knownClient(userId, b.client_email)) {
      c.set('idemSkip', true);
      return c.json({ error: 'confirm the recipient', needs_confirm: true, recipient: b.client_email }, 409);
    }
    const profile = db.getProfile(userId);
    const currency = b.currency ?? profile?.currency ?? 'USD';
    const t = performance.now();
    const inv = await paypal.forUser(userId).createAndSendInvoice({
      value: centsToValue(b.amount), currency, item: b.item, clientName: b.client_name ?? null, clientEmail: b.client_email ?? null,
      businessName: profile?.business_name ?? null,
    }, idemKey(c));
    const created = now();
    db.insertInvoice({
      id: inv.id, user_id: userId, status: inv.status, amount_cents: b.amount, currency, item: b.item,
      client_name_enc: enc(userId, b.client_name), client_email_enc: enc(userId, b.client_email), pay_link: inv.payLink,
      due_at: created + config.money.invoiceDueDays * DAY, created_at: created,
    });
    const ms = Math.round(performance.now() - t);
    log('invoice_created', { user_id: userId, invoice_id: inv.id, status: inv.status, paypal_ms: ms });
    return c.json({ id: inv.id, status: inv.status, pay_link: inv.payLink, amount: centsToValue(b.amount), currency, paypal_ms: ms });
  });

  app.post('/v1/actions/paylink', async (c) => {
    const userId = c.get('userId');
    const b = await body(c, PayLinkBody);
    const currency = b.currency ?? db.getProfile(userId)?.currency ?? 'USD';
    const t = performance.now();
    const o = await paypal.forUser(userId).createOrder({ value: centsToValue(b.amount), currency, item: b.item }, idemKey(c));
    db.insertOrder({
      id: o.id, user_id: userId, status: o.status, amount_cents: b.amount, currency, item: b.item,
      client_name_enc: enc(userId, b.client_name), approve_link: o.approveLink, created_at: now(),
    });
    const ms = Math.round(performance.now() - t);
    log('order_created', { user_id: userId, order_id: o.id, status: o.status, paypal_ms: ms });
    return c.json({ id: o.id, status: o.status, approve_link: o.approveLink, amount: centsToValue(b.amount), currency, paypal_ms: ms });
  });

  app.post('/v1/actions/remind', async (c) => {
    const userId = c.get('userId');
    const { invoice_id } = await body(c, RemindBody);
    const inv = db.getInvoice(userId, invoice_id);
    if (!inv) throw new HttpError(404, 'invoice not found');
    if (inv.paid_at) throw new HttpError(409, 'invoice is already paid');
    await paypal.forUser(userId).remind(inv.id, idemKey(c));
    db.addReminder(userId, inv.id);
    log('reminder_sent', { user_id: userId, invoice_id: inv.id });
    return c.json({ ok: true, invoice_id: inv.id });
  });

  app.post('/v1/actions/refund', async (c) => {
    const userId = c.get('userId');
    const b = await body(c, RefundBody);
    if ('confirm_token' in b) {
      const claim = db.claimRefund(userId, sha256(b.confirm_token), now());
      if ('error' in claim) {
        if (claim.error === 'busy') throw new HttpError(409, 'another refund on this payment is running');
        throw new HttpError(404, 'confirm token not found, used or expired');
      }
      const r = claim.ok;
      try {
        const out = await paypal.forUser(userId).refundCapture(r.capture_id, centsToValue(r.amount_cents), r.currency, r.id);
        db.finishRefund(userId, r.id, 'done', out.id);
        const target = r.target_kind === 'invoice' ? db.getInvoice(userId, r.target_id) : db.getOrder(userId, r.target_id);
        const status = db.refundState(userId, r.target_id).doneCents >= (target?.amount_cents ?? 0) ? 'REFUNDED' : 'PARTIALLY_REFUNDED';
        if (r.target_kind === 'invoice') db.setInvoiceStatus(userId, r.target_id, status, null, null);
        else db.setOrderStatus(userId, r.target_id, status, null, null);
        log('refund_done', { user_id: userId, target_id: r.target_id, refund_id: out.id, status });
        return c.json({ ok: true, refund_id: out.id, status: out.status, amount: centsToValue(r.amount_cents), currency: r.currency });
      } catch (e) {
        db.finishRefund(userId, r.id, 'failed', null);
        throw e;
      }
    }
    c.set('idemSkip', true);
    const inv = db.getInvoice(userId, b.id);
    const target: InvoiceRow | OrderRow | undefined = inv ?? db.getOrder(userId, b.id);
    const kind = inv ? 'invoice' : 'order';
    if (!target) throw new HttpError(404, 'payment not found');
    if (!target.paid_at || !target.capture_id) throw new HttpError(409, 'payment is not captured yet, nothing to refund');
    if (target.status === 'REFUNDED') throw new HttpError(409, 'payment is already refunded');
    const state = db.refundState(userId, target.id);
    if (state.running > 0) throw new HttpError(409, 'another refund on this payment is running');
    const left = target.amount_cents - state.doneCents;
    const cents = b.amount ?? left;
    if (cents > left) throw new HttpError(400, `refund is larger than what is left (${centsToValue(left)})`);
    const token = randomToken('rf');
    db.insertRefund({
      id: randomUUID(), user_id: userId, target_kind: kind, target_id: target.id, amount_cents: cents, currency: target.currency,
      capture_id: target.capture_id, token_hash: sha256(token), expires_at: now() + config.money.refundConfirmTtlMs, status: 'pending',
    });
    const who = dec(userId, target.client_name_enc) ?? target.item;
    return c.json({ confirm_token: token, expires_in_s: config.money.refundConfirmTtlMs / 1000, summary: `Refund ${formatMoney(cents, target.currency)} to ${who}?` });
  });

  // ---- read views
  const invoiceState = (s: string) => (['PAID', 'MARKED_AS_PAID'].includes(s) ? 'paid' : ['REFUNDED', 'PARTIALLY_REFUNDED', 'MARKED_AS_REFUNDED'].includes(s) ? 'refunded' : s === 'CANCELLED' ? 'cancelled' : 'unpaid');
  const orderState = (s: string) => (s === 'COMPLETED' ? 'paid' : ['REFUNDED', 'PARTIALLY_REFUNDED'].includes(s) ? 'refunded' : 'unpaid');

  app.get('/v1/payments', async (c) => {
    const userId = c.get('userId');
    if (c.req.query('refresh') === '1') {
      const pp = paypal.forUser(userId);
      const stale = db.listInvoices(userId, 10).filter((r) => invoiceState(r.status) === 'unpaid');
      await Promise.all(stale.map(async (r) => {
        try {
          const s = await pp.getInvoice(r.id);
          db.setInvoiceStatus(userId, r.id, s.status, invoiceState(s.status) === 'paid' ? now() : null, s.captureId);
        } catch (e) {
          log('refresh_failed', { invoice_id: r.id, err: (e as Error).message });
        }
      }));
    }
    const t = now();
    const invoices = db.listInvoices(userId).map((r) => {
      const state = invoiceState(r.status);
      return {
        kind: 'invoice', id: r.id, state, paypal_status: r.status, amount: centsToValue(r.amount_cents), currency: r.currency, item: r.item,
        client_name: dec(userId, r.client_name_enc), link: r.pay_link, created_at: new Date(r.created_at).toISOString(),
        days_overdue: state === 'unpaid' && t > r.due_at ? Math.floor((t - r.due_at) / DAY) : 0,
      };
    });
    const orders = db.listOrders(userId).map((r) => ({
      kind: 'order', id: r.id, state: orderState(r.status), paypal_status: r.status, amount: centsToValue(r.amount_cents), currency: r.currency,
      item: r.item, client_name: dec(userId, r.client_name_enc), link: r.approve_link, created_at: new Date(r.created_at).toISOString(), days_overdue: 0,
    }));
    const payments = [...invoices, ...orders].sort((a, b) => b.created_at.localeCompare(a.created_at));
    return c.json({ payments });
  });

  app.get('/v1/summary', (c) => {
    const userId = c.get('userId');
    const d = new Date(now());
    const today = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
    const week = today - ((d.getUTCDay() + 6) % 7) * DAY;
    const sum = (since: number) => Object.fromEntries(db.paidSince(userId, since).map((r) => [r.currency, centsToValue(r.cents)]));
    return c.json({ earned_today: sum(today), earned_this_week: sum(week), unpaid_count: db.unpaidCount(userId), timezone: 'UTC' });
  });

  app.post('/v1/reply', async (c) => {
    const userId = c.get('userId');
    const { text } = await body(c, TextBody);
    const t = performance.now();
    const reply = await ai.reply(text, profileOf(userId), catalogText(db.listItems(userId)));
    const ms = Math.round(performance.now() - t);
    log('reply', { user_id: userId, ms });
    return c.json({ reply, ms });
  });

  // ---- profile and catalog
  app.get('/v1/profile', (c) => c.json({ profile: db.getProfile(c.get('userId')) ?? null }));
  app.put('/v1/profile', async (c) => {
    const p = await body(c, ProfileBody);
    db.putProfile(c.get('userId'), p);
    return c.json({ profile: p });
  });
  const itemOut = (i: CatalogItem) => ({ id: i.id, name: i.name, price: centsToValue(i.price_cents), currency: i.currency });
  app.get('/v1/catalog', (c) => c.json({ items: db.listItems(c.get('userId')).map(itemOut) }));
  app.post('/v1/catalog', async (c) => {
    const b = await body(c, ItemBody);
    return c.json({ item: itemOut(db.addItem(c.get('userId'), { name: b.name, price_cents: b.price, currency: b.currency })) });
  });
  app.put('/v1/catalog/:id', async (c) => {
    const b = await body(c, ItemBody);
    const it = { name: b.name, price_cents: b.price, currency: b.currency };
    if (!db.updateItem(c.get('userId'), c.req.param('id'), it)) throw new HttpError(404, 'item not found');
    return c.json({ item: itemOut({ id: c.req.param('id'), ...it }) });
  });
  app.delete('/v1/catalog/:id', (c) => {
    if (!db.deleteItem(c.get('userId'), c.req.param('id'))) throw new HttpError(404, 'item not found');
    return c.json({ ok: true });
  });

  // ---- PayPal webhooks: verify with PayPal, then map ids to owners through our own tables
  // Failed verifications count per client IP; verified events have their own global budget,
  // so spoofed traffic cannot use up the budget that real PayPal events need.
  const webhookFailures = createLimiter(config.rateLimit.webhook);
  const webhookVerified = createLimiter(config.rateLimit.webhookVerified);
  app.post('/webhooks/paypal', async (c) => {
    const ip = clientIp(c);
    if (webhookFailures.over(ip)) {
      c.header('Retry-After', webhookFailures.retryAfter(ip));
      return c.json({ error: 'rate limited' }, 429);
    }
    let event: any;
    try {
      event = await c.req.json();
    } catch {
      webhookFailures.hit(ip);
      return c.json({ error: 'bad json' }, 400);
    }
    const h = Object.fromEntries(['paypal-auth-algo', 'paypal-cert-url', 'paypal-transmission-id', 'paypal-transmission-sig', 'paypal-transmission-time']
      .map((k) => [k, c.req.header(k)]));
    let ok = false;
    try {
      ok = Object.values(h).every(Boolean) && (await paypal.platform().verifyWebhook(h, event));
    } catch (e) {
      log('webhook_verify_error', { err: (e as Error).message });
    }
    if (!ok) {
      webhookFailures.hit(ip);
      log('webhook_rejected', { event_type: event?.event_type });
      return c.json({ error: 'signature verification failed' }, 401);
    }
    if (webhookVerified.hit('all')) return c.json({ error: 'rate limited' }, 429);
    const type = String(event?.event_type ?? '');
    const res = event?.resource ?? {};
    let handled = false;
    if (type === 'INVOICING.INVOICE.PAID') {
      const id = res.invoice?.id ?? res.id;
      const owner = id && db.ownerOfInvoice(id);
      if (owner) {
        db.setInvoiceStatus(owner, id, 'PAID', now(), res.invoice?.payments?.transactions?.[0]?.payment_id ?? null);
        handled = true;
      }
    } else if (type === 'CHECKOUT.ORDER.APPROVED') {
      const owner = res.id && db.ownerOfOrder(res.id);
      if (owner) {
        const cap = await paypal.forUser(owner).captureOrder(res.id, `capture-${res.id}`);
        db.setOrderStatus(owner, res.id, cap.status, cap.status === 'COMPLETED' ? now() : null, cap.captureId);
        handled = true;
      }
    } else if (type === 'PAYMENT.CAPTURE.COMPLETED') {
      const orderId = res.supplementary_data?.related_ids?.order_id;
      const owner = orderId && db.ownerOfOrder(orderId);
      if (owner) {
        db.setOrderStatus(owner, orderId, 'COMPLETED', now(), res.id ?? null);
        handled = true;
      }
    }
    log('webhook', { event_type: type, handled });
    return c.json({ ok: true, handled });
  });

  return app;
}
