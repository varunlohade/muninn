// Sets up the PayPal SANDBOX state the recorded demo needs, on the demo user only (device label 'muninn-demo'). Safe to re-run.
// usage: node --env-file=../.env scripts/demo-paypal-shots.ts [--dry-run]
// --dry-run prints what it would do and writes nothing (no PayPal call, no database write).
import { config } from '../src/config.ts';
import { createCipher, parseMasterKey } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { createPayPalProvider } from '../src/paypal.ts';
import { DEMO_LABEL, demoShots } from '../src/seed.ts';

const env = process.env as Record<string, string>;
if (!config.paypal.sandbox) throw new Error('demo-paypal-shots runs against the PayPal sandbox only');
const dryRun = process.argv.includes('--dry-run');
const db = openDb(config.dbPath);
const userId = db.userForDeviceLabel(DEMO_LABEL);
if (!userId) throw new Error('no demo user yet: run seed:demo first');
const cipher = createCipher(parseMasterKey(env.DATA_ENCRYPTION_KEY));
const paypal = createPayPalProvider({ clientId: env.PAYPAL_CLIENT_ID, clientSecret: env.PAYPAL_CLIENT_SECRET }).forUser(userId);
try {
  for (const line of await demoShots({ db, cipher, paypal, userId, now: Date.now(), dryRun })) console.log(`SHOTS ${line}`);
} catch (e) {
  console.error(`SHOTS FAIL ${(e as Error).message}`);
  process.exit(1);
}
