import { serve } from '@hono/node-server';
import { createApp } from './app.ts';
import { createAi } from './ai.ts';
import { config } from './config.ts';
import { createCipher, parseMasterKey } from './crypto.ts';
import { openDb } from './db.ts';
import { log } from './log.ts';
import { createPayPalProvider } from './paypal.ts';
import { ensureDemoUser, seedDemo, todaySpecs } from './seed.ts';

function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

const db = openDb(config.dbPath);
const cipher = createCipher(parseMasterKey(process.env.DATA_ENCRYPTION_KEY));
const paypal = createPayPalProvider({ clientId: need('PAYPAL_CLIENT_ID'), clientSecret: need('PAYPAL_CLIENT_SECRET') });
const app = createApp({
  db,
  cipher,
  ai: createAi({ typesafeKey: need('TYPESAFE_API_KEY'), openrouterKey: need('OPENROUTER_API_KEY') }),
  paypal,
});

const warmStart = performance.now();
paypal.platform().warmUp().then(
  () => log('warmup', { paypal_token_ms: Math.round(performance.now() - warmStart) }),
  (e) => log('warmup_failed', { err: (e as Error).message }),
);

// DEMO_SEED=1 (sandbox only): seed the demo user once, then add today's paid invoices every hour.
// Each run is idempotent, so a restart or an hourly tick costs DB reads only once the day is seeded.
if (process.env.DEMO_SEED === '1' && config.paypal.sandbox) {
  const demo = ensureDemoUser(db);
  if (demo.token) {
    // Printed once, when the demo user is created. Only the hash is stored, so it cannot be shown again.
    console.log(`DEMO_DEVICE_TOKEN ${demo.token}  (shown once; give it to judges, then clear these logs if you like)`);
  }
  const pp = paypal.forUser(demo.userId);
  let running = false;
  const tick = async (full: boolean) => {
    if (running) return;
    running = true;
    try {
      const now = Date.now();
      const base = full ? await seedDemo({ db, cipher, paypal: pp, userId: demo.userId, now }) : null;
      const today = await seedDemo({ db, cipher, paypal: pp, userId: demo.userId, now, specs: todaySpecs(now) });
      log('demo_seed', { user_id: demo.userId, base, today });
    } catch (e) {
      log('demo_seed_failed', { err: (e as Error).message });
    } finally {
      running = false;
    }
  };
  void tick(true);
  setInterval(() => void tick(false), 60 * 60 * 1000);
}

serve({ fetch: app.fetch, port: config.port, hostname: process.env.HOST ?? '127.0.0.1' }, (info) => {
  log('listening', { port: info.port, paypal_sandbox: config.paypal.sandbox, webhooks_verifiable: Boolean(config.paypal.webhookId) });
});
