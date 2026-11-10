process.env.LOG_SILENT = '1';
import { randomBytes } from 'node:crypto';
import { createApp } from '../src/app.ts';
import type { AppleVerifier } from '../src/apple.ts';
import type { Ai, Classification, Extraction } from '../src/ai.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import type { PayPal, PayPalDispute, PayPalDisputeDetail, PayPalTxn } from '../src/paypal.ts';

export const sleep = (ms = 0) => new Promise((r) => setTimeout(r, ms));

export function setup(opts: { cls?: Partial<Classification>; ext?: Partial<Extraction>; verify?: boolean | ((h: Record<string, string | undefined>) => boolean); delayMs?: number; paypalDelayMs?: number; brief?: string | Error; now?: () => number; apple?: AppleVerifier; onNewUser?: (userId: string) => void } = {}) {
  const db = openDb(':memory:');
  const cipher = createCipher(randomBytes(32));
  const calls: { fn: string; args: unknown[] }[] = [];
  const aiCalls: { fn: string; args: unknown[] }[] = [];
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
    async searchTransactions() { return []; },
    async listDisputes() { return []; },
    async getDispute() { return null; },
    async sendDisputeMessage() {},
    async createDatedInvoice(...args) {
      calls.push({ fn: 'dated_invoice', args });
      return { id: `INV2-SEED-${++n}`, status: 'UNPAID', payLink: `https://paypal.test/inv/${n}`, dueDate: args[0].dueDate };
    },
    async recordPayment(...args) { calls.push({ fn: 'record_payment', args }); return { paymentId: `EXTR-${++n}` }; },
  };
  // PayPal data per user, standing in for each user's own connected merchant account.
  const ppData = new Map<string, { txns?: PayPalTxn[] | Error; disputes?: PayPalDisputeDetail[] }>();
  const forUser = (userId: string): PayPal => {
    const d = ppData.get(userId) ?? {};
    const list = (): PayPalDispute[] => (d.disputes ?? []).map(({ buyer_name, transaction_id, messages, ...x }) => x);
    return {
      ...pp,
      async searchTransactions(...args) {
        calls.push({ fn: 'search', args: [userId, ...args] });
        if (d.txns instanceof Error) throw d.txns;
        return d.txns ?? [];
      },
      async listDisputes() { calls.push({ fn: 'disputes', args: [userId] }); return list(); },
      async getDispute(id) { return d.disputes?.find((x) => x.id === id) ?? null; },
      async sendDisputeMessage(...args) { calls.push({ fn: 'dispute_message', args: [userId, ...args] }); },
    };
  };
  const ai: Ai = {
    async classify(text) { aiCalls.push({ fn: 'classify', args: [text] }); await sleep(opts.delayMs); return { intent: 'create_invoice', confidence: 0.92, ms: 5, ...opts.cls }; },
    async extract(text, catalog) { aiCalls.push({ fn: 'extract', args: [text, catalog] }); await sleep(opts.delayMs); return { client_name: 'Sam', client_email: 'sam@example.com', amount: 45, currency: null, item: 'haircut', ...opts.ext }; },
    async reply() { return 'Haircut is $45. Want a slot tomorrow?'; },
    async brief(facts) {
      aiCalls.push({ fn: 'brief', args: [facts] });
      if (opts.brief instanceof Error) throw opts.brief;
      return opts.brief ?? facts.split('\n').slice(0, 2).join('\n');
    },
  };
  const app = createApp({ db, cipher, ai, paypal: { forUser, platform: () => pp }, now: opts.now, apple: opts.apple, onNewUser: opts.onNewUser });
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
  return { db, cipher, app, calls, aiCalls, device, call, ppData, mockPayPal: pp };
}

export const webhookHeaders = {
  'paypal-auth-algo': 'SHA256withRSA', 'paypal-cert-url': 'https://api.sandbox.paypal.com/cert', 'paypal-transmission-id': 't1',
  'paypal-transmission-sig': 'sig', 'paypal-transmission-time': new Date().toISOString(),
};
export const paidEvent = (id: string) => ({
  event_type: 'INVOICING.INVOICE.PAID', resource: { invoice: { id, payments: { transactions: [{ payment_id: 'CAPX' }] } } },
});

