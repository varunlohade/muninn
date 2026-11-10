// Live end-to-end run: real jev, OpenRouter and PayPal sandbox. Uses the real DB file.
import { serve } from '@hono/node-server';
import { randomUUID } from 'node:crypto';
import type { AddressInfo } from 'node:net';
import { createApp } from '../src/app.ts';
import { createAi } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { createCipher, parseMasterKey, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { createPayPalProvider } from '../src/paypal.ts';

const env = process.env as Record<string, string>;
const db = openDb(config.dbPath);
const paypal = createPayPalProvider({ clientId: env.PAYPAL_CLIENT_ID, clientSecret: env.PAYPAL_CLIENT_SECRET });
const warm = performance.now();
await paypal.platform().warmUp();
console.log(`E2E warmup: ${JSON.stringify({ paypal_token_ms: Math.round(performance.now() - warm) })}`);
const app = createApp({
  db,
  cipher: createCipher(parseMasterKey(env.DATA_ENCRYPTION_KEY)),
  ai: createAi({ typesafeKey: env.TYPESAFE_API_KEY, openrouterKey: env.OPENROUTER_API_KEY }),
  paypal,
});
const server = serve({ fetch: app.fetch, port: 0, hostname: '127.0.0.1' });
await new Promise((r) => server.once('listening', r));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

const userId = db.createUser();
const token = randomToken('pkd');
db.addDevice(userId, sha256(token), 'e2e');

async function call(method: string, path: string, body?: unknown, extra: Record<string, string> = {}) {
  const t = performance.now();
  const res = await fetch(base + path, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...extra },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json();
  const ms = Math.round(performance.now() - t);
  if (!res.ok) throw new Error(`${method} ${path} -> ${res.status} ${JSON.stringify(json)}`);
  return { json, ms };
}
const step = (name: string, data: unknown) => console.log(`E2E ${name}: ${JSON.stringify(data)}`);

let failed = false;
try {
  await call('PUT', '/v1/profile', { business_name: 'Fresh Cuts', tone: 'warm, brief, uses first names', currency: 'USD' });
  await call('POST', '/v1/catalog', { name: 'Haircut', price: 45 });

  const text = "thanks! that'll be $45 for the haircut, sam@example.com";
  const s = await call('POST', '/v1/suggest', { text });
  step('suggest', { http_ms: s.ms, intent: s.json.intent, confidence: s.json.confidence, timings: s.json.timings, chips: s.json.chips.map((c: any) => c.label) });
  const chip = s.json.chips.find((c: any) => c.kind === 'invoice');
  if (!chip) throw new Error('no invoice chip');

  const inv = await call('POST', '/v1/actions/invoice', chip.payload, { 'X-User-Action': 'tap', 'Idempotency-Key': randomUUID() });
  step('invoice', { http_ms: inv.ms, id: inv.json.id, status: inv.json.status, pay_link: inv.json.pay_link, paypal_ms: inv.json.paypal_ms });

  const p = await call('GET', '/v1/payments?refresh=1');
  const row = p.json.payments.find((x: any) => x.id === inv.json.id);
  step('payments', { http_ms: p.ms, found: Boolean(row), state: row?.state, paypal_status: row?.paypal_status, amount: row?.amount, item: row?.item });
  if (row?.state !== 'unpaid') throw new Error('invoice not listed as unpaid');

  const sum = await call('GET', '/v1/summary');
  step('summary', sum.json);
  console.log(`E2E PASS user_id=${userId}`);
} catch (e) {
  failed = true;
  console.log(`E2E FAIL ${(e as Error).message}`);
} finally {
  server.close();
  process.exit(failed ? 1 : 0);
}
