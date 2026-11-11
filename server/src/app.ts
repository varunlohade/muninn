import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { config, INTERVALS, TONES, type AskGroup, type Interval, type AskRoute, type Intent, type Tone } from './config.ts';
import { randomToken, sha256, type Cipher } from './crypto.ts';
import type { CatalogItem, Db, InvoiceRow, OrderRow } from './db.ts';
import type { Ai, Extraction } from './ai.ts';
import { PayPalError, type PayPalProvider } from './paypal.ts';
import { Amount, Currency, amountToCents, centsToValue, formatMoney } from './money.ts';
import { log } from './log.ts';
import { clean } from './text.ts';
import { askQuick, intervalOf, mentions, noteText, onlyKnownWords, quick, typedEmails, withoutInterval, type Quick } from './quick.ts';
import { getConnInfo } from '@hono/node-server/conninfo';
import { createIntegrations } from './integrations.ts';
import { RANGES, createBusiness } from './business.ts';
import { createAppleVerifier, type AppleVerifier } from './apple.ts';

export type Deps = {
  db: Db; cipher: Cipher; ai: Ai; paypal: PayPalProvider; now?: () => number;
  apple?: AppleVerifier;
  /** Runs once for each user that Sign in with Apple creates. The demo server seeds the demo business here. */
  onNewUser?: (userId: string) => void;
};
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
  if (config.trustProxy && config.clientIpHeader) {
    const ip = c.req.header(config.clientIpHeader)?.trim();
    if (ip) return ip;
  }
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
// context: text the owner copied from the client (e.g. "how much do I owe you?"). Cleaned and capped, never trusted for recipients.
const SuggestBody = z.object({
  text: z.string().trim().max(config.maxTextChars),
  context: z.string().transform((v) => clean(v).slice(0, config.maxContextChars)).optional(),
}).strict().refine((b) => b.text || b.context, { message: 'text or context is required' });
// Writing help: one paragraph, cleaned and capped. The text is never stored or logged.
const WriteText = CleanText(config.maxWriteChars);
// An empty ask is allowed: it routes to "none" with no paid call.
const AskBody = z.object({ text: z.string().trim().max(config.maxTextChars) }).strict();
const FixBody = z.object({ text: WriteText }).strict();
const RefineBody = z.object({ text: WriteText, tone: z.enum(TONES) }).strict();
const OptionalWriteText = z.string().transform(clean).pipe(z.string().max(config.maxWriteChars)).optional();
const ToneBody = z.object({ text: OptionalWriteText, context: OptionalWriteText }).strict()
  .refine((b) => b.text || b.context, { message: 'text or context is required' });
