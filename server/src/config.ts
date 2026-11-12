const env = process.env;

export const INTENTS = ['create_invoice', 'pay_link', 'payment_status', 'send_reminder', 'refund', 'catalog_reply', 'none'] as const;
export type Intent = (typeof INTENTS)[number];
// Ask router: step 1 picks a group, step 2 picks one function inside it. 'none' is the last option of every question.
export const ASK_GROUPS = ['money', 'writing', 'info', 'device', 'none'] as const;
export type AskGroup = (typeof ASK_GROUPS)[number];
export const ASK_ROUTES = {
  money: ['invoice', 'paylink', 'subscribe', 'remind', 'refund', 'none'],
  writing: ['fix', 'refine', 'tone', 'reply', 'review_ask', 'none'],
  info: ['who_paid', 'brief', 'clients', 'lookup', 'disputes', 'none'],
  device: ['add_note', 'today_calendar', 'none'],
} as const;
export type AskRoute = (typeof ASK_ROUTES)[Exclude<AskGroup, 'none'>][number];
// How often a repeat bill charges. PayPal plans take the same units in capitals.
export const INTERVALS = ['week', 'month', 'year'] as const;
export type Interval = (typeof INTERVALS)[number];
export const TONES = ['polite', 'professional', 'friendly', 'shorter', 'firmer'] as const;
export type Tone = (typeof TONES)[number];

