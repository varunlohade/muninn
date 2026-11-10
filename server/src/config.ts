const env = process.env;

export const INTENTS = ['create_invoice', 'pay_link', 'payment_status', 'send_reminder', 'refund', 'catalog_reply', 'none'] as const;
export type Intent = (typeof INTENTS)[number];
export const TONES = ['professional', 'friendly', 'shorter', 'firmer'] as const;
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

  apple: {
    // The app bundle id. Apple puts it in the identity token as aud.
    audience: env.APPLE_BUNDLE_ID ?? 'com.orseliyas.muninn',
    issuer: 'https://appleid.apple.com',
    jwksUrl: 'https://appleid.apple.com/auth/keys',
    jwksTtlMs: 24 * 60 * 60 * 1000,
    jwksMinRefetchMs: 60_000,
    timeoutMs: 5000,
  },

  paypal: {
    sandbox: env.PAYPAL_ENV !== 'live',
    baseUrl: env.PAYPAL_ENV === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com',
    webUrl: env.PAYPAL_ENV === 'live' ? 'https://www.paypal.com' : 'https://www.sandbox.paypal.com',
    webhookId: env.PAYPAL_WEBHOOK_ID ?? '',
    timeoutMs: 15000,
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
    primary: { model: 'meta-llama/llama-3.3-70b-instruct', provider: { order: ['groq'], allow_fallbacks: true } },
    fallback: { model: 'google/gemini-2.5-flash' },
  },

  money: {
    maxAmount: 10000,
    currencies: ['USD', 'EUR', 'GBP', 'CAD', 'AUD'] as const,
    invoiceDueDays: 7,
    refundConfirmTtlMs: 2 * 60 * 1000,
  },

  rateLimit: {
    suggest: { limit: 60, windowMs: 60_000 },
    actions: { limit: 20, windowMs: 60_000 },
    write: { limit: 30, windowMs: 60_000 },
    other: { limit: 120, windowMs: 60_000 },
    auth: { limit: 10, windowMs: 60_000 },
    webhook: { limit: 120, windowMs: 60_000 },
    webhookVerified: { limit: 600, windowMs: 60_000 },
  },
};