const InvoiceBody = z.object({
  amount: Amount, currency: Currency.optional(), item: Item, client_name: ClientName, client_email: ClientEmail,
  // Set by the owner's confirm tap, which shows both. An invoice that emails someone needs both to match.
  confirm_recipient: ClientEmail, confirm_amount: Amount.optional(), confirm_currency: Currency.optional(),
}).strict();
// A repeat bill always confirms amount, currency and interval on the server, and the recipient when PayPal gets an email.
const SubscribeBody = z.object({
  amount: Amount, currency: Currency.optional(), interval: z.enum(INTERVALS), item: Item.optional(), client_name: ClientName, client_email: ClientEmail,
  confirm_amount: Amount.optional(), confirm_currency: Currency.optional(), confirm_interval: z.enum(INTERVALS).optional(), confirm_recipient: ClientEmail,
}).strict();
const PayLinkBody = z.object({ amount: Amount, currency: Currency.optional(), item: Item, client_name: ClientName }).strict();
// confirm_client: set by the owner's confirm tap, which shows the client. It must name the invoice's client.
const RemindBody = z.object({ invoice_id: z.string().min(1).max(64), confirm_client: z.string().trim().max(100).optional() }).strict();
const RefundBody = z.union([
  z.object({ confirm_token: z.string().min(10).max(100) }).strict(),
  z.object({ id: z.string().min(1).max(64), amount: Amount.optional() }).strict(),
]);
const ProfileBody = z.object({
  business_name: CleanText(80), tone: CleanText(200), currency: Currency.default('USD'),
}).strict();
const ItemBody = z.object({ name: Item, price: Amount, currency: Currency.default('USD') }).strict();
const DisputeId = z.string().regex(/^PP-[A-Z0-9-]{3,40}$/);
const AppleAuthBody = z.object({ identity_token: z.string().min(20).max(4096), nonce: z.string().min(16).max(128) }).strict();
const DisputeMessageBody = z.object({ message: CleanText(2000) }).strict();

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
  const integrations = createIntegrations(db, cipher, now);
  const biz = createBusiness({ db, ai, paypal, integrations, dec, now });

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

  // ---- Sign in with Apple: the one /v1 route with no device token. It sits before the token check on purpose.
  // Every failure is a plain 401, so a caller learns nothing about which check failed.
  const verifyApple = deps.apple ?? createAppleVerifier({ now });
  app.post('/v1/auth/apple', rateLimiter('auth', clientIp), async (c) => {
    let sub: string;
    try {
      const b = AppleAuthBody.parse(await c.req.json());
      sub = (await verifyApple(b.identity_token, b.nonce)).sub;
    } catch (e) {
      log('apple_auth_rejected', { reason: e instanceof z.ZodError ? 'bad body' : (e as Error).message });
      return c.json({ error: 'unauthorized' }, 401);
    }
    const { userId, created } = db.userForAppleSub(cipher.lookupHash('apple-sub', sub));
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'apple');
    if (created) deps.onNewUser?.(userId);
    log('apple_auth', { user_id: userId, created });
    return c.json({ device_token: token });
  });

  // ---- auth: every other /v1 route resolves the user from the device token, never from the body
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
  app.use('/v1/ask', rateLimiter('suggest', byUser));
  app.use('/v1/actions/*', rateLimiter('actions', byUser));
  app.use('/v1/write/*', rateLimiter('write', byUser));
  app.use('/v1/disputes/:id/message', rateLimiter('actions', byUser));
  app.use('/v1/*', rateLimiter('other', byUser));

  // ---- actions are default-deny: an explicit tap header plus an idempotency key
  const tapGate: MiddlewareHandler<Env> = async (c, next) => {
    // Lookup only: the stored answer for this key and body, or 404. It never runs the action, so it needs no tap.
    if (c.req.header('idempotency-lookup') === '1') {
      const prior = db.getIdem(c.get('userId'), c.req.header('idempotency-key') ?? '');
      if (!prior || prior.route !== c.req.path || prior.body_hash !== sha256(await c.req.text())) return c.json({ error: 'not found' }, 404);
      if (prior.status !== 'done' || !prior.response) return c.json({ error: 'request with this Idempotency-Key is in progress' }, 409);
      return c.json(JSON.parse(prior.response), 200);
    }
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
  };
  app.use('/v1/actions/*', tapGate);
  app.use('/v1/disputes/:id/message', tapGate);
  const idemKey = (c: Context<Env>) => requestIdFor(c.get('userId'), c.req.header('idempotency-key')!);

  // ---- suggest
  // Regex first: it ends ordinary chat with no paid call and fills amount, currency and email.
  // jev picks the intent. The LLM extract runs only for fields the regex and the owner's own data cannot fill.
  app.post('/v1/suggest', async (c) => {
    const userId = c.get('userId');
    const { text, context } = await body(c, SuggestBody);
    const prompt = context ? `Client said: ${context}\nOwner is typing: ${text}` : text;
    const t0 = performance.now();
    const timings: Record<string, number> = {};
    let path = 'regex_none';
    let parallel = false;
    const done = (chips: Chip[], intent: string, confidence: number) => {
      timings.total_ms = Math.round(performance.now() - t0);
      log('suggest', { user_id: userId, path, paid_calls: path === 'regex_none' ? 0 : path === 'jev_only' ? 1 : 2, parallel, intent, confidence, chips: chips.length, ...timings });
      return c.json({ chips, intent, confidence, timings });
    };

    const q = quick(text, context ?? '');
    if (q.none) return done([], 'none', 1);

    const items = db.listItems(userId);
    const profile = profileOf(userId);
    const seen = `${text} ${context ?? ''}`;
    const known = regexFields(userId, q, text, seen, items);
    const extract = () => {
      path = 'jev+extract';
      return ai.extract(prompt, catalogText(items)).then(
        (ext) => { timings.extract_ms = Math.round(performance.now() - t0); return ext; },
        (e) => { timings.extract_ms = Math.round(performance.now() - t0); log('extract_failed', { err: (e as Error).message }); return null; },
      );
    };
    // A money signal the regex cannot fully fill: extraction starts alongside jev, so the total is about
    // max(jev, extract), and its result is dropped if jev finds no action. Skipped when the regex filled an intent.
    let extracting = Object.values(known).some(Boolean) ? null : extract();
    parallel = !!extracting;
    path = extracting ? 'jev+extract' : 'jev_only';
    let cls;
    try {
      cls = await ai.classify(prompt);
    } catch (e) {
      timings.classify_ms = Math.round(performance.now() - t0);
      log('classify_failed', { err: (e as Error).message });
      return done([], 'error', 0);
    }
    timings.classify_ms = cls.ms;
    if (cls.intent === 'none' || cls.confidence < config.jev.minConfidence) return done([], cls.intent, cls.confidence);

    const chips = await moneyChips(userId, cls.intent, { text, context: context ?? '', q, known, items, currency: profile.currency }, extracting, extract);
    return done(chips ?? [], cls.intent, cls.confidence);
  });

  type Filled = { text: string; context: string; q: Quick; known: ReturnType<typeof regexFields>; items: CatalogItem[]; currency: string };
  /**
   * The chips for an intent that is already picked. `extracting` is an extract call that already runs, or null;
   * `extract` starts one, and it runs only when the regex and the owner's records cannot fill the intent.
   * Null when the extract call was needed and failed.
   */
  async function moneyChips(userId: string, intent: string, f: Filled, extracting: Promise<Extraction | null> | null, extract: () => Promise<Extraction | null>): Promise<Chip[] | null> {
    const { q } = f;
    let ext: Extraction | null = null;
    // Unsure: the regex and the model read different amounts, only the model read one, or it came only from client text.
    let unsure = false;
    const fill = f.known[intent as keyof typeof f.known];
    if (fill !== undefined) {
      if (fill && !extracting) {
        ext = fill;
      } else {
        const model = await (extracting ??= extract());
        if (!model) return null;
        // The model read no amount but the text has more than amount, item and name words ("half off", "waived"):
        // the amount comes from the regex or the catalog, so the owner confirms it.
        const extraWords = !onlyKnownWords(f.text, [...f.items.map((i) => i.name), ...clientNames(userId)]);
        unsure = q.clientAmountOnly || (model.amount !== null && model.amount !== q.amount) || (model.amount === null && extraWords);
        // What the regex read beats a model guess. Email comes only from the owner's own text (see buildChips).
        ext = {
          ...model,
          client_name: model.client_name ?? fill?.client_name ?? null,
          client_email: q.email ?? model.client_email,
          amount: q.amount ?? model.amount,
          // A typed amount keeps its typed currency; a bare $ stays null, so the profile currency applies.
          currency: q.amount !== null ? q.currency : model.currency,
        };
      }
    }
    return buildChips(userId, intent, ext, f.text, f.context, f.items, f.currency, unsure);
  }

  const catalogMatch = (items: CatalogItem[], seen: string, extItem?: string | null) =>
    items.find((i) => seen.includes(i.name.toLowerCase()) || (extItem && extItem.toLowerCase().includes(i.name.toLowerCase())));

  /**
   * For each intent that needs fields: the fields when the regex and the owner's own records give all of them
   * (then no extract call), else null. An invoice needs amount, a catalog item and a typed email; a pay link
   * needs amount and item; a reminder needs one known unpaid client named; a refund needs one paid client
   * named and, if the text has digits, the amount. A regex amount counts only when every other word the owner
   * typed is a money word, a catalog item or a known client; else the model reads it too (rule B).
   */
  const clientNames = (userId: string) =>
    [...db.listInvoices(userId), ...db.listOrders(userId)].map((r) => dec(userId, r.client_name_enc)).filter((n): n is string => !!n);

  function regexFields(userId: string, q: Quick, text: string, seen: string, items: CatalogItem[]) {
    const hasItem = !!catalogMatch(items, seen.toLowerCase());
    const invoices = db.listInvoices(userId);
    const orders = db.listOrders(userId);
    const clients = clientNames(userId);
    const named = (rows: (InvoiceRow | OrderRow)[]) => {
      const names = new Set(rows.map((r) => dec(userId, r.client_name_enc)).filter((n): n is string => !!n && mentions(seen, n)));
      return names.size === 1 ? [...names][0] : null;
    };
    const amount = q.amount !== null && onlyKnownWords(text, [...items.map((i) => i.name), ...clients]);
    const base: Extraction = { client_name: named([...invoices, ...orders]), client_email: q.email, amount: q.amount, currency: q.currency, item: null };
    const unpaid = invoices.filter((r) => !r.paid_at && r.status !== 'CANCELLED');
    const paid = [...invoices, ...orders].filter((r) => r.paid_at && r.capture_id && r.status !== 'REFUNDED');
    const remindName = named(unpaid);
    const refundName = named(paid);
    return {
      create_invoice: amount && hasItem && q.email ? base : null,
      pay_link: amount && hasItem ? base : null,
      send_reminder: remindName ? { ...base, client_name: remindName } : null,
      refund: refundName && (amount || !/\d/.test(seen)) ? { ...base, client_name: refundName } : null,
    };
  }

  const chip = (kind: string, label: string, payload: Record<string, unknown>, needsConfirm = false): Chip =>
    ({ kind, label: clean(label), payload, needs_confirm: needsConfirm });
  const cleanOrNull = (v: string | null | undefined, max: number) => (v ? clean(v).slice(0, max) || null : null);


  /** True when `want` is the client's full name or first name (case-insensitive). No want matches no one. */
  const sameClient = (userId: string, r: InvoiceRow | OrderRow, want: string | undefined) => {
    if (!want) return false;
    const name = (dec(userId, r.client_name_enc) ?? '').trim().toLowerCase();
    return name === want || name.split(/\s+/)[0] === want;
  };
  /** The one row that matches, or null when none or several do: a reminder or refund never guesses. */
  const onlyOne = <T>(rows: T[]) => (rows.length === 1 ? rows[0] : null);

  /** The email of the one known client with exactly this name, named in the owner's own text. 0 or 2+ emails: null. */
  function recordEmail(userId: string, name: string | null, text: string): string | null {
    const want = name?.trim().toLowerCase();
    if (!want || !mentions(text, want)) return null;
    const emails = new Set(db.listInvoices(userId)
      .filter((r) => dec(userId, r.client_name_enc)?.trim().toLowerCase() === want)
      .map((r) => dec(userId, r.client_email_enc)?.trim().toLowerCase())
      .filter((e): e is string => !!e));
    return emails.size === 1 ? [...emails][0] : null;
  }

  function buildChips(userId: string, intent: string, rawExt: Extraction | null, text: string, context: string, items: CatalogItem[], defaultCurrency: string, unsure = false): Chip[] {
    const ext = rawExt && { ...rawExt, item: cleanOrNull(rawExt.item, 120), client_name: cleanOrNull(rawExt.client_name, 100) };
    // Copied client text may only help match the catalog.
    const lower = text.toLowerCase();
    const seen = `${lower} ${context.toLowerCase()}`;
    const match = catalogMatch(items, seen, ext?.item);
    // A typed currency wins; a typed amount with a bare $ is in the profile currency; only a catalog price keeps the item's.
    const typedCurrency = (config.money.currencies as readonly string[]).includes(ext?.currency ?? '') ? ext!.currency! : null;
    const currency = typedCurrency ?? (ext?.amount != null ? defaultCurrency : match?.currency ?? defaultCurrency);
    // Copied or typed text names a client: true when that text holds the client's full or first name.
    const namedIn = (t: string, client: string) => !!client && (mentions(t, client) || mentions(t, client.split(/\s+/)[0]));

    if (intent === 'create_invoice' || intent === 'pay_link') {
      const cents = ext?.amount != null ? amountToCents(ext.amount) : match?.price_cents ?? null;
      if (cents === null) return [];
      const item = ext?.item ? ext.item.charAt(0).toUpperCase() + ext.item.slice(1) : match?.name ?? 'Payment';
      const money = formatMoney(cents, currency);
      const base = { amount: centsToValue(cents), currency, item, client_name: ext?.client_name ?? null };
      // An email the owner typed, else the one email the owner's records hold for the client named in the owner's
      // text. Never an email the model read from copied client text or made up.
      // Two or more typed emails: the owner picks on the confirm, never the model.
      const emails = typedEmails(text);
      const typed = ext?.client_email && emails.length === 1 && emails[0] === ext.client_email.toLowerCase() ? ext.client_email : null;
      const email = emails.length > 1 ? null : typed ?? recordEmail(userId, ext?.client_name ?? null, text);
      const recipient = email ?? ext?.client_name ?? null;
      // Every invoice gets one confirm tap that shows the amount and the recipient; the server checks both.
      const invoice = chip('invoice', `Invoice ${money} · ${item}${recipient ? ` → ${recipient}` : ''}`, { ...base, client_email: email }, true);
      const currencyClash = !!match && ext?.amount != null && match.currency !== currency;
      const link = chip('paylink', `Pay link ${money} · ${item}`, base, unsure || currencyClash);
      return intent === 'create_invoice' ? [invoice, link] : [link, invoice];
    }
    if (intent === 'payment_status') {
      const unpaid = db.unpaidCount(userId);
      return [chip('payments', `Who paid? · ${unpaid} unpaid`, {})];
    }
    if (intent === 'send_reminder') {
      const want = ext?.client_name?.trim().toLowerCase();
      const unpaid = db.listInvoices(userId).filter((r) => !r.paid_at && r.status !== 'CANCELLED');
      const hit = onlyOne(unpaid.filter((r) => sameClient(userId, r, want)));
      // The client must be named in the text, never only guessed by the model ("remind her").
      const client = hit ? dec(userId, hit.client_name_enc) ?? '' : '';
      if (!hit || !(namedIn(text, client) || namedIn(context, client))) return [];
      const name = biz.namer(userId)(hit) ?? client;
      // Every reminder takes one confirm tap; the server checks the client it names (confirm_client).
      return [chip('remind', `Remind ${name} · ${formatMoney(hit.amount_cents, hit.currency)}`,
        { invoice_id: hit.id, client_name: name, amount: centsToValue(hit.amount_cents), currency: hit.currency }, true)];
    }
    if (intent === 'refund') {
      const want = ext?.client_name?.trim().toLowerCase();
      const cents = ext?.amount != null ? amountToCents(ext.amount) : null;
      const left = (r: InvoiceRow | OrderRow) => r.amount_cents - db.refundState(userId, r.id).doneCents;
      const paid = [...db.listInvoices(userId), ...db.listOrders(userId)].filter((r) => r.paid_at && r.capture_id && r.status !== 'REFUNDED' && left(r) > 0);
      const hit = onlyOne(paid.filter((r) => sameClient(userId, r, want) && (cents === null || cents <= left(r))));
      const client = hit ? dec(userId, hit.client_name_enc) ?? '' : '';
      if (!hit || !(namedIn(text, client) || namedIn(context, client))) return [];
      const refundCents = cents ?? left(hit);
      const who = biz.namer(userId)(hit) ?? hit.item;
      return [chip('refund', `Refund ${formatMoney(refundCents, hit.currency)} · ${who}`, { id: hit.id, amount: centsToValue(refundCents) })];
    }
    if (intent === 'catalog_reply') {
      return items.length ? [chip('reply', 'Reply with prices', {})] : [];
    }
    return [];
  }

  const EVERY: Record<Interval, string> = { week: 'weekly', month: 'monthly', year: 'yearly' };
  /**
   * The repeat bill chip. The interval comes only from the regex. The amount is the regex amount when every other
   * word is known, else the model reads it too. The client is named in the owner's text or left out; the email is
   * one the owner typed or the one on record for that client. Always needs a confirm.
   */
  async function subscribeChips(userId: string, text: string, extract: () => Promise<Extraction | null>): Promise<Chip[]> {
    const interval = intervalOf(text);
    if (!interval) return [];
    const plain = withoutInterval(text);
    const q = quick(plain);
    const items = db.listItems(userId);
    const clients = clientNames(userId);
    const known = new Set(clients.filter((n) => mentions(text, n)));
    let ext: Extraction | null = q.amount !== null && onlyKnownWords(plain, [...items.map((i) => i.name), ...clients])
      ? { client_name: known.size === 1 ? [...known][0] : null, client_email: q.email, amount: q.amount, currency: q.currency, item: null }
      : null;
    if (!ext) {
      const model = await extract();
      if (!model) return [];
      ext = { ...model, client_email: q.email ?? model.client_email, amount: q.amount ?? model.amount, currency: q.amount !== null ? q.currency : model.currency };
    }
    const match = catalogMatch(items, text.toLowerCase(), ext.item);
    const cents = ext.amount != null ? amountToCents(ext.amount) : match?.price_cents ?? null;
    if (cents === null) return [];
    const defaultCurrency = profileOf(userId).currency;
    const typedCurrency = (config.money.currencies as readonly string[]).includes(ext.currency ?? '') ? ext.currency! : null;
    const currency = typedCurrency ?? (ext.amount != null ? defaultCurrency : match?.currency ?? defaultCurrency);
    const rawName = cleanOrNull(ext.client_name, 100);
    const name = rawName && (mentions(text, rawName) || mentions(text, rawName.split(/\s+/)[0])) ? rawName : null;
    const emails = typedEmails(text);
    const typed = ext.client_email && emails.length === 1 && emails[0] === ext.client_email.toLowerCase() ? emails[0] : null;
    const email = emails.length > 1 ? null : typed ?? recordEmail(userId, name, text);
    const itemName = cleanOrNull(ext.item, 120);
    const item = itemName ? itemName.charAt(0).toUpperCase() + itemName.slice(1) : match?.name ?? 'Repeat payment';
    const who = name ?? email;
    return [chip('subscribe', `Repeat ${formatMoney(cents, currency)} ${EVERY[interval]}${who ? ` · ${who}` : ''}`,
      { amount: centsToValue(cents), currency, interval, item, client_name: name, client_email: email }, true)];
  }

  // ---- money actions
  app.post('/v1/actions/invoice', async (c) => {
    const userId = c.get('userId');
    const b = await body(c, InvoiceBody);
    const profile = db.getProfile(userId);
    const currency = b.currency ?? profile?.currency ?? 'USD';
    if (b.client_email && (b.confirm_recipient !== b.client_email || b.confirm_amount !== b.amount || b.confirm_currency !== b.currency)) {
      c.set('idemSkip', true);
      return c.json({ error: 'confirm the amount and recipient', needs_confirm: true, recipient: b.client_email, amount: centsToValue(b.amount), currency }, 409);
    }
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

  app.post('/v1/actions/subscribe', async (c) => {
    const userId = c.get('userId');
    const b = await body(c, SubscribeBody);
    const profile = db.getProfile(userId);
    const currency = b.currency ?? profile?.currency ?? 'USD';
    if (b.confirm_amount !== b.amount || b.confirm_currency !== currency || b.confirm_interval !== b.interval
      || (b.client_email && b.confirm_recipient !== b.client_email)) {
      c.set('idemSkip', true);
      return c.json({
        error: 'confirm the amount, currency, interval and recipient', needs_confirm: true,
        recipient: b.client_email ?? b.client_name ?? null, amount: centsToValue(b.amount), currency, interval: b.interval,
      }, 409);
    }
    const item = b.item ?? 'Repeat payment';
    const planKey = `${currency}:${b.amount}:${b.interval}`;
    const cached = db.getBillingPlan(userId, planKey);
    const t = performance.now();
    const sub = await paypal.forUser(userId).createSubscription({
      value: centsToValue(b.amount), currency, interval: b.interval, clientEmail: b.client_email ?? null,
      productId: cached?.product_id ?? db.anyBillingProduct(userId), planId: cached?.plan_id ?? null,
      productRequestId: requestIdFor(userId, 'billing-product'), planRequestId: requestIdFor(userId, `billing-plan:${planKey}`),
    }, idemKey(c));
    db.putBillingPlan(userId, planKey, sub.productId, sub.planId);
    db.insertSubscription({
      id: sub.id, user_id: userId, status: sub.status, amount_cents: b.amount, currency, interval: b.interval, item,
      client_name_enc: enc(userId, b.client_name), client_email_enc: enc(userId, b.client_email), approve_link: sub.approveLink,
      plan_id: sub.planId, created_at: now(),
    });
    const ms = Math.round(performance.now() - t);
    log('subscription_created', { user_id: userId, subscription_id: sub.id, status: sub.status, paypal_ms: ms });
    return c.json({ id: sub.id, status: sub.status, approve_link: sub.approveLink, amount: centsToValue(b.amount), currency, interval: b.interval, item, paypal_ms: ms });
  });

  app.post('/v1/actions/remind', async (c) => {
    const userId = c.get('userId');
    const { invoice_id, confirm_client } = await body(c, RemindBody);
    const inv = db.getInvoice(userId, invoice_id);
    if (!inv) throw new HttpError(404, 'invoice not found');
    if (inv.paid_at) throw new HttpError(409, 'invoice is already paid');
    // The confirm tap showed the client's display name; it must match that name or the invoice's own.
    const shown = biz.namer(userId)(inv);
    const names = [shown, dec(userId, inv.client_name_enc)].filter((n): n is string => !!n).map((n) => n.trim().toLowerCase());
    if (!confirm_client || !names.includes(confirm_client.toLowerCase())) {
      c.set('idemSkip', true);
      return c.json({ error: 'confirm the client', needs_confirm: true, recipient: shown ?? 'the client', amount: centsToValue(inv.amount_cents), currency: inv.currency }, 409);
    }
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
    const who = biz.namer(userId)(target) ?? 'the client';
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
    return c.json({ payments: paymentsOf(userId) });
  });

  function paymentsOf(userId: string) {
    const t = now();
    const nameOf = biz.namer(userId);
    const invoices = db.listInvoices(userId).map((r) => {
      const state = invoiceState(r.status);
      return {
        kind: 'invoice', id: r.id, state, paypal_status: r.status, amount: centsToValue(r.amount_cents), currency: r.currency, item: r.item,
        client_name: nameOf(r), link: r.pay_link, created_at: new Date(r.created_at).toISOString(),
        days_overdue: state === 'unpaid' && t > r.due_at ? Math.floor((t - r.due_at) / DAY) : 0,
        origin: 'paypal_invoice', paid_via: !r.paid_at ? null : r.status === 'MARKED_AS_PAID' ? 'recorded_payment' : 'paypal', seeded: r.source === 'demo_seed',
      };
    });
    const orders = db.listOrders(userId).map((r) => ({
      kind: 'order', id: r.id, state: orderState(r.status), paypal_status: r.status, amount: centsToValue(r.amount_cents), currency: r.currency,
      item: r.item, client_name: nameOf(r), link: r.approve_link, created_at: new Date(r.created_at).toISOString(), days_overdue: 0,
      origin: 'paypal_order', paid_via: r.paid_at ? 'paypal' : null, seeded: false,
    }));
    const payments = [...invoices, ...orders].sort((a, b) => b.created_at.localeCompare(a.created_at));
    return payments;
  }

  app.get('/v1/summary', async (c) => c.json(await biz.summary(c.get('userId'))));

  // ---- integrations and the business view, all through the user's own PayPal connection
  app.get('/v1/integrations', (c) => c.json({ integrations: integrations.list(c.get('userId')) }));

  app.get('/v1/transactions', async (c) => {
    const range = z.enum(RANGES).default('week').parse(c.req.query('range') ?? undefined);
    const set = await biz.transactions(c.get('userId'), range);
    return c.json({ range, source: set.source, note: set.note, transactions: set.txns });
  });

  app.get('/v1/disputes', async (c) => {
    const list = await biz.disputes(c.get('userId'));
    return c.json({ disputes: list });
  });
  app.get('/v1/disputes/:id', async (c) => {
    const id = DisputeId.safeParse(c.req.param('id'));
    const d = id.success ? await biz.dispute(c.get('userId'), id.data) : null;
    if (!d) throw new HttpError(404, 'dispute not found');
    return c.json({ dispute: d });
  });
  app.post('/v1/disputes/:id/message', async (c) => {
    const userId = c.get('userId');
    const id = DisputeId.safeParse(c.req.param('id'));
    const { message } = await body(c, DisputeMessageBody);
    if (!id.success || !(await biz.sendDisputeMessage(userId, id.data, message, idemKey(c)))) throw new HttpError(404, 'dispute not found');
    log('dispute_message_sent', { user_id: userId, dispute_id: id.data });
    return c.json({ ok: true, dispute_id: id.data });
  });

  app.get('/v1/brief', async (c) => c.json(await biz.brief(c.get('userId'))));
  app.get('/v1/clients', async (c) => c.json(await biz.clients(c.get('userId'))));

  app.post('/v1/reply', async (c) => {
    const userId = c.get('userId');
    const { text } = await body(c, TextBody);
    const t = performance.now();
    const reply = await ai.reply(text, profileOf(userId), catalogText(db.listItems(userId)));
    const ms = Math.round(performance.now() - t);
    log('reply', { user_id: userId, ms });
    return c.json({ reply, ms });
  });

  // ---- writing help: runs only from a tap in the keyboard. Only sizes and timings are logged, never the text.
  app.use('/v1/write/*', async (c, next) => {
    if (c.req.header('x-user-action') !== 'tap') return c.json({ error: 'writing help runs only from an explicit user tap' }, 428);
    await next();
  });
  const writing = async <T extends object>(c: Context<Env>, kind: string, chars: number, run: () => Promise<T>, paid: (out: T) => number = () => 1) => {
    const t = performance.now();
    try {
      const out = await run();
      const ms = Math.round(performance.now() - t);
      log('write', { user_id: c.get('userId'), kind, chars, ms, ok: true, paid_calls: paid(out) });
      return c.json({ ...out, ms });
    } catch (e) {
      // A model error can quote the text, so only its type is logged.
      log('write', { user_id: c.get('userId'), kind, chars, ms: Math.round(performance.now() - t), ok: false, err: (e as Error).name });
      return c.json({ error: 'writing help is not available right now' }, 502);
    }
  };
  app.post('/v1/write/fix', async (c) => {
    const { text } = await body(c, FixBody);
    return writing(c, 'fix', text.length, async () => {
      const fixed = await ai.fix(text);
      return { text: fixed, changed: fixed !== text };
    });
  });
  app.post('/v1/write/refine', async (c) => {
    const { text, tone } = await body(c, RefineBody);
    return writing(c, `refine_${tone}`, text.length, async () => ({ text: await ai.refine(text, tone) }));
  });
  app.post('/v1/write/tone', async (c) => {
    const b = await body(c, ToneBody);
    const draft = b.text ?? '', client = b.context ?? '';
    // jev judges the tone; the LLM writes a calm reply only when the tone is not ok.
    return writing(c, 'tone', draft.length + client.length, () => ai.toneCheck(draft, client), (out) => (out.tone === 'ok' ? 1 : 2));
  });

  // ---- ask: one free-form request, routed to one Muninn function. Regex first, then two small jev choices.
  // The router never moves money: a money route returns the same chips as /v1/suggest, and each chip
  // still needs its own tap on /v1/actions/*. Device routes return an instruction; the phone does the work.
  const ROUTE_INTENT: Partial<Record<AskRoute, Intent>> = { invoice: 'create_invoice', paylink: 'pay_link', remind: 'send_reminder', refund: 'refund' };
  const NOT_SURE = 'Not sure what you need. Try "invoice Sam $45 for a haircut" or "who has not paid".';
  const refineTone = (words: string): Tone =>
    /\b(?:short|brief|concise)/i.test(words) ? 'shorter' : /\b(?:firm|strict|stern)/i.test(words) ? 'firmer'
      : /\b(?:professional|formal|polite)/i.test(words) ? 'professional' : 'friendly';
  app.post('/v1/ask', async (c) => {
    // A writing route calls the model on the owner's text, so ask keeps the rule of /v1/write/*.
    if (c.req.header('x-user-action') !== 'tap') return c.json({ error: 'ask runs only from an explicit user tap' }, 428);
    const userId = c.get('userId');
    const { text } = await body(c, AskBody);
    const t0 = performance.now();
    let paid = 0;
    // Only the route, sizes and timings are logged, never the text.
    const done = (route: AskRoute, confidence: number, result: Record<string, unknown>, err?: string) => {
      log('ask', { user_id: userId, route, confidence, paid_calls: paid, chars: text.length, ms: Math.round(performance.now() - t0), ...(err ? { err } : {}) });
      return c.json({ route, confidence, result });
    };
    const none = (confidence: number, line = NOT_SURE, err?: string) => done('none', confidence, { line }, err);

    const aq = askQuick(text);
    if (aq.none) return none(1, 'Ask for an invoice, a reminder, a rewrite, who paid, or a note.');
    let group: AskGroup | null = aq.group;
    let confidence = 1;
    let route: AskRoute;
    try {
      if (!group) {
        paid++;
        ({ group, confidence } = await ai.askGroup(text));
      }
      if (group === 'none' || confidence < config.jev.minConfidence) return none(confidence);
      paid++;
      const picked = await ai.askRoute(text, group);
      confidence = Math.min(confidence, picked.confidence);
      if (picked.route === 'none' || confidence < config.jev.minConfidence) return none(confidence);
      route = picked.route;
    } catch (e) {
      return none(0, 'Could not read that right now. Try again.', (e as Error).message);
    }

    const items = db.listItems(userId);
    const extract = () => {
      paid++;
      return ai.extract(text, catalogText(items)).catch((e) => { log('extract_failed', { err: (e as Error).message }); return null; });
    };
    if (route === 'subscribe') {
      if (!intervalOf(text)) return none(confidence, 'Say how often, like "bill Sam $40 monthly".');
      return done(route, confidence, { chips: await subscribeChips(userId, text, extract) });
    }

    const intent = ROUTE_INTENT[route];
    if (intent) {
      const q = quick(text);
      const filled = { text, context: '', q, known: regexFields(userId, q, text, text, items), items, currency: profileOf(userId).currency };
      return done(route, confidence, { chips: (await moneyChips(userId, intent, filled, null, extract)) ?? [] });
    }

    if (group === 'writing') {
      // The text to work on comes after the first colon: "make this nicer: ya ok will send".
      const colon = text.indexOf(':');
      const draft = WriteText.safeParse(colon < 0 ? '' : text.slice(colon + 1));
      if (!draft.success) return none(confidence, 'Put the text after a colon, like "fix: thnks for comming".');
      const d = draft.data;
      try {
        paid++;
        if (route === 'fix') {
          const fixed = await ai.fix(d);
          return done(route, confidence, { text: fixed, changed: fixed !== d });
        }
        if (route === 'refine') {
          const tone = refineTone(text.slice(0, colon));
          return done(route, confidence, { text: await ai.refine(d, tone), tone });
        }
        if (route === 'tone') {
          const out = await ai.toneCheck(d, '');
          if (out.tone !== 'ok') paid++;
          return done(route, confidence, out);
        }
        return done(route, confidence, { reply: await ai.reply(d, profileOf(userId), catalogText(db.listItems(userId))) });
      } catch (e) {
        // A model error can quote the text, so only its type is logged.
        return none(confidence, 'Writing help is not available right now. Try again.', (e as Error).name);
      }
    }

    if (route === 'who_paid') return done(route, confidence, { payments: paymentsOf(userId) });
    if (route === 'brief') return done(route, confidence, await biz.brief(userId, () => paid++));
    if (route === 'clients') return done(route, confidence, await biz.clients(userId));
    if (route === 'disputes') return done(route, confidence, { disputes: await biz.disputes(userId) });
    if (route === 'add_note') {
      const note = clean(noteText(text));
      return note ? done(route, confidence, { action: 'add_note', text: note }) : none(confidence, 'Say what to note, like "add a note: buy shampoo".');
    }
    return done(route, confidence, { action: 'show_calendar' });
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