export const config = {
  port: Number(env.PORT ?? 8787),
  dbPath: env.DB_PATH ?? new URL('../data/pro-keyboard.db', import.meta.url).pathname,
  corsOrigins: (env.CORS_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  trustProxy: env.TRUST_PROXY === '1',
  // Behind Cloudflare (Render), X-Forwarded-For ends with the Cloudflare edge, so read the header Cloudflare sets instead.
  clientIpHeader: (env.CLIENT_IP_HEADER ?? '').trim().toLowerCase(),
  bodyLimitBytes: 16 * 1024,
  maxTextChars: 2000,
  maxContextChars: 1000,
  maxWriteChars: 1500,
  maxExplainChars: 200,
  // "Send as link": a drawing PNG kept for 30 days at an unguessable URL. PUBLIC_URL is the address people open,
  // else PUBLIC_BASE_URL (the one PayPal Connect uses), else the request's own origin.
  sharedImage: { maxBytes: 1024 * 1024, ttlMs: 30 * 86_400_000 },
  publicUrl: (env.PUBLIC_URL ?? env.PUBLIC_BASE_URL ?? '').replace(/\/+$/, ''),

  apple: {
    // The app bundle id. Apple puts it in the identity token as aud.
    audience: env.APPLE_BUNDLE_ID ?? 'com.orseliyas.muninn',
    issuer: 'https://appleid.apple.com',
    jwksUrl: 'https://appleid.apple.com/auth/keys',
    jwksTtlMs: 24 * 60 * 60 * 1000,
    jwksMinRefetchMs: 60_000,
    timeoutMs: 5000,
    // GET /v1/auth/apple/nonce gives a single-use nonce for this long. When required, a nonce the server never gave out
    // is refused. Required with APPLE_NONCE_REQUIRED=1, or in production unless APPLE_NONCE_REQUIRED=0.
    nonceTtlMs: 10 * 60_000,
    requireServerNonce: env.APPLE_NONCE_REQUIRED === '1' || (env.NODE_ENV === 'production' && env.APPLE_NONCE_REQUIRED !== '0'),
  },

  // A device token works for this long after sign-in. Each sign-in makes a new one.
  session: { ttlMs: 90 * 86_400_000 },
  // Password hashing: 64 MB each, so at most 2 at once on a 512 MB server. Others wait in line up to queueTimeoutMs, then get 503.
  password: { maxConcurrent: 2, queueTimeoutMs: 10_000 },
  // Email + password tries. One client address gets 5 tries per email in 15 minutes, then waits 15 minutes.
  // Across all addresses an email gets 20 tries an hour; after that each try waits longer (1 s, 2 s, 4 s ... up to 5 minutes),
  // so an attacker slows the owner down but cannot lock them out for long.
  emailAuth: { perIpMax: 5, perIpWindowMs: 15 * 60_000, perIpLockMs: 15 * 60_000, perEmailMax: 20, perEmailWindowMs: 60 * 60_000, maxDelayMs: 5 * 60_000 },

  paypal: {
    sandbox: env.PAYPAL_ENV !== 'live',
    baseUrl: env.PAYPAL_ENV === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com',
    webUrl: env.PAYPAL_ENV === 'live' ? 'https://www.paypal.com' : 'https://www.sandbox.paypal.com',
    webhookId: env.PAYPAL_WEBHOOK_ID ?? '',
    timeoutMs: 15000,
    // Connect PayPal: the platform account's own merchant id (merchant-integrations lookups need it),
    // an optional partner BN code, and this server's public https address for PayPal's return link.
    partnerMerchantId: env.PAYPAL_PARTNER_MERCHANT_ID ?? '',
    bnCode: env.PAYPAL_BN_CODE ?? '',
    publicUrl: (env.PUBLIC_BASE_URL ?? '').replace(/\/+$/, ''),
    // The app's ASWebAuthenticationSession waits for this scheme. A pending connect expires after this long.
    appReturnUrl: 'muninn://paypal-connected',
    connectTtlMs: 60 * 60 * 1000,
    // The one-time code on the app return link: the app finishes Connect with it, signed in, within this time.
    connectCodeTtlMs: 10 * 60 * 1000,
  },

  jev: {
    url: 'https://api.typesafe.ai/v1/systemone',
    model: env.TYPESAFE_MODEL ?? 'jev-latest',
    timeoutMs: 4000,
    minConfidence: 0.6,
  },

  llm: {
    url: 'https://openrouter.ai/api/v1/chat/completions',
    timeoutMs: 2000,
    hedgeMs: 700,
    // Rewrites are longer than extraction, so they get more time before the backup model starts.
    writeTimeoutMs: 6000,
    writeHedgeMs: 1500,
    // A drawn scene is a few thousand tokens of JSON.
    explainTimeoutMs: 15_000,
    primary: { model: 'meta-llama/llama-3.3-70b-instruct', provider: { order: ['groq'], allow_fallbacks: true } },
    fallback: { model: 'google/gemini-2.5-flash' },
  },

  money: {
    maxAmount: 10000,
    currencies: ['USD', 'EUR', 'GBP', 'CAD', 'AUD'] as const,
    invoiceDueDays: 7,
    refundConfirmTtlMs: 2 * 60 * 1000,
    // Payouts send the owner's own money out. Each currency's payouts in one UTC day stay at or under this many units.
    payoutDailyCap: 1000,
    // The shared demo merchant sends real sandbox money for everyone not connected: a small cap per user and one for all of them.
    demoPayoutDailyCap: 50,
    demoPayoutPlatformDailyCap: 200,
  },

  rateLimit: {
    suggest: { limit: 60, windowMs: 60_000 },
    actions: { limit: 20, windowMs: 60_000 },
    write: { limit: 30, windowMs: 60_000 },
    // Explain and draw are paid calls the owner asks for, so a few a minute and a cap per day.
    explain: { limit: 10, windowMs: 60_000 },
    explainDaily: { limit: 100, windowMs: 86_400_000 },
    shareUpload: { limit: 20, windowMs: 3_600_000 },
    // Opening a shared link needs no token, so it is limited per address.
    shareView: { limit: 120, windowMs: 60_000 },
    other: { limit: 120, windowMs: 60_000 },
    auth: { limit: 10, windowMs: 60_000 },
    // Email sign-up, login and link, per client address. Tries per email are counted in the DB (emailAuth above).
    emailAuth: { limit: 10, windowMs: 60_000 },
    // New accounts across the whole server (device, Apple and email), and demo seeds for them.
    newAccounts: { limit: 300, windowMs: 3_600_000 },
    demoSeed: { limit: 20, windowMs: 3_600_000 },
    // A device account needs no proof of who asks, so one address gets few of them.
    deviceAuth: { limit: 5, windowMs: 3_600_000 },
    webhook: { limit: 120, windowMs: 60_000 },
    webhookVerified: { limit: 600, windowMs: 60_000 },
  },
};
