import { serve } from '@hono/node-server';
import { createApp } from './app.ts';
import { createAi } from './ai.ts';
import { config } from './config.ts';
import { createCipher, parseMasterKey } from './crypto.ts';
import { openDb } from './db.ts';
import { log } from './log.ts';
import { createPayPalProvider } from './paypal.ts';

function need(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

const paypal = createPayPalProvider({ clientId: need('PAYPAL_CLIENT_ID'), clientSecret: need('PAYPAL_CLIENT_SECRET') });
const app = createApp({
  db: openDb(config.dbPath),
  cipher: createCipher(parseMasterKey(process.env.DATA_ENCRYPTION_KEY)),
  ai: createAi({ typesafeKey: need('TYPESAFE_API_KEY'), openrouterKey: need('OPENROUTER_API_KEY') }),
  paypal,
});

const warmStart = performance.now();
paypal.platform().warmUp().then(
  () => log('warmup', { paypal_token_ms: Math.round(performance.now() - warmStart) }),
  (e) => log('warmup_failed', { err: (e as Error).message }),
);

serve({ fetch: app.fetch, port: config.port, hostname: process.env.HOST ?? '127.0.0.1' }, (info) => {
  log('listening', { port: info.port, paypal_sandbox: config.paypal.sandbox, webhooks_verifiable: Boolean(config.paypal.webhookId) });
});
