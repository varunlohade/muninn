import { Hono, type Context, type MiddlewareHandler } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { cors } from 'hono/cors';
import { secureHeaders } from 'hono/secure-headers';
import { randomBytes, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { config, INTERVALS, TONES, type AskGroup, type Interval, type AskRoute, type Intent, type Tone } from './config.ts';
import { randomToken, sha256, type Cipher } from './crypto.ts';
import type { CatalogItem, Db, InvoiceRow, OrderRow, Preview, SharedImage } from './db.ts';
import { isPng, jpegSize, pngSize } from './image.ts';
import type { Ai, DeviceAction, Extraction } from './ai.ts';
import { PayPalError, type PayPalProvider } from './paypal.ts';
import { Amount, Currency, amountToCents, centsToValue, formatMoney } from './money.ts';
import { log } from './log.ts';
import { clean } from './text.ts';
import {
  afterRemindName, askQuick, commandIntent, deviceSignal, deviceTitle, deviceTrigger, intervalOf, lastSentence, mentions, moneyTrigger, nameIn, noteText, onlyKnownWords, quick, repeatEnds,
  moneyRequest, saidAll, typedEmails, withoutInterval, detectLookup, type Quick,
} from './quick.ts';
import { ASK_AT, SHOW_AT, chipLabel, createSearch, importance, invoiceState, mentionsItemWord, orderState } from './search.ts';
import { getConnInfo } from '@hono/node-server/conninfo';
import { createIntegrations } from './integrations.ts';
import { createSlack, SlackWebhookUrl } from './slack.ts';
import { RANGES, createBusiness } from './business.ts';
import { createAppleVerifier, type AppleVerifier } from './apple.ts';
import { DEFAULT_BUSINESS_NAME, createPayPalConnect } from './connect.ts';
import { createMore } from './actions-more.ts';
import { buildChart, monthStart, zoneOr } from './chart.ts';
import { createLearner } from './learn.ts';
import { PasswordBusyError, dummyHash, hashPassword, needsRehash, passwordProblem, verifyPassword } from './password.ts';

export type Deps = {
  db: Db; cipher: Cipher; ai: Ai; paypal: PayPalProvider; now?: () => number;
  apple?: AppleVerifier;
  /** Runs once for each user that Sign in with Apple creates. The demo server seeds the demo business here. */
  onNewUser?: (userId: string) => void;
};
export type Env = { Variables: { userId: string; tokenHash: string; idemSkip?: boolean } };
export type Chip = { kind: string; label: string; payload: Record<string, unknown>; needs_confirm: boolean; trigger?: string };

const DAY = 86_400_000;
const DEFAULT_PROFILE = { business_name: DEFAULT_BUSINESS_NAME, tone: 'friendly and short', currency: 'USD' };

class HttpError extends Error {
  status: 400 | 401 | 404 | 409 | 413 | 428 | 429;
  constructor(status: HttpError['status'], message: string) {
    super(message);
    this.status = status;
  }
}

// Fixed windows per key. The map keeps keys in the order their windows started, so the first key is always the oldest:
// a full map drops expired keys from the front, then the oldest live key. It never clears everyone's counts.
export function createLimiter({ limit, windowMs, maxKeys = 10_000 }: { limit: number; windowMs: number; maxKeys?: number }) {
  const hits = new Map<string, { n: number; reset: number }>();
  const entry = (key: string) => {
    const now = Date.now();
    let h = hits.get(key);
    if (!h || h.reset <= now) {
      hits.delete(key);
      for (const [k, v] of hits) {
        if (hits.size < maxKeys && v.reset > now) break;
        hits.delete(k);
      }
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

/** The limit key for an address: IPv4 as is, IPv6 by its /64 (one home or phone usually owns a whole /64). */
export function ipKey(ip: string): string {
  const v = ip.trim().replace(/%.*$/, '').toLowerCase();
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v);
  if (mapped) return mapped[1];
  if (!v.includes(':')) return v;
  const [head, tail] = v.split('::');
  const h = head ? head.split(':') : [];
  const t = tail ? tail.split(':') : [];
  const groups = tail === undefined ? h : [...h, ...Array(Math.max(0, 8 - h.length - t.length)).fill('0'), ...t];
  return `${groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, '')).join(':')}::/64`;
}

function clientIp(c: Context<Env>): string {
  if (config.trustProxy && config.clientIpHeader) {
    const ip = c.req.header(config.clientIpHeader)?.trim();
    if (ip) return ipKey(ip);
  }
  if (config.trustProxy) {
    const hops = (c.req.header('x-forwarded-for') ?? '').split(',').map((h) => h.trim()).filter(Boolean);
    if (hops.length) return ipKey(hops[hops.length - 1]);
  }
  try {
    return ipKey(getConnInfo(c).remote.address ?? 'direct');
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
// Explain: a short question or topic the phone's regex already called an explain request. Never stored or logged.
const ExplainText = CleanText(config.maxExplainChars);
const ExplainBody = z.object({ text: ExplainText }).strict();
const VisualBody = z.object({ topic: ExplainText }).strict();
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
// A Google review link in one of four exact forms, so no redirect or other Google page gets in. Left out keeps the stored one; null clears it.
const REVIEW_LINK = [
  /^https:\/\/g\.page\/r\/[A-Za-z0-9_-]+\/review$/,
  /^https:\/\/g\.page\/[A-Za-z0-9_-]+\/review$/,
  /^https:\/\/maps\.app\.goo\.gl\/[A-Za-z0-9_-]+$/,
  /^https:\/\/search\.google\.com\/local\/writereview\?placeid=[A-Za-z0-9_-]+$/,
];
const ReviewUrl = z.string().trim().max(500).refine((v) => REVIEW_LINK.some((r) => r.test(v)), {
  message: 'must be a Google review link: g.page/r/<id>/review, g.page/<name>/review, maps.app.goo.gl/<id> or search.google.com/local/writereview?placeid=<id>',
});
const ProfileBody = z.object({
  business_name: CleanText(80), tone: CleanText(200), currency: Currency.default('USD'), review_url: ReviewUrl.nullable().optional(),
}).strict();
const BusinessBody = z.object({ description: CleanText(300) }).strict();
const DisputeId = z.string().regex(/^PP-[A-Z0-9-]{3,40}$/);
const AppleAuthBody = z.object({ identity_token: z.string().min(20).max(4096), nonce: z.string().min(16).max(128) }).strict();
const DeviceAuthBody = z.object({ device_id: z.string().uuid() }).strict();
// The email is trimmed and lowercased before it is hashed or stored. The password rules run only where a password is set.
const EmailAuthBody = z.object({ email: z.string().trim().toLowerCase().pipe(z.email().max(254)), password: z.string().min(1).max(1024) }).strict();
const SlackBody = z.object({ webhook_url: SlackWebhookUrl.nullable() }).strict();
const DisputeMessageBody = z.object({ message: CleanText(2000) }).strict();
// Full months of history and estimated months ahead, as the chart chip's payload asks.
// tz: the owner's IANA time zone for calendar months; a missing or unknown zone means UTC.
const ChartQuery = z.object({
  back: z.coerce.number().int().min(2).max(12).default(6), ahead: z.coerce.number().int().min(1).max(6).default(3),
  tz: z.string().max(64).optional(),
});

const esc = (s: string) => s.replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);

const PAGE_STYLE = 'body{margin:0;background:#f4f8fc;font:16px -apple-system,system-ui,sans-serif;color:#1c2b3a}' +
  'main{max-width:960px;margin:0 auto;padding:16px}img{display:block;width:100%;height:auto;border-radius:16px;background:#fff}' +
  'h1{font-size:18px;font-weight:600;margin:4px 0 12px}p{color:#5b6b7b;margin:12px 0 0;font-size:14px}';

/** The share page: Open Graph and Twitter tags so iMessage, WhatsApp, Telegram and Slack show the picture, and the drawing full width. */
function sharePage(base: string, id: string, img: SharedImage): string {
  const title = img.title ?? 'A drawing from Muninn';
  const page = `${base}/d/${id}`;
  const full = pngSize(img.png);
  const og = img.preview
    ? { url: `${page}.jpg`, type: 'image/jpeg', width: img.preview.width, height: img.preview.height }
    : { url: `${page}.png`, type: 'image/png', width: full?.width, height: full?.height };
  const meta = (attr: 'property' | 'name', key: string, value: string | number | undefined) =>
    value === undefined ? '' : `<meta ${attr}="${key}" content="${esc(String(value))}">`;
  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    `<title>${esc(title)}</title>` +
    meta('property', 'og:type', 'website') + meta('property', 'og:site_name', 'Muninn') +
    meta('property', 'og:title', title) + meta('property', 'og:description', 'Made with Muninn') +
    meta('property', 'og:url', page) + meta('property', 'og:image', og.url) + meta('property', 'og:image:type', og.type) +
    meta('property', 'og:image:width', og.width) + meta('property', 'og:image:height', og.height) +
    meta('property', 'og:image:alt', title) +
    meta('name', 'twitter:card', 'summary_large_image') + meta('name', 'twitter:title', title) +
    meta('name', 'twitter:description', 'Made with Muninn') + meta('name', 'twitter:image', og.url) +
    `<meta name="robots" content="noindex"><style>${PAGE_STYLE}</style></head><body><main>` +
    `<h1>${esc(title)}</h1><img src="${esc(page)}.png" alt="${esc(title)}"${full ? ` width="${full.width}" height="${full.height}"` : ''}>` +
    '<p>Made with Muninn</p></main></body></html>';
}

const gonePage = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
  `<title>This drawing has expired</title><meta name="robots" content="noindex"><style>${PAGE_STYLE}</style></head>` +
  '<body><main><h1>This drawing has expired</h1><p>Muninn keeps shared drawings for 30 days.</p></main></body></html>';

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
  /** What the business does, in the owner's words, or '' when the owner has not said. */
  const businessOf = (userId: string) => dec(userId, db.getDescriptionEnc(userId)) ?? '';
  const replyProfile = (userId: string) => ({ ...profileOf(userId), description: businessOf(userId) });
  const requestIdFor = (userId: string, key: string) => sha256(`${userId}:${key}`).slice(0, 36);
  // A connect or disconnect changes whose PayPal sales the chart reads.
  // After a connect, Muninn learns the owner's clients and usual items from their own PayPal, in the background.
  const learner = createLearner({ db, cipher, ai, paypal, now, defaultProfile: DEFAULT_PROFILE });
  /** The business for the model's context: the owner's words, then the items and prices learned from PayPal. Never client names. */
  const promptBusinessOf = (userId: string) => [businessOf(userId), learner.context(userId)].filter(Boolean).join(' ');
  const connect = createPayPalConnect({
    db, cipher, paypal, now, onChange: (userId) => biz.forgetHistory(userId),
    onConnected: (userId, account, seller) => { void learner.run(userId, account, seller); },
    learned: (userId) => learner.summary(userId)?.line ?? null,
    onDisconnected: (userId) => learner.forget(userId),
  });
  const integrations = createIntegrations(db, cipher, now, connect.label);
  const slack = createSlack(db, cipher, now);
  const biz = createBusiness({ db, ai, paypal, integrations, dec, now, isConnected: (userId) => !connect.isDemo(userId) });
  const search = createSearch({ db, dec, namer: biz.namer });
  const more = createMore({ db, paypal, biz, now, dec, enc, body, requestIdFor, accountOf: connect.account,
    fail: (status, message) => new HttpError(status, message) });

  // A shared drawing's images may be loaded from any origin (chat apps show the preview); everything else stays same-origin.
  const secure = secureHeaders(), secureShared = secureHeaders({ crossOriginResourcePolicy: 'cross-origin' });
  app.use('*', (c, next) => (/^\/d\/[^/]+\.(png|jpg)$/.test(c.req.path) ? secureShared(c, next) : secure(c, next)));
  app.use('*', cors({ origin: (origin) => (config.corsOrigins.includes(origin) ? origin : null), allowMethods: ['GET', 'POST', 'PUT', 'DELETE'] }));
  // A drawing PNG is the /v1 body that may be bigger than the JSON limit.
  const tooLarge = (c: Context<Env>) => c.json({ error: 'body too large' }, 413);
  const jsonLimit = bodyLimit({ maxSize: config.bodyLimitBytes, onError: tooLarge });
  // A drawing is the PNG plus its JPEG preview and a short title.
  const drawingLimit = bodyLimit({ maxSize: config.sharedImage.maxBytes + config.sharedImage.preview.maxBytes + 16 * 1024, onError: (c) => c.json({ error: 'image too large' }, 413) });
  app.use('/v1/*', (c, next) => (c.req.path === '/v1/drawings' ? drawingLimit(c, next) : jsonLimit(c, next)));
  app.use('/webhooks/*', bodyLimit({ maxSize: 64 * 1024, onError: (c) => c.json({ error: 'body too large' }, 413) }));

  app.onError((err, c) => {
    if (err instanceof z.ZodError) return c.json({ error: 'invalid request', issues: err.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`) }, 400);
    if (err instanceof HttpError) return c.json({ error: err.message }, err.status);
    if (err instanceof PasswordBusyError) {
      log('password_busy', { path: c.req.path });
      c.header('Retry-After', '5');
      return c.json({ error: 'busy, try again in a few seconds' }, 503);
    }
    if (err instanceof PayPalError) {
      log('paypal_error', { path: c.req.path, err: err.message });
      return c.json({ error: 'PayPal request failed', detail: err.message }, 502);
    }
    log('error', { path: c.req.path, err: (err as Error).message });
    return c.json({ error: 'internal error' }, 500);
  });

  app.get('/health', (c) => c.json({ ok: true }));

  // ---- a shared drawing. No token: whoever has the link sees the drawing and nothing else.
  // /d/<id> is a small page whose Open Graph tags make chats show the picture; /d/<id>.png is the drawing, /d/<id>.jpg the preview.
  // An unknown id is a plain 404; an expired one is 410 with no image.
  app.get('/d/:file', rateLimiter('shareView', clientIp), (c) => {
    const m = /^([A-Za-z0-9_-]{22})(\.png|\.jpg)?$/.exec(c.req.param('file'));
    const at = now();
    const img = m ? db.sharedImage(m[1], at) : undefined;
    c.header('X-Robots-Tag', 'noindex, nofollow');
    if (!m || !img || (m[2] === '.jpg' && img !== 'gone' && !img.preview)) return c.text('not found', 404);
    if (img === 'gone') {
      c.header('Cache-Control', 'public, max-age=86400');
      c.header('Content-Security-Policy', "default-src 'none'");
      return m[2] ? c.text('this drawing has expired', 410) : c.html(gonePage, 410);
    }
    // Never cached past the link's own end, so an expired link is not served from a cache.
    const left = Math.max(0, Math.floor((img.expiresAt - at) / 1000));
    if (!m[2]) {
      c.header('Cache-Control', `public, max-age=${Math.min(3600, left)}`);
      c.header('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");
      return c.html(sharePage(config.publicUrl || new URL(c.req.url).origin, m[1], img));
    }
    const [bytes, type] = m[2] === '.png' ? [img.png, 'image/png'] : [img.preview!.jpeg, 'image/jpeg'];
    return c.body(new Uint8Array(bytes), 200, {
      'Content-Type': type,
      'Cache-Control': `public, max-age=${Math.min(86400, left)}`,
      'Content-Security-Policy': "default-src 'none'",
      'X-Content-Type-Options': 'nosniff',
    });
  });

  // ---- new accounts: a cap per hour across the server, and a smaller budget for the demo seed.
  // Past the seed budget a new user simply starts empty.
  const newAccounts = createLimiter(config.rateLimit.newAccounts);
  const seedBudget = createLimiter(config.rateLimit.demoSeed);
  const TOO_MANY_ACCOUNTS = { error: 'too many new accounts right now, try again later' };
  const welcome = (userId: string) => {
    if (!deps.onNewUser) return;
    if (seedBudget.hit('all')) return log('demo_seed_skipped', { user_id: userId, reason: 'budget' });
    deps.onNewUser(userId);
  };

  // ---- Sign in with Apple: the one /v1 route with no device token. It sits before the token check on purpose.
  // Every failure is a plain 401, so a caller learns nothing about which check failed.
  const verifyApple = deps.apple ?? createAppleVerifier({ now });
  // A single-use nonce. The app sends SHA-256(nonce) to Apple and the raw nonce back to us within 10 minutes.
  app.get('/v1/auth/apple/nonce', rateLimiter('auth', clientIp), (c) => {
    const nonce = randomBytes(32).toString('base64url');
    db.addAppleNonce(sha256(nonce), now() + config.apple.nonceTtlMs, now());
    return c.json({ nonce, expires_in_s: config.apple.nonceTtlMs / 1000 });
  });
  // Checks the token, then uses up the nonce. A nonce we never gave out passes only when config.apple.requireServerNonce is off.
  const appleSub = async (raw: unknown) => {
    const b = AppleAuthBody.parse(raw);
    const { sub } = await verifyApple(b.identity_token, b.nonce);
    const nonce = db.useAppleNonce(sha256(b.nonce), now());
    if (nonce === 'spent' || (nonce === 'unknown' && config.apple.requireServerNonce)) throw new Error(`nonce ${nonce}`);
    return sub;
  };
  app.post('/v1/auth/apple', rateLimiter('auth', clientIp), async (c) => {
    let sub: string;
    try {
      sub = await appleSub(await c.req.json());
    } catch (e) {
      log('apple_auth_rejected', { reason: e instanceof z.ZodError ? 'bad body' : (e as Error).message });
      return c.json({ error: 'unauthorized' }, 401);
    }
    const subHash = cipher.lookupHash('apple-sub', sub);
    if (!db.hasAppleSub(subHash) && newAccounts.hit('all')) return c.json(TOO_MANY_ACCOUNTS, 429);
    const { userId, created } = db.userForAppleSub(subHash);
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'apple');
    if (created) welcome(userId);
    log('apple_auth', { user_id: userId, created });
    return c.json({ device_token: token });
  });

  // ---- device account: the app's "Get started". No sign-in; it sits before the token check on purpose.
  // Every call makes a new user. device_id is never looked up, so nobody gets another user's token by sending their id.
  app.post('/v1/auth/device', rateLimiter('deviceAuth', clientIp), async (c) => {
    if (!DeviceAuthBody.safeParse(await c.req.json().catch(() => null)).success) return c.json({ error: 'device_id must be a UUID' }, 400);
    if (newAccounts.hit('all')) return c.json(TOO_MANY_ACCOUNTS, 429);
    const userId = db.createUser();
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'device');
    welcome(userId);
    log('device_auth', { user_id: userId });
    return c.json({ device_token: token });
  });

  // ---- email + password: sign-up and login sit before the token check on purpose.
  // TODO: no email verification yet. Anyone can sign up with an address they do not own. Add a verify link before launch.
  // Login answers the same 401 for an unknown email and a wrong password, after the same scrypt work.
  const WRONG = { error: 'wrong email or password' };
  const LOCKED = { error: 'too many tries, wait a few minutes and try again' };
  const emailKey = (email: string) => cipher.lookupHash('email', email);
  // Counts this try BEFORE any password check, so parallel guesses cannot slip past the limits:
  // per (email, client address) 5 tries then a 15-minute wait; per email 20 an hour, then a growing delay.
  // Applies to any email, with or without an account. Returns the 429 to send, or the keys to release on success.
  const ea = config.emailAuth;
  const tryEmail = (c: Context<Env>, key: string): { blocked: Response } | { pair: string; key: string } => {
    const pair = cipher.lookupHash('email-ip', `${key}:${clientIp(c)}`);
    const until = db.reserveAuthAttempt([
      { key: pair, max: ea.perIpMax, windowMs: ea.perIpWindowMs, lockFor: () => ea.perIpLockMs },
      { key, max: ea.perEmailMax, windowMs: ea.perEmailWindowMs, lockFor: (n) => Math.min(1000 * 2 ** (n - ea.perEmailMax), ea.maxDelayMs) },
    ], now());
    if (!until) return { pair, key };
    c.header('Retry-After', String(Math.max(1, Math.ceil((until - now()) / 1000))));
    return { blocked: c.json(LOCKED, 429) };
  };
  // A right password (or no password check at all) gives the try back: the address is cleared, the email count drops by one.
  const release = (t: { pair: string; key: string }) => db.releaseAuthAttempt([t.pair], [t.key]);
  // A hash that never ran (the queue was full) gives the try back, then the 503 goes out.
  const unlessBusy = async <T>(t: { pair: string; key: string }, work: Promise<T>): Promise<T> => {
    try {
      return await work;
    } catch (e) {
      if (e instanceof PasswordBusyError) db.releaseAuthAttempt([], [t.pair, t.key]);
      throw e;
    }
  };
  // True only for a real hash and the right password. A good login redoes a hash made with older scrypt settings;
  // when hashing is busy that waits for the next login.
  const passwordOk = async (t: { pair: string; key: string }, user: { id: string; password_hash: string | null } | undefined, password: string) => {
    const hash = user?.password_hash;
    const ok = (await unlessBusy(t, (async () => verifyPassword(password, hash ?? (await dummyHash())))())) && !!hash;
    if (ok) {
      release(t);
      if (needsRehash(hash)) {
        try {
          db.setPasswordHash(user.id, await hashPassword(password));
        } catch (e) {
          if (!(e instanceof PasswordBusyError)) throw e;
        }
      }
    }
    return ok;
  };
  // Every sign-in makes a new random token; only its hash is stored, and it expires after config.session.ttlMs.
  const newSession = (userId: string, label: string) => {
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), label);
    return token;
  };

  app.post('/v1/auth/email/signup', rateLimiter('emailAuth', clientIp), async (c) => {
    const b = EmailAuthBody.safeParse(await c.req.json().catch(() => null));
    if (!b.success) return c.json({ error: 'a valid email and a password are required' }, 400);
    const problem = passwordProblem(b.data.password);
    if (problem) return c.json({ error: problem }, 400);
    const key = emailKey(b.data.email);
    const t = tryEmail(c, key);
    if ('blocked' in t) return t.blocked;
    if (!db.userForEmail(key) && newAccounts.hit('all')) {
      release(t);
      return c.json(TOO_MANY_ACCOUNTS, 429);
    }
    const { userId, created } = db.createEmailUser(key, (id) => cipher.encrypt(id, b.data.email), await unlessBusy(t, hashPassword(b.data.password)));
    // The email has an account already. The right password signs in, so a second tap never makes a second account.
    if (!created && !(await passwordOk(t, db.userForEmail(key), b.data.password))) {
      log('email_signup_rejected', { reason: 'taken' });
      return c.json({ error: 'this email already has an account, log in instead' }, 409);
    }
    if (created) {
      release(t);
      welcome(userId);
    }
    log('email_signup', { user_id: userId, created });
    return c.json({ device_token: newSession(userId, 'email'), created });
  });

  app.post('/v1/auth/email/login', rateLimiter('emailAuth', clientIp), async (c) => {
    const b = EmailAuthBody.safeParse(await c.req.json().catch(() => null));
    if (!b.success) return c.json(WRONG, 401);
    const t = tryEmail(c, emailKey(b.data.email));
    if ('blocked' in t) return t.blocked;
    const user = db.userForEmail(t.key);
    if (!(await passwordOk(t, user, b.data.password)) || !user) {
      log('email_login_rejected', {});
      return c.json(WRONG, 401);
    }
    log('email_login', { user_id: user.id });
    return c.json({ device_token: newSession(user.id, 'email') });
  });

  // ---- auth: every other /v1 route resolves the user from the device token, never from the body
  app.use('/v1/*', async (c, next) => {
    const m = /^Bearer (pkd_[A-Za-z0-9_-]{20,100})$/.exec(c.req.header('authorization') ?? '');
    const tokenHash = m ? sha256(m[1]) : '';
    const userId = m ? db.userForTokenHash(tokenHash) : undefined;
    if (!userId) return c.json({ error: 'unauthorized' }, 401);
    c.set('userId', userId);
    c.set('tokenHash', tokenHash);
    await next();
  });
  const byUser = (c: Context<Env>) => c.get('userId');
  app.use('/v1/suggest', rateLimiter('suggest', byUser));
  app.use('/v1/reply', rateLimiter('suggest', byUser));
  app.use('/v1/ask', rateLimiter('suggest', byUser));
  app.use('/v1/chart', rateLimiter('suggest', byUser));
  app.use('/v1/actions/*', rateLimiter('actions', byUser));
  app.use('/v1/write/*', rateLimiter('write', byUser));
  app.use('/v1/disputes/:id/message', rateLimiter('actions', byUser));
  // One pattern covers /v1/explain and /v1/explain/visual, so both share the same buckets.
  app.use('/v1/explain/*', rateLimiter('explain', byUser), rateLimiter('explainDaily', byUser));
  app.use('/v1/*', rateLimiter('other', byUser));

  // ---- "Save your details": attaches an Apple account to the signed-in device account. The Apple token is checked exactly as in /v1/auth/apple.
  // If that Apple account already has a user (an earlier install), the caller gets a token for that user, so a re-install gets its data back.
  app.post('/v1/auth/apple/link', rateLimiter('auth', byUser), async (c) => {
    const userId = c.get('userId');
    let sub: string;
    try {
      sub = await appleSub(await c.req.json());
    } catch (e) {
      log('apple_link_rejected', { user_id: userId, reason: e instanceof z.ZodError ? 'bad body' : (e as Error).message });
      return c.json({ error: 'unauthorized' }, 401);
    }
    const linked = db.linkAppleSub(userId, cipher.lookupHash('apple-sub', sub));
    if (!linked) return c.json({ error: 'this account is already saved with another Apple account' }, 409);
    if (linked.owner === userId) {
      log('apple_link', { user_id: userId, recovered: false });
      return c.json({ linked: true, recovered: false });
    }
    const token = randomToken('pkd');
    db.addDevice(linked.owner, sha256(token), 'apple');
    log('apple_link', { user_id: linked.owner, recovered: true, from_user_id: userId });
    return c.json({ linked: true, recovered: true, device_token: token });
  });

  // ---- add an email and password to the signed-in account (device or Apple), the email twin of /v1/auth/apple/link.
  // If the email already has an account and the password is right, the caller gets a token for that account instead.
  // The password rules run before the email is looked up, so the answer to a weak password says nothing about the email.
  app.post('/v1/auth/email/link', rateLimiter('emailAuth', clientIp), rateLimiter('emailAuth', byUser), async (c) => {
    const userId = c.get('userId');
    const b = EmailAuthBody.safeParse(await c.req.json().catch(() => null));
    if (!b.success) return c.json({ error: 'a valid email and a password are required' }, 400);
    const problem = passwordProblem(b.data.password);
    if (problem) return c.json({ error: problem }, 400);
    const t = tryEmail(c, emailKey(b.data.email));
    if ('blocked' in t) return t.blocked;
    const held = db.userForEmail(t.key);
    if (held) {
      if (!(await passwordOk(t, held, b.data.password))) return c.json(WRONG, 401);
      if (held.id === userId) return c.json({ linked: true, recovered: false });
      log('email_link', { user_id: held.id, recovered: true, from_user_id: userId });
      return c.json({ linked: true, recovered: true, device_token: newSession(held.id, 'email') });
    }
    release(t);
    if (!db.linkEmail(userId, t.key, cipher.encrypt(userId, b.data.email), await hashPassword(b.data.password))) {
      return c.json({ error: 'this account already has an email' }, 409);
    }
    log('email_link', { user_id: userId, recovered: false });
    return c.json({ linked: true, recovered: false });
  });

  // ---- logout: the token stops working at once. ?all=1 ends every session of this user.
  app.post('/v1/auth/logout', (c) => {
    const userId = c.get('userId');
    const all = c.req.query('all') === '1';
    let ended = 1;
    if (all) ended = db.removeDevicesForUser(userId);
    else db.removeDevice(c.get('tokenHash'));
    log('logout', { user_id: userId, all, ended });
    return c.json({ logged_out: true, sessions_ended: ended });
  });

  // ---- the account: how the user signs in, and deleting it (App Store rule 5.1.1(v)).
  app.get('/v1/account', (c) => {
    const userId = c.get('userId');
    const a = db.account(userId);
    return c.json({ email: dec(userId, a?.email_enc ?? null), apple: !!a?.apple, password: !!a?.password });
  });
  app.delete('/v1/account', (c) => {
    if (c.req.header('x-user-action') !== 'tap') return c.json({ error: 'account delete runs only from an explicit user tap' }, 428);
    const userId = c.get('userId');
    learner.forget(userId);
    db.deleteAccount(userId);
    biz.forgetHistory(userId);
    log('account_deleted', { user_id: userId });
    return c.json({ deleted: true });
  });

  // ---- actions are default-deny: an explicit tap header plus an idempotency key
  // A stored answer can name a client, so it is encrypted with the user's key. Rows from before that are plain JSON.
  const storedAnswer = (userId: string, response: string) => JSON.parse(response.startsWith('{') ? response : cipher.decrypt(userId, response));
  const tapGate: MiddlewareHandler<Env> = async (c, next) => {
    // Lookup only: the stored answer for this key and body, or 404. It never runs the action, so it needs no tap.
    if (c.req.header('idempotency-lookup') === '1') {
      const prior = db.getIdem(c.get('userId'), c.req.header('idempotency-key') ?? '');
      if (!prior || prior.route !== c.req.path || prior.body_hash !== sha256(await c.req.text())) return c.json({ error: 'not found' }, 404);
      if (prior.status !== 'done' || !prior.response) return c.json({ error: 'request with this Idempotency-Key is in progress' }, 409);
      return c.json(storedAnswer(c.get('userId'), prior.response), 200);
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
      return c.json(storedAnswer(userId, prior.response), 200);
    }
    let stored = false;
    try {
      await next();
      if (c.res.status === 200 && !c.get('idemSkip')) {
        db.completeIdem(userId, key, cipher.encrypt(userId, await c.res.clone().text()));
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
    // One jev question when a lookup is likely but not sure ("invoice sam"); the rest of suggest may still run after it.
    let lookupPaid = 0;
    // "pay joe $200" is a payout, never a pay link. Its chip sits beside the other regex chips instead of ending suggest.
    const pay = more.payout(userId, text) ?? [];
    const done = (found: Chip[], intent: string, confidence: number) => {
      const chips = [...pay, ...found];
      timings.total_ms = Math.round(performance.now() - t0);
      const paid_calls = lookupPaid + (path === 'regex_none' || path === 'regex_lookup' || path === 'regex_intent' ? 0
        : path === 'jev_only' || path === 'jev_device' || path === 'extract_only' ? 1 : path === 'jev_lookup' ? 0 : 2);
      log('suggest', { user_id: userId, path, paid_calls, parallel, intent, confidence, chips: chips.length, ...timings });
      return c.json({ chips, intent, confidence, timings });
    };
    let extra: Chip[] | null = null;
    try {
      extra = await more.suggest(userId, text);
    } catch (e) {
      // A PayPal read behind a dispute or plan chip never fails suggest.
      log('more_suggest_failed', { err: (e as Error).message });
    }
    if (extra) return done(extra, 'more', 1);

    // A lookup of the owner's own records: regex settles it with no paid call when the phrase and the name are clear.
    const look = context ? null : lookupChip(userId, text);
    if (look && look.score >= SHOW_AT) {
      path = 'regex_lookup';
      return done([look.chip], 'lookup', look.score);
    }
    if (look && look.score >= ASK_AT) {
      path = 'jev_lookup';
      lookupPaid = 1;
      try {
        const r = await ai.askRoute(text, 'info');
        if (r.route === 'lookup' && r.confidence >= config.jev.minConfidence) return done([look.chip], 'lookup', r.confidence);
      } catch (e) {
        log('lookup_route_failed', { err: (e as Error).message });
      }
      path = 'regex_none';
    }

    // A payout sentence needs no model: it is never a pay link or an invoice.
    if (pay.length) return done([], 'payout', 1);

    const q = quick(text, context ?? '');
    // An owner command is a money signal even with no money word: "nudge Jordan", "chase Jordan".
    const command = context ? null : commandIntent(text);
    if (q.none && !command) {
      // No money signal. Plain chat stops here with no call; an action-ish sentence gets one jev question.
      if (context || !deviceSignal(text)) return done([], 'none', 1);
      path = 'jev_device';
      const sentence = lastSentence(text);
      let picked;
      try {
        picked = await ai.deviceAction(sentence);
      } catch (e) {
        log('device_failed', { err: (e as Error).message });
        return done([], 'error', 0);
      }
      if (picked.kind === 'none' || picked.confidence < config.jev.minConfidence) return done([], 'none', picked.confidence);
      return done(deviceChips(picked.kind, sentence), picked.kind, picked.confidence);
    }

    const profile = profileOf(userId);
    const business = promptBusinessOf(userId);
    const seen = `${text} ${context ?? ''}`;
    const known = regexFields(userId, q, text, seen);
    const extract = () => {
      path = 'jev+extract';
      return ai.extract(prompt, '', business).then(
        (ext) => { timings.extract_ms = Math.round(performance.now() - t0); return ext; },
        (e) => { timings.extract_ms = Math.round(performance.now() - t0); log('extract_failed', { err: (e as Error).message }); return null; },
      );
    };
    // A money signal the regex cannot fully fill: extraction starts alongside jev, so the total is about
    // max(jev, extract), and its result is dropped if jev finds no action. Skipped when the regex filled an intent.
    let extracting = Object.values(known).some(Boolean) ? null : extract();
    parallel = !!extracting;
    path = extracting ? 'jev+extract' : 'jev_only';
    const filled = { text, context: context ?? '', q, known, currency: profile.currency, business };

    // The owner plainly asks to be paid ("two screens for 50", "sam owes me 50 for the app screens"): the regex is sure
    // of the intent and the amount, so no jev question. The model reads only the client and the reason, and each
    // counts only when the owner typed it.
    const asked = context || command ? null : moneyRequest(text);
    if (asked) {
      // Every word is an amount, a money word or a known client: nothing left for the model to read.
      const model = known.pay_link ? null : await (extracting ?? extract());
      const client = known.send_reminder?.client_name ?? known.pay_link?.client_name ?? grounded(model?.client_name, text);
      const intent = q.email || client ? 'create_invoice' : 'pay_link';
      const ext: Extraction = {
        client_name: client, client_email: q.email, amount: asked.amount, currency: asked.currency,
        item: grounded(model?.item, text) ?? asked.reason,
      };
      path = timings.extract_ms !== undefined ? 'regex_ask+extract' : 'regex_ask';
      parallel = false;
      const trigger = moneyTrigger(text);
      // A one-tap pay link only when the regex read a plain total and every other word is known, or the model read the
      // same total (rule B). Otherwise the pay link confirms too.
      const unsure = !known.pay_link && !(q.amount === asked.amount && model?.amount === asked.amount);
      return done(buildChips(userId, intent, ext, text, '', profile.currency, unsure).map((ch) => (trigger ? { ...ch, trigger } : ch)), intent, 1);
    }

    // An owner command that names its action needs no jev question: "bill Kowalski ..." is an invoice, and
    // "remind Emma ..." is a reminder when one known unpaid client is named.
    if (command === 'create_invoice' || (command === 'send_reminder' && known.send_reminder && reminderAboutMoney(userId, text, known.send_reminder.client_name))) {
      const chips = await moneyChips(userId, command, filled, extracting, extract);
      path = timings.extract_ms !== undefined ? 'extract_only' : 'regex_intent';
      parallel = false;
      return done(chips ?? [], command, 1);
    }
    let cls;
    try {
      cls = await ai.classify(prompt, business);
    } catch (e) {
      timings.classify_ms = Math.round(performance.now() - t0);
      log('classify_failed', { err: (e as Error).message });
      return done([], 'error', 0);
    }
    timings.classify_ms = cls.ms;
    if (cls.intent === 'none' || cls.confidence < config.jev.minConfidence) return done([], cls.intent, cls.confidence);

    const chips = await moneyChips(userId, cls.intent, filled, extracting, extract);
    return done(chips ?? [], cls.intent, cls.confidence);
  });

  /** The lookup chip for typed text, with how much it is worth showing. Null for no lookup phrase or a name that is no client. */
  function lookupChip(userId: string, text: string): { chip: Chip; score: number } | null {
    const l = detectLookup(text, now());
    const r = l && search.find(userId, l);
    if (!l || !r || r.match === 'none') return null;
    return { chip: { kind: 'lookup', label: clean(chipLabel(r)), payload: r, needs_confirm: false, trigger: l.trigger }, score: importance(l.sure, r.match, r.candidates.length) };
  }

  /**
   * A device chip runs on the phone (calendar, reminders, notes), never here. The server gives the kind and a title;
   * the phone fills the time from its own reading of the sentence, or tomorrow 9 AM for a follow-up.
   */
  function deviceChips(kind: Exclude<DeviceAction, 'none'>, sentence: string): Chip[] {
    const title = deviceTitle(sentence);
    if (!title) return [];
    const name = nameIn(sentence);
    const base = { needs_confirm: false, trigger: deviceTrigger(sentence) };
    switch (kind) {
      case 'event': return [{ kind, label: 'Add to calendar', payload: { title }, ...base }];
      case 'reminder': return [{ kind, label: 'Remind me', payload: { title }, ...base }];
      case 'note': return [{ kind, label: 'Save note', payload: { text: sentence }, ...base }];
      case 'followup': return [{ kind, label: 'Follow up', payload: { title: name ? `Follow up with ${name}` : `Follow up: ${title}` }, ...base }];
    }
  }

  type Filled = { text: string; context: string; q: Quick; known: ReturnType<typeof regexFields>; currency: string; business: string };
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
        const extraWords = !onlyKnownWords(f.text, clientNames(userId));
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
    // Each chip names the typed words it came from ("$45 for the haircut"), so the keyboard can quote them.
    const trigger = f.context ? null : moneyTrigger(f.text);
    return buildChips(userId, intent, ext, f.text, f.context, f.currency, unsure).map((ch) => (trigger ? { ...ch, trigger } : ch));
  }

  /** The model's words, kept only when every main word of them is in what the owner typed. Never a word nobody typed. */
  const grounded = (v: string | null | undefined, typed: string) => {
    const w = cleanOrNull(v, 120);
    return w && saidAll(w, typed) ? w : null;
  };

  /**
   * For each intent that needs fields: the fields when the regex and the owner's own records give all of them
   * (then no extract call), else null. An invoice needs amount and a typed email; a pay link
   * needs amount; a reminder needs one known unpaid client named; a refund needs one paid client
   * named and, if the text has digits, the amount. A regex amount counts only when every other word the owner
   * typed is a money word or a known client; else the model reads it too (rule B).
   */
  const clientNames = (userId: string) =>
    [...db.listInvoices(userId), ...db.listOrders(userId)].map((r) => dec(userId, r.client_name_enc)).filter((n): n is string => !!n);

  function regexFields(userId: string, q: Quick, text: string, seen: string) {
    const invoices = db.listInvoices(userId);
    const orders = db.listOrders(userId);
    const clients = clientNames(userId);
    const named = (rows: (InvoiceRow | OrderRow)[], firstName = false) => {
      const said = (n: string) => mentions(seen, n) || (firstName && mentions(seen, n.trim().split(/\s+/)[0]));
      const names = new Set(rows.map((r) => dec(userId, r.client_name_enc)).filter((n): n is string => !!n && said(n)));
      return names.size === 1 ? [...names][0] : null;
    };
    const amount = q.amount !== null && onlyKnownWords(text, clients);
    const base: Extraction = { client_name: named([...invoices, ...orders]), client_email: q.email, amount: q.amount, currency: q.currency, item: null };
    const unpaid = invoices.filter((r) => !r.paid_at && r.status !== 'CANCELLED');
    const paid = [...invoices, ...orders].filter((r) => r.paid_at && r.capture_id && r.status !== 'REFUNDED');
    // "remind Jordan" names Jordan Ray: a reminder, like its chip, accepts a first name.
    const remindName = named(unpaid, true);
    const refundName = named(paid);
    return {
      create_invoice: amount && q.email ? base : null,
      pay_link: amount ? base : null,
      send_reminder: remindName ? { ...base, client_name: remindName } : null,
      refund: refundName && (amount || !/\d/.test(seen)) ? { ...base, client_name: refundName } : null,
    };
  }

  // "nudge Emma" and "chase Emma" always mean money. "remind Jordan" with nothing after the name is a Nudge too.
  // "remind Emma to bring the leash" or "remind Emma that we meet at 5" is personal: after "to" or "that" only a
  // money word or a word of an unpaid invoice's item counts, and a bare number is a time, not a price.
  // Anything else after the name ("about the invoice", "she owes me") needs a money word, a price or an item word.
  const MONEY_WORD = /\b(pay|paid|payment|payments|invoice|invoices|bill|bills|owe|owes|owed|owing|due|overdue|balance)\b|[$€£]/i;
  const reminderAboutMoney = (userId: string, text: string, name: string | null | undefined) => {
    const rest = name ? afterRemindName(text, name) : null;
    if (rest === '') return true;
    if (!/^\s*remind\b/i.test(lastSentence(text))) return true;
    const about = rest ?? text;
    const money = MONEY_WORD.test(about) || (!/^(?:to|that)\b/i.test(about) && /\d/.test(about));
    return money || mentionsItemWord(about, db.listInvoices(userId).filter((r) => !r.paid_at && r.status !== 'CANCELLED').map((r) => r.item));
  };

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
    if (emails.size) return emails.size === 1 ? [...emails][0] : null;
    // No invoice for this client yet: the email PayPal gave for the one learned client with this name.
    const learned = learner.clients(userId).filter((c) => c.name?.trim().toLowerCase() === want && c.email);
    return learned.length === 1 ? learned[0].email : null;
  }

  function buildChips(userId: string, intent: string, rawExt: Extraction | null, text: string, context: string, defaultCurrency: string, unsure = false): Chip[] {
    // The reason is the owner's (or the copied client text's) own words, never a word nobody typed ("Logo design").
    const ext = rawExt && { ...rawExt, item: grounded(rawExt.item, `${text} ${context}`), client_name: cleanOrNull(rawExt.client_name, 100) };
    // A typed currency wins; a bare $ is in the profile currency.
    const typedCurrency = (config.money.currencies as readonly string[]).includes(ext?.currency ?? '') ? ext!.currency! : null;
    let currency = typedCurrency ?? defaultCurrency;
    // Copied or typed text names a client: true when that text holds the client's full or first name.
    const namedIn = (t: string, client: string) => !!client && (mentions(t, client) || mentions(t, client.split(/\s+/)[0]));

    if (intent === 'create_invoice' || intent === 'pay_link') {
      let cents = ext?.amount != null ? amountToCents(ext.amount) : null;
      // No amount said: a client Muninn learned from PayPal, named in the owner's own text, brings their usual item
      // and price as a suggestion. The chip names that item, the pay link confirms too, and the invoice confirm shows every value.
      const learned = cents === null ? learner.named(userId, text) : null;
      const usual = learned?.usual && (!typedCurrency || typedCurrency === learned.usual.currency)
        && (config.money.currencies as readonly string[]).includes(learned.usual.currency) ? learned.usual : null;
      if (usual) {
        cents = amountToCents(usual.amount);
        currency = usual.currency;
        unsure = true;
      }
      if (cents === null) return [];
      const said = usual ? usual.item : ext?.item;
      const item = said ? said.charAt(0).toUpperCase() + said.slice(1) : 'Payment';
      const money = formatMoney(cents, currency);
      const base = { amount: centsToValue(cents), currency, item, client_name: ext?.client_name ?? (usual ? learned!.name : null) };
      // An email the owner typed, else the one email the owner's records hold for the client named in the owner's
      // text. Never an email the model read from copied client text or made up.
      // Two or more typed emails: the owner picks on the confirm, never the model.
      const emails = typedEmails(text);
      const typed = ext?.client_email && emails.length === 1 && emails[0] === ext.client_email.toLowerCase() ? ext.client_email : null;
      const email = emails.length > 1 ? null : typed ?? recordEmail(userId, base.client_name, text) ?? (usual ? learned!.email : null);
      const recipient = email ?? ext?.client_name ?? null;
      // Every invoice gets one confirm tap that shows the amount and the recipient; the server checks both.
      const invoice = chip('invoice', `Invoice ${money} · ${item}${recipient ? ` → ${recipient}` : ''}`, { ...base, client_email: email }, true);
      const link = chip('paylink', `Pay link ${money} · ${item}`, base, unsure);
      return intent === 'create_invoice' ? [invoice, link] : [link, invoice];
    }
    if (intent === 'payment_status') {
      const unpaid = db.unpaidCount(userId);
      return [chip('payments', `Who owes you · ${unpaid} unpaid`, {})];
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
      return [chip('remind', `Nudge ${name} · ${formatMoney(hit.amount_cents, hit.currency)} owed`,
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
    const clients = clientNames(userId);
    const known = new Set(clients.filter((n) => mentions(text, n)));
    let ext: Extraction | null = q.amount !== null && onlyKnownWords(plain, clients)
      ? { client_name: known.size === 1 ? [...known][0] : null, client_email: q.email, amount: q.amount, currency: q.currency, item: null }
      : null;
    if (!ext) {
      const model = await extract();
      if (!model) return [];
      ext = { ...model, client_email: q.email ?? model.client_email, amount: q.amount ?? model.amount, currency: q.amount !== null ? q.currency : model.currency };
    }
    const cents = ext.amount != null ? amountToCents(ext.amount) : null;
    if (cents === null) return [];
    const typedCurrency = (config.money.currencies as readonly string[]).includes(ext.currency ?? '') ? ext.currency! : null;
    const currency = typedCurrency ?? profileOf(userId).currency;
    const rawName = cleanOrNull(ext.client_name, 100);
    const name = rawName && (mentions(text, rawName) || mentions(text, rawName.split(/\s+/)[0])) ? rawName : null;
    const emails = typedEmails(text);
    const typed = ext.client_email && emails.length === 1 && emails[0] === ext.client_email.toLowerCase() ? emails[0] : null;
    const email = emails.length > 1 ? null : typed ?? recordEmail(userId, name, text);
    const itemName = grounded(ext.item, text);
    const item = itemName ? itemName.charAt(0).toUpperCase() + itemName.slice(1) : 'Repeat payment';
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
    const account = connect.account(userId);
    const inv = await paypal.forAccount(userId, account).createAndSendInvoice({
      value: centsToValue(b.amount), currency, item: b.item, clientName: b.client_name ?? null, clientEmail: b.client_email ?? null,
      businessName: profile?.business_name ?? null,
    }, idemKey(c));
    const created = now();
    db.insertInvoice({
      id: inv.id, user_id: userId, status: inv.status, amount_cents: b.amount, currency, item: b.item,
      client_name_enc: enc(userId, b.client_name), client_email_enc: enc(userId, b.client_email), pay_link: inv.payLink,
      due_at: created + config.money.invoiceDueDays * DAY, created_at: created, pp_account: account,
    });
    const ms = Math.round(performance.now() - t);
    log('invoice_created', { user_id: userId, invoice_id: inv.id, status: inv.status, paypal_ms: ms });
    return c.json({ id: inv.id, status: inv.status, pay_link: inv.payLink, amount: centsToValue(b.amount), currency, paypal_ms: ms, demo: !account });
  });

  app.post('/v1/actions/paylink', async (c) => {
    const userId = c.get('userId');
    const b = await body(c, PayLinkBody);
    const currency = b.currency ?? db.getProfile(userId)?.currency ?? 'USD';
    const t = performance.now();
    const account = connect.account(userId);
    const o = await paypal.forAccount(userId, account).createOrder({ value: centsToValue(b.amount), currency, item: b.item }, idemKey(c));
    db.insertOrder({
      id: o.id, user_id: userId, status: o.status, amount_cents: b.amount, currency, item: b.item,
      client_name_enc: enc(userId, b.client_name), approve_link: o.approveLink, created_at: now(), pp_account: account,
    });
    const ms = Math.round(performance.now() - t);
    log('order_created', { user_id: userId, order_id: o.id, status: o.status, paypal_ms: ms });
    return c.json({ id: o.id, status: o.status, approve_link: o.approveLink, amount: centsToValue(b.amount), currency, paypal_ms: ms, demo: !account });
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
    // Plans and products belong to one PayPal account, so a connected seller's keys carry its account.
    const account = connect.account(userId);
    const acct = account ? `m:${account}:` : '';
    const planKey = `${acct}${currency}:${b.amount}:${b.interval}`;
    const cached = db.getBillingPlan(userId, planKey);
    const t = performance.now();
    const sub = await paypal.forAccount(userId, account).createSubscription({
      value: centsToValue(b.amount), currency, interval: b.interval, clientEmail: b.client_email ?? null,
      productId: cached?.product_id ?? db.anyBillingProduct(userId, acct), planId: cached?.plan_id ?? null,
      productRequestId: requestIdFor(userId, `${acct}billing-product`), planRequestId: requestIdFor(userId, `billing-plan:${planKey}`),
    }, idemKey(c));
    db.putBillingPlan(userId, planKey, sub.productId, sub.planId);
    db.insertSubscription({
      id: sub.id, user_id: userId, status: sub.status, amount_cents: b.amount, currency, interval: b.interval, item,
      client_name_enc: enc(userId, b.client_name), client_email_enc: enc(userId, b.client_email), approve_link: sub.approveLink,
      plan_id: sub.planId, created_at: now(), pp_account: account,
    });
    const ms = Math.round(performance.now() - t);
    log('subscription_created', { user_id: userId, subscription_id: sub.id, status: sub.status, paypal_ms: ms });
    return c.json({ id: sub.id, status: sub.status, approve_link: sub.approveLink, amount: centsToValue(b.amount), currency, interval: b.interval, item, paypal_ms: ms, demo: !account });
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
    await paypal.forAccount(userId, inv.pp_account).remind(inv.id, idemKey(c));
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
      const target = r.target_kind === 'invoice' ? db.getInvoice(userId, r.target_id) : db.getOrder(userId, r.target_id);
      try {
        const out = await paypal.forAccount(userId, target?.pp_account ?? null).refundCapture(r.capture_id, centsToValue(r.amount_cents), r.currency, r.id);
        db.finishRefund(userId, r.id, 'done', out.id);
        const status = db.refundState(userId, r.target_id).doneCents >= (target?.amount_cents ?? 0) ? 'REFUNDED' : 'PARTIALLY_REFUNDED';
        if (r.target_kind === 'invoice') db.setInvoiceStatus(userId, r.target_id, status, null, null);
        else db.setOrderStatus(userId, r.target_id, status, null, null);
        log('refund_done', { user_id: userId, target_id: r.target_id, refund_id: out.id, status });
        return c.json({ ok: true, refund_id: out.id, status: out.status, amount: centsToValue(r.amount_cents), currency: r.currency, demo: !target?.pp_account });
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
    return c.json({ confirm_token: token, expires_in_s: config.money.refundConfirmTtlMs / 1000, summary: `Refund ${formatMoney(cents, target.currency)} to ${who}? Can't undo.` });
  });

  // ---- read views

  app.get('/v1/payments', async (c) => {
    const userId = c.get('userId');
    if (c.req.query('refresh') === '1') {
      const stale = db.listInvoices(userId, 10).filter((r) => invoiceState(r.status) === 'unpaid');
      await Promise.all(stale.map(async (r) => {
        try {
          const s = await paypal.forAccount(userId, r.pp_account).getInvoice(r.id);
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

  // ---- chart: money in by month from the owner's PayPal history, plus a marked estimate. Read-only: it never moves money.
  app.get('/v1/chart', async (c) => {
    const userId = c.get('userId');
    const q = ChartQuery.parse({ back: c.req.query('back'), ahead: c.req.query('ahead'), tz: c.req.query('tz') });
    const tz = zoneOr(q.tz);
    const at = now();
    const set = await biz.history(userId, monthStart(at, -q.back, tz), tz);
    const chart = buildChart(set.rows, { at, back: q.back, ahead: q.ahead, currency: profileOf(userId).currency, tz });
    log('chart', { user_id: userId, back: q.back, ahead: q.ahead, source: set.source, rows: set.rows.length, estimate: chart.enough_history });
    return c.json({ ...chart, source: set.source, note: set.note });
  });

  // ---- integrations and the business view, all through the user's own PayPal connection
  app.route('/', connect.routes);
  app.get('/v1/integrations', (c) => c.json({ integrations: integrations.list(c.get('userId')) }));
  // The webhook URL is a secret: stored encrypted and never sent back. null disconnects.
  app.put('/v1/integrations/slack', async (c) => {
    const userId = c.get('userId');
    const { webhook_url } = await body(c, SlackBody);
    slack.put(userId, webhook_url);
    log('slack_connected', { user_id: userId, connected: !!webhook_url });
    return c.json({ integration: integrations.list(userId).find((i) => i.id === 'slack') });
  });

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
    const reply = await ai.reply(text, replyProfile(userId));
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
  const NOT_SURE = 'Try: invoice Sam $45 · nudge Ana · refund Sam $20 · who owes me';
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
    const extra = more.payout(userId, text) ?? await more.suggest(userId, text, 'ask');
    if (extra) return done('action' as AskRoute, 1, { chips: extra });

    const aq = askQuick(text);
    if (aq.none) return none(1, NOT_SURE);
    // A clear lookup phrase needs no router. An unknown name still answers: "No invoices for Sam yet".
    const look = detectLookup(text, now());
    const found = look ? search.find(userId, look) : null;
    // "invoice sam" with one client named Sam is a lookup too; with no such client it goes to the router.
    if (look && found && (look.sure || importance(look.sure, found.match, found.candidates.length) >= SHOW_AT)) return done('lookup', 1, found);
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

    const extract = () => {
      paid++;
      return ai.extract(text, '', promptBusinessOf(userId)).catch((e) => { log('extract_failed', { err: (e as Error).message }); return null; });
    };
    if (route === 'subscribe') {
      if (repeatEnds(text)) return none(confidence, "Repeat billing with an end date isn't ready yet. Send one invoice at a time for now.");
      if (!intervalOf(text)) return none(confidence, 'Say how often, like "bill Sam $40 monthly".');
      return done(route, confidence, { chips: await subscribeChips(userId, text, extract) });
    }

    const intent = ROUTE_INTENT[route];
    if (intent) {
      const q = quick(text);
      const filled = { text, context: '', q, known: regexFields(userId, q, text, text), currency: profileOf(userId).currency, business: promptBusinessOf(userId) };
      return done(route, confidence, { chips: (await moneyChips(userId, intent, filled, null, extract)) ?? [] });
    }

    if (route === 'review_ask') {
      const url = db.getProfile(userId)?.review_url;
      if (!url) return none(confidence, 'Add your Google review link in Integrations first.');
      return done(route, confidence, { text: `Thanks for coming in! If you have a minute, a review would mean a lot: ${url}` });
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
        return done(route, confidence, { reply: await ai.reply(d, replyProfile(userId)) });
      } catch (e) {
        // A model error can quote the text, so only its type is logged.
        return none(confidence, 'Writing help is not available right now. Try again.', (e as Error).name);
      }
    }

    if (route === 'who_paid') return done(route, confidence, { payments: paymentsOf(userId) });
    if (route === 'brief') return done(route, confidence, await biz.brief(userId, () => paid++));
    if (route === 'clients') return done(route, confidence, await biz.clients(userId));
    if (route === 'lookup') {
      const r = look && search.find(userId, look);
      return r ? done(route, confidence, r) : none(confidence, 'Say whose record, like "invoice for Sam" or "did Ana pay".');
    }
    if (route === 'disputes') return done(route, confidence, { disputes: await biz.disputes(userId) });
    if (route === 'add_note') {
      const note = clean(noteText(text));
      return note ? done(route, confidence, { action: 'add_note', text: note }) : none(confidence, 'Say what to note, like "add a note: buy shampoo".');
    }
    return done(route, confidence, { action: 'show_calendar' });
  });

  // ---- profile
  const profileOut = (userId: string) => {
    const p = db.getProfile(userId);
    return p ? { ...p, description: businessOf(userId) || null } : null;
  };
  // What Muninn learned from the owner's own PayPal: counts and a short summary, no client names.
  app.get('/v1/paypal/learned', (c) => c.json({ learned: learner.summary(c.get('userId')) }));

  app.get('/v1/profile', (c) => c.json({ profile: profileOut(c.get('userId')) }));
  // "What does your business do?": the keyboard reads price questions as questions about this business.
  app.put('/v1/profile/business', async (c) => {
    const userId = c.get('userId');
    const { description } = await body(c, BusinessBody);
    db.setDescriptionEnc(userId, enc(userId, description), DEFAULT_PROFILE);
    return c.json({ profile: profileOut(userId) });
  });
  app.put('/v1/profile', async (c) => {
    const p = await body(c, ProfileBody);
    db.putProfile(c.get('userId'), p);
    return c.json({ profile: profileOut(c.get('userId')) });
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
    // Slack hears about a payment once: only when this event is the one that marks it paid.
    const paidNow = (owner: string, r: { paid_at: number | null; client_name_enc: string | null; amount_cents: number; currency: string; item: string } | undefined) =>
      r && !r.paid_at ? () => slack.notifyPaid(owner, { clientName: dec(owner, r.client_name_enc), cents: r.amount_cents, currency: r.currency, item: r.item }) : null;
    let notify: (() => Promise<void>) | null = null;
    if (type === 'INVOICING.INVOICE.PAID') {
      const id = res.invoice?.id ?? res.id;
      const owner = id && db.ownerOfInvoice(id);
      if (owner) {
        notify = paidNow(owner, db.getInvoice(owner, id));
        db.setInvoiceStatus(owner, id, 'PAID', now(), res.invoice?.payments?.transactions?.[0]?.payment_id ?? null);
        handled = true;
      }
    } else if (type === 'CHECKOUT.ORDER.APPROVED') {
      const owner = res.id && db.ownerOfOrder(res.id);
      if (owner) {
        const before = db.getOrder(owner, res.id);
        const cap = await paypal.forAccount(owner, before?.pp_account ?? null).captureOrder(res.id, `capture-${res.id}`);
        db.setOrderStatus(owner, res.id, cap.status, cap.status === 'COMPLETED' ? now() : null, cap.captureId);
        if (cap.status === 'COMPLETED') notify = paidNow(owner, before);
        handled = true;
      }
    } else if (type === 'BILLING.SUBSCRIPTION.ACTIVATED') {
      const owner = res.id && db.ownerOfSubscription(res.id);
      // CANCELLED and SUSPENDED are final here: a late or replayed ACTIVATED never brings one back.
      const status = owner && db.getSubscription(owner, res.id)?.status;
      if (owner) {
        if (status !== 'CANCELLED' && status !== 'SUSPENDED') db.setSubscriptionActive(owner, res.id, now());
        handled = true;
      }
    } else if (type === 'BILLING.SUBSCRIPTION.CANCELLED' || type === 'BILLING.SUBSCRIPTION.SUSPENDED') {
      const owner = res.id && db.ownerOfSubscription(res.id);
      if (owner) {
        db.setSubscriptionStatus(owner, res.id, type === 'BILLING.SUBSCRIPTION.CANCELLED' ? 'CANCELLED' : 'SUSPENDED');
        handled = true;
      }
    } else if (type === 'PAYMENT.SALE.COMPLETED') {
      // A payment on a subscription: the sale's billing_agreement_id is the subscription id.
      // A late sale counts, but only ACTIVATED brings back a cancelled or suspended repeat bill.
      const subId = res.billing_agreement_id;
      const owner = subId && res.id && db.ownerOfSubscription(subId);
      if (owner) {
        const sub = db.getSubscription(owner, subId);
        if (sub && sub.status !== 'CANCELLED' && sub.status !== 'SUSPENDED') db.setSubscriptionActive(owner, subId, now());
        // The alert names this sale's own amount. A sale with no readable amount gets no alert.
        const saleCents = amountToCents(res.amount?.total);
        const saleCurrency = Currency.safeParse(res.amount?.currency).data;
        if (db.addSubscriptionPayment(owner, subId, String(res.id), now()) && sub && saleCents !== null && saleCurrency) {
          notify = paidNow(owner, { ...sub, paid_at: null, amount_cents: saleCents, currency: saleCurrency });
        }
        handled = true;
      }
    } else if (type.startsWith('MERCHANT.')) {
      handled = await connect.webhook(type, res);
    } else if (type === 'PAYMENT.CAPTURE.COMPLETED') {
      const orderId = res.supplementary_data?.related_ids?.order_id;
      const owner = orderId && db.ownerOfOrder(orderId);
      if (owner) {
        notify = paidNow(owner, db.getOrder(owner, orderId));
        db.setOrderStatus(owner, orderId, 'COMPLETED', now(), res.id ?? null);
        handled = true;
      }
    }
    // Slack goes out after the answer, so a slow Slack never holds up PayPal. notifyPaid logs its own failures.
    if (notify) setImmediate(notify);
    log('webhook', { event_type: type, handled });
    return c.json({ ok: true, handled });
  });

  more.mount(app);
  // ---- "Send as link": the keyboard uploads a drawing and types the short link into the chat.
  // multipart/form-data with `image` (the PNG), `preview` (a JPEG for link previews) and an optional `title`;
  // a bare image/png body (older builds) is still taken, with no preview.
  app.post('/v1/drawings', rateLimiter('shareUpload', byUser), async (c) => {
    const lim = config.sharedImage;
    let png: Uint8Array, previewBytes: Uint8Array | undefined, title: string | undefined;
    const type = c.req.header('content-type') ?? '';
    if (type === 'image/png') {
      png = new Uint8Array(await c.req.arrayBuffer());
    } else if (type.startsWith('multipart/form-data')) {
      const form = await c.req.parseBody().catch(() => undefined);
      const image = form?.image, preview = form?.preview;
      if (!(image instanceof File) || !(preview instanceof File)) return c.json({ error: 'send image and preview files' }, 400);
      png = new Uint8Array(await image.arrayBuffer());
      previewBytes = new Uint8Array(await preview.arrayBuffer());
      title = typeof form?.title === 'string' ? clean(form.title).slice(0, lim.maxTitleChars) || undefined : undefined;
    } else {
      return c.json({ error: 'send a PNG image' }, 400);
    }
    if (!isPng(png)) return c.json({ error: 'send a PNG image' }, 400);
    if (png.length > lim.maxBytes) return c.json({ error: 'image too large' }, 413);
    let preview: Preview | undefined;
    if (previewBytes) {
      if (previewBytes.length > lim.preview.maxBytes) return c.json({ error: 'preview too large' }, 413);
      const size = jpegSize(previewBytes);
      if (!size) return c.json({ error: 'preview must be a JPEG' }, 400);
      if (size.width < lim.preview.minWidth || size.width > lim.preview.maxSide || size.height > lim.preview.maxSide) {
        return c.json({ error: `preview must be ${lim.preview.minWidth} to ${lim.preview.maxSide} px wide` }, 400);
      }
      preview = { jpeg: previewBytes, ...size };
    }
    const at = now();
    db.purgeSharedImages(at, lim.keepGoneMs);
    // 128 random bits: the link cannot be guessed, and ids say nothing about the user or the time.
    const id = randomBytes(16).toString('base64url');
    const expiresAt = at + lim.ttlMs;
    db.addSharedImage({ id, userId: c.get('userId'), png, createdAt: at, expiresAt, preview, title });
    log('share_image', { user_id: c.get('userId'), bytes: png.length, preview_bytes: preview?.jpeg.length ?? 0 });
    const base = config.publicUrl || new URL(c.req.url).origin;
    return c.json({ url: `${base}/d/${id}`, image_url: `${base}/d/${id}.png`, expires_at: new Date(expiresAt).toISOString() });
  });

  // ---- explain: the phone sends only text its own regex read as an explain request, so plain chat never reaches here.
  // Only sizes and timings are logged, never the question or the answer.
  const explaining = async <T extends object>(c: Context<Env>, kind: string, chars: number, run: () => Promise<T>) => {
    const t = performance.now();
    try {
      const out = await run();
      log('explain', { user_id: c.get('userId'), kind, chars, ms: Math.round(performance.now() - t), ok: true, paid_calls: 1 });
      return c.json(out);
    } catch (e) {
      log('explain', { user_id: c.get('userId'), kind, chars, ms: Math.round(performance.now() - t), ok: false, err: (e as Error).name });
      return c.json({ error: 'explain is not available right now' }, 502);
    }
  };
  app.post('/v1/explain', async (c) => {
    const { text } = await body(c, ExplainBody);
    return explaining(c, 'explain', text.length, () => ai.explain(text));
  });
  app.post('/v1/explain/visual', async (c) => {
    const { topic } = await body(c, VisualBody);
    return explaining(c, 'visual', topic.length, () => ai.visual(topic));
  });

  return app;
}
