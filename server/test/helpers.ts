process.env.LOG_SILENT = '1';
import { randomBytes } from 'node:crypto';
import { createApp } from '../src/app.ts';
import type { Ai, Classification, Extraction } from '../src/ai.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import type { PayPal } from '../src/paypal.ts';

export const sleep = (ms = 0) => new Promise((r) => setTimeout(r, ms));

export function setup(opts: { cls?: Partial<Classification>; ext?: Partial<Extraction>; verify?: boolean | ((h: Record<string, string | undefined>) => boolean); delayMs?: number; paypalDelayMs?: number } = {}) {
  const db = openDb(':memory:');
  const cipher = createCipher(randomBytes(32));
  const calls: { fn: string; args: unknown[] }[] = [];
  let n = 0;
  const pp: PayPal = {
    async createAndSendInvoice(...args) {
      calls.push({ fn: 'invoice', args });
      await sleep(opts.paypalDelayMs);
      return { id: `INV2-TEST-${++n}`, status: 'SENT', payLink: `https://paypal.test/inv/${n}` };
    },
    async createOrder(...args) {
      calls.push({ fn: 'order', args });
      return { id: `ORDER${++n}`, status: 'CREATED', approveLink: `https://paypal.test/approve/${n}` };
    },
    async getInvoice() { return { status: 'SENT', captureId: null }; },
    async remind(...args) { calls.push({ fn: 'remind', args }); },
    async captureOrder() { return { status: 'COMPLETED', captureId: 'CAP1' }; },
    async refundCapture(...args) { calls.push({ fn: 'refund', args }); await sleep(opts.paypalDelayMs); return { id: 'REF1', status: 'COMPLETED' }; },
    async verifyWebhook(h) { return typeof opts.verify === 'function' ? opts.verify(h) : opts.verify ?? true; },
    async warmUp() {},
  };
  const ai: Ai = {
    async classify() { await sleep(opts.delayMs); return { intent: 'create_invoice', confidence: 0.92, ms: 5, ...opts.cls }; },
    async extract() { await sleep(opts.delayMs); return { client_name: 'Sam', client_email: 'sam@example.com', amount: 45, currency: null, item: 'haircut', ...opts.ext }; },
    async reply() { return 'Haircut is $45. Want a slot tomorrow?'; },
  };
  const app = createApp({ db, cipher, ai, paypal: { forUser: () => pp, platform: () => pp } });
  const device = () => {
    const userId = db.createUser();
    const token = randomToken('pkd');
    db.addDevice(userId, sha256(token), 'test');
    return { userId, token };
  };
  let k = 0;
  const call = (token: string | null, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) =>
    app.request(path, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(path.startsWith('/v1/actions') ? { 'X-User-Action': 'tap', 'Idempotency-Key': `key-${Date.now()}-${++k}` } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  return { db, cipher, app, calls, device, call };
}

export const webhookHeaders = {
  'paypal-auth-algo': 'SHA256withRSA', 'paypal-cert-url': 'https://api.sandbox.paypal.com/cert', 'paypal-transmission-id': 't1',
  'paypal-transmission-sig': 'sig', 'paypal-transmission-time': new Date().toISOString(),
};
export const paidEvent = (id: string) => ({
  event_type: 'INVOICING.INVOICE.PAID', resource: { invoice: { id, payments: { transactions: [{ payment_id: 'CAPX' }] } } },
});

