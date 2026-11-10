// Seeds the "Muninn" demo user with real sandbox PayPal invoices. Safe to re-run.
// usage: npm run seed:demo -- [user_id] [--show]
import { writeFileSync } from 'node:fs';
import { createApp } from '../src/app.ts';
import { createAi } from '../src/ai.ts';
import { config } from '../src/config.ts';
import { createCipher, parseMasterKey, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { createPayPalProvider } from '../src/paypal.ts';
import { DEMO_LABEL, seedDemo, todaySpecs } from '../src/seed.ts';

const env = process.env as Record<string, string>;
if (!config.paypal.sandbox) throw new Error('seed:demo runs against the PayPal sandbox only');
const args = process.argv.slice(2);
const show = args.includes('--show');
const refreshToday = args.includes('--refresh-today');
const userArg = args.find((a) => !a.startsWith('--'));

const db = openDb(config.dbPath);
const cipher = createCipher(parseMasterKey(env.DATA_ENCRYPTION_KEY));
const paypal = createPayPalProvider({ clientId: env.PAYPAL_CLIENT_ID, clientSecret: env.PAYPAL_CLIENT_SECRET });

let userId = userArg ?? db.userForDeviceLabel(DEMO_LABEL);
if (!userId) {
  userId = db.createUser();
  const token = randomToken('pkd');
  db.addDevice(userId, sha256(token), DEMO_LABEL);
  // Written once to the git-ignored data dir, never printed. Re-runs reuse the user; `npm run device -- <user_id>` makes another token.
  const file = new URL('../data/demo-device.json', import.meta.url).pathname;
  writeFileSync(file, JSON.stringify({ user_id: userId, device_token: token }) + '\n', { mode: 0o600 });
  console.log(`SEED demo device token written to ${file}`);
}
try {
  const now = Date.now();
  const base = { db, cipher, paypal: paypal.forUser(userId), userId, now };
  console.log(`SEED ${JSON.stringify({ user_id: userId, ...(await seedDemo(base)) })}`);
  if (refreshToday) console.log(`SEED today ${JSON.stringify(await seedDemo({ ...base, specs: todaySpecs(now) }))}`);
} catch (e) {
  // PayPal errors carry the HTTP status, error name and first issue; no secrets.
  console.error(`SEED FAIL ${(e as Error).message}`);
  process.exit(1);
}

if (show) {
  const app = createApp({ db, cipher, ai: createAi({ typesafeKey: env.TYPESAFE_API_KEY, openrouterKey: env.OPENROUTER_API_KEY }), paypal });
  const token = randomToken('pkd');
  db.addDevice(userId, sha256(token), 'seed-show');
  try {
    for (const path of ['/v1/summary', '/v1/brief', '/v1/clients']) {
      const r = await app.request(path, { headers: { Authorization: `Bearer ${token}` } });
      console.log(`SEED ${path}: ${JSON.stringify(await r.json())}`);
    }
  } finally {
    db.removeDevice(sha256(token));
  }
}
