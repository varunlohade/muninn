const env = process.env;

export const INTENTS = ['create_invoice', 'pay_link', 'payment_status', 'send_reminder', 'refund', 'catalog_reply', 'none'] as const;
export type Intent = (typeof INTENTS)[number];

export const config = {
  port: Number(env.PORT ?? 8787),
  dbPath: env.DB_PATH ?? new URL('../data/pro-keyboard.db', import.meta.url).pathname,
  corsOrigins: (env.CORS_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean),
  bodyLimitBytes: 16 * 1024,
  maxTextChars: 2000,

  paypal: {
    sandbox: env.PAYPAL_ENV !== 'live',
    baseUrl: env.PAYPAL_ENV === 'live' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com',
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
    other: { limit: 120, windowMs: 60_000 },
    webhook: { limit: 120, windowMs: 60_000 },
  },
};
