process.env.LOG_SILENT = '1';
import { randomBytes } from 'node:crypto';
import { createApp } from '../src/app.ts';
import type { AppleVerifier } from '../src/apple.ts';
import type { Ai, Classification, DeviceAction, Extraction, ToneCheck } from '../src/ai.ts';
import type { AskGroup, AskRoute } from '../src/config.ts';
import { createCipher, randomToken, sha256 } from '../src/crypto.ts';
import { openDb } from '../src/db.ts';
import { ExplanationSchema, SceneSchema } from '../src/explain.ts';
import logExplain from './fixtures/log-explain.json' with { type: 'json' };
import logScene from './fixtures/log-scene.json' with { type: 'json' };
import type { Balance, PayPal, PayPalDispute, PayPalDisputeDetail, PayPalPartner, PayPalTxn } from '../src/paypal.ts';

export const sleep = (ms = 0) => new Promise((r) => setTimeout(r, ms));

export function setup(opts: { cls?: Partial<Classification>; ext?: Partial<Extraction> | ((text: string, catalog: string, business: string) => Partial<Extraction>); group?: { group?: AskGroup; confidence?: number } | Error; route?: { route?: AskRoute; confidence?: number }; device?: { kind?: DeviceAction; confidence?: number } | Error; verify?: boolean | ((h: Record<string, string | undefined>) => boolean); delayMs?: number; paypalDelayMs?: number; brief?: string | Error; write?: string | Error; tone?: ToneCheck; explain?: unknown; visual?: unknown; now?: () => number; apple?: AppleVerifier; onNewUser?: (userId: string) => void; partner?: PayPalPartner } = {}) {
  const db = openDb(':memory:');
  const cipher = createCipher(randomBytes(32));
  const calls: { fn: string; args: unknown[] }[] = [];
  const aiCalls: { fn: string; args: unknown[] }[] = [];
  let n = 0;
  // What PayPal says each subscription is now. Unset means ACTIVE.
  const subStatus = new Map<string, string>();
  // What the balance read answers: the balances, or an error such as a sandbox that refuses it.
  const balance: { reply: Balance[] | Error } = { reply: [{ currency: 'USD', available: '1240.50', primary: true }] };
  // Each payout batch's one item. A test sets status to SUCCESS to play a recipient who already claimed it.
  const payoutItems = new Map<string, { itemId: string; status: string }>();
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
    async createSubscription(...args) {
      calls.push({ fn: 'subscribe', args });
      const [i] = args;
      await sleep(opts.paypalDelayMs);
      const k = ++n;
      return { id: `I-TEST${k}`, status: 'APPROVAL_PENDING', approveLink: `https://paypal.test/sub/${k}`, productId: i.productId ?? `PROD-TEST-${k}`, planId: i.planId ?? `P-TEST-${k}` };
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
    async getSubscription(id) { calls.push({ fn: 'get_subscription', args: [id] }); return { status: subStatus.get(id) ?? 'ACTIVE', nextBillingAt: '2026-12-01T10:00:00Z', lastPaidAt: null }; },
    async changeSubscription(...args) {
      calls.push({ fn: 'change_subscription', args });
      subStatus.set(args[0], { suspend: 'SUSPENDED', activate: 'ACTIVE', cancel: 'CANCELLED' }[args[1]]);
    },
    async deleteRecordedPayment(...args) { calls.push({ fn: 'delete_payment', args }); },
    async cancelInvoice(...args) { calls.push({ fn: 'cancel_invoice', args }); },
    async recordRefund(...args) { calls.push({ fn: 'record_refund', args }); return { refundId: `RFX-${++n}` }; },
    async createPayout(...args) {
      calls.push({ fn: 'payout', args });
      await sleep(opts.paypalDelayMs);
      const batchId = `BATCH-${++n}`;
      payoutItems.set(batchId, { itemId: `ITEM-${n}`, status: 'UNCLAIMED' });
      return { batchId, status: 'PENDING' };
    },
    async getPayoutItem(batchId) { calls.push({ fn: 'payout_item', args: [batchId] }); return payoutItems.get(batchId) ?? null; },
    async cancelPayoutItem(...args) {
      calls.push({ fn: 'payout_cancel', args });
      for (const it of payoutItems.values()) if (it.itemId === args[0]) it.status = 'RETURNED';
      return { status: 'RETURNED' };
    },
    async acceptClaim() {},
    async makeOffer() {},
    async getBalances() {
      calls.push({ fn: 'balances', args: [] });
      if (balance.reply instanceof Error) throw balance.reply;
      return balance.reply;
    },
  };
  // PayPal data per user, standing in for each user's own connected merchant account.
  const ppData = new Map<string, { txns?: PayPalTxn[] | Error; disputes?: PayPalDisputeDetail[] | Error }>();
  const forUser = (userId: string): PayPal => {
    const d = ppData.get(userId) ?? {};
    const all = (): PayPalDisputeDetail[] => {
      if (d.disputes instanceof Error) throw d.disputes;
      return d.disputes ?? [];
    };
    const list = (): PayPalDispute[] => all().map(({ buyer_name, transaction_id, messages, ...x }) => x);
    return {
      ...pp,
      async searchTransactions(...args) {
        calls.push({ fn: 'search', args: [userId, ...args] });
        if (d.txns instanceof Error) throw d.txns;
        return d.txns ?? [];
      },
      async listDisputes() { calls.push({ fn: 'disputes', args: [userId] }); return list(); },
      async getDispute(id) { calls.push({ fn: 'dispute_detail', args: [userId, id] }); return all().find((x) => x.id === id) ?? null; },
      async sendDisputeMessage(...args) { calls.push({ fn: 'dispute_message', args: [userId, ...args] }); },
      async acceptClaim(...args) { calls.push({ fn: 'accept_claim', args: [userId, ...args] }); },
      async makeOffer(...args) { calls.push({ fn: 'make_offer', args: [userId, ...args] }); },
    };
  };
  const rewrite = (text: string) => {
    if (opts.write instanceof Error) throw opts.write;
    return opts.write ?? text;
  };
  const model = (v: unknown, fallback: unknown) => {
    if (v instanceof Error) throw v;
    return v ?? fallback;
  };
  const ai: Ai = {
    async classify(...args) { aiCalls.push({ fn: 'classify', args }); await sleep(opts.delayMs); return { intent: 'create_invoice', confidence: 0.92, ms: 5, ...opts.cls }; },
    async extract(text, catalog, business = '') {
      aiCalls.push({ fn: 'extract', args: [text, catalog, business] });
      await sleep(opts.delayMs);
      return { client_name: 'Sam', client_email: 'sam@example.com', amount: 45, currency: null, item: 'haircut', ...(typeof opts.ext === 'function' ? opts.ext(text, catalog, business) : opts.ext) };
    },
    async askGroup(text) {
      aiCalls.push({ fn: 'askGroup', args: [text] });
      if (opts.group instanceof Error) throw opts.group;
      return { group: 'money', confidence: 0.92, ...opts.group };
    },
    async deviceAction(text) {
      aiCalls.push({ fn: 'deviceAction', args: [text] });
      if (opts.device instanceof Error) throw opts.device;
      return { kind: 'none', confidence: 0.92, ...opts.device };
    },
    async askRoute(text, group) { aiCalls.push({ fn: 'askRoute', args: [text, group] }); return { route: 'invoice', confidence: 0.92, ...opts.route }; },
    async reply(...args) { aiCalls.push({ fn: 'reply', args }); return 'Happy to help. Want a slot tomorrow?'; },
    async brief(facts) {
      aiCalls.push({ fn: 'brief', args: [facts] });
      if (opts.brief instanceof Error) throw opts.brief;
      return opts.brief ?? facts.split('\n').slice(0, 2).join('\n');
    },
    async fix(...args) { aiCalls.push({ fn: 'fix', args }); return rewrite(args[0]); },
    async refine(...args) { aiCalls.push({ fn: 'refine', args }); return rewrite(args[0]); },
    async toneCheck(...args) { aiCalls.push({ fn: 'toneCheck', args }); return opts.tone ?? { tone: 'ok', calm: null }; },
    // explain and visual take the model's raw JSON (an Error to fail) and pass it through the real schemas, as createAi does.
    async explain(...args) { aiCalls.push({ fn: 'explain', args }); return ExplanationSchema.parse(model(opts.explain, logExplain)); },
    async visual(...args) { aiCalls.push({ fn: 'visual', args }); return SceneSchema.parse(model(opts.visual, logScene)); },
  };
  // Each forAccount call: which account an action on an existing object ran on.
  const accounts: { userId: string; account: string | null }[] = [];
  const app = createApp({ db, cipher, ai, paypal: { forUser, forAccount: (userId, account) => { accounts.push({ userId, account }); return forUser(userId); }, platform: () => pp, partner: () => opts.partner ?? noPartner }, now: opts.now, apple: opts.apple, onNewUser: opts.onNewUser });
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
        ...(path.startsWith('/v1/write') || path === '/v1/ask' ? { 'X-User-Action': 'tap' } : {}),
        ...(path.startsWith('/v1/actions') ? { 'X-User-Action': 'tap', 'Idempotency-Key': `key-${Date.now()}-${++k}` } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  return { db, cipher, app, calls, aiCalls, device, call, ppData, mockPayPal: pp, subStatus, balance, payoutItems, accounts };
}

const noPartner: PayPalPartner = {
  async createReferral() { throw new Error('no partner mock'); },
  async merchantStatus() { return null; },
  async merchantIdForTracking() { return null; },
};

export const webhookHeaders = {
  'paypal-auth-algo': 'SHA256withRSA', 'paypal-cert-url': 'https://api.sandbox.paypal.com/cert', 'paypal-transmission-id': 't1',
  'paypal-transmission-sig': 'sig', 'paypal-transmission-time': new Date().toISOString(),
};
export const subscriptionPaidEvent = (subscriptionId: string, saleId: string) => ({
  event_type: 'PAYMENT.SALE.COMPLETED', resource: { id: saleId, billing_agreement_id: subscriptionId, state: 'completed', amount: { total: '40.00', currency: 'USD' } },
});
export const paidEvent = (id: string) => ({
  event_type: 'INVOICING.INVOICE.PAID', resource: { invoice: { id, payments: { transactions: [{ payment_id: 'CAPX' }] } } },
});

