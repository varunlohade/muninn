import { PayPalAgentToolkit } from '@paypal/agent-toolkit/ai-sdk';
import { config, type Interval } from './config.ts';

export type InvoiceInput = {
  value: string; currency: string; item: string; clientName: string | null; clientEmail: string | null; businessName: string | null;
};
export type PayPal = {
  createAndSendInvoice(i: InvoiceInput, requestId: string): Promise<{ id: string; status: string; payLink: string | null }>;
  createOrder(i: { value: string; currency: string; item: string }, requestId: string): Promise<{ id: string; status: string; approveLink: string | null }>;
  createSubscription(i: SubscriptionInput, requestId: string): Promise<SubscriptionCreated>;
  getInvoice(id: string): Promise<{ status: string; captureId: string | null }>;
  remind(id: string, requestId: string): Promise<void>;
  captureOrder(id: string, requestId: string): Promise<{ status: string; captureId: string | null }>;
  refundCapture(captureId: string, value: string, currency: string, requestId: string): Promise<{ id: string; status: string }>;
  verifyWebhook(headers: Record<string, string | undefined>, event: unknown): Promise<boolean>;
  searchTransactions(start: Date, end: Date): Promise<PayPalTxn[]>;
  listDisputes(): Promise<PayPalDispute[]>;
  getDispute(id: string): Promise<PayPalDisputeDetail | null>;
  sendDisputeMessage(id: string, message: string, requestId: string): Promise<void>;
  createDatedInvoice(i: DatedInvoiceInput, requestId: string): Promise<{ id: string; status: string; payLink: string; dueDate: string }>;
  recordPayment(id: string, p: { date: string; value: string; currency: string; method: string; note: string }, requestId: string): Promise<{ paymentId: string }>;
  warmUp(): Promise<void>;
  getSubscription(id: string): Promise<SubscriptionState>;
  /** suspend = pause, activate = resume, cancel = end for good. */
  changeSubscription(id: string, to: 'suspend' | 'activate' | 'cancel', reason: string, requestId: string): Promise<void>;
  /** Takes back a payment recordPayment made. `paymentId` is what recordPayment returned. */
  deleteRecordedPayment(invoiceId: string, paymentId: string, requestId: string): Promise<void>;
  /** `notify`: PayPal emails the client that the invoice is cancelled. */
  cancelInvoice(id: string, notify: boolean, requestId: string): Promise<void>;
  /** Notes a refund that happened outside PayPal. No money moves. */
  recordRefund(id: string, r: { date: string; value: string; currency: string; method: string }, requestId: string): Promise<{ refundId: string }>;
  /** Every currency the account holds. Read-only. */
  getBalances(): Promise<Balance[]>;
  /** Sends money to one email or phone number. MONEY: the caller confirms recipient, amount and currency first. */
  createPayout(p: { email?: string; phone?: string; value: string; currency: string; note: string }, requestId: string): Promise<{ batchId: string; status: string }>;
  /** The one item of a payout batch, or null while PayPal has not made it yet. */
  getPayoutItem(batchId: string): Promise<{ itemId: string; status: string } | null>;
  /** Only an UNCLAIMED item can be cancelled; the money goes back to the sender. */
  cancelPayoutItem(itemId: string, requestId: string): Promise<{ status: string }>;
  /** Gives the buyer the full disputed amount back and closes the dispute. MONEY. */
  acceptClaim(id: string, note: string, requestId: string): Promise<void>;
  /** Offers the buyer a refund to close the dispute. The buyer accepts or not. */
  makeOffer(id: string, o: { note: string; value: string; currency: string }, requestId: string): Promise<void>;
};
export type Balance = { currency: string; available: string; primary: boolean };
export type SubscriptionState = { status: string; nextBillingAt: string | null; lastPaidAt: string | null };
// Explicit dates and a reference tag; sent without emailing the recipient. Used by the demo seed.
// invoiceNumber is unique per merchant, so a re-run finds the invoice a crashed run left behind instead of making a second one.
export type DatedInvoiceInput = InvoiceInput & { invoiceDate: string; dueDate: string; reference: string; invoiceNumber: string };
export type Money = { value: string; currency: string };
// productId / planId: the ones made before for this user and this amount, interval and currency, or null to make new ones.
export type SubscriptionInput = {
  value: string; currency: string; interval: Interval; clientEmail: string | null;
  productId: string | null; planId: string | null; productRequestId: string; planRequestId: string;
};
export type SubscriptionCreated = { id: string; status: string; approveLink: string; productId: string; planId: string };
export type PayPalTxn = {
  id: string; event_code: string; date: string; status: string; amount: Money; fee: Money | null;
  payer_name: string | null; payer_email: string | null; invoice_id: string | null; subject: string | null;
};
export type PayPalDispute = { id: string; status: string; reason: string; amount: Money | null; due_date: string | null; created_at: string; stage: string | null };
export type PayPalDisputeDetail = PayPalDispute & {
  buyer_name: string | null; transaction_id: string | null;
  messages: { posted_by: string; time: string; content: string }[];
};
export type PayPalProvider = {
  /** The user's current account: their connected PayPal, or the shared demo merchant. Use it to make new objects. */
  forUser(userId: string): PayPal;
  /**
   * The account that made an object: null is the demo merchant, otherwise the seller's account key.
   * An object stays on the account that made it, so old demo invoices keep working after the owner connects.
   */
  forAccount(userId: string, account: string | null): PayPal;
  platform(): PayPal;
  partner(): PayPalPartner;
};
// A connected seller: money calls run on the platform's credentials for this merchant, through PayPal-Auth-Assertion.
// account: a keyed hash of the merchant id, stored on each row the seller's account made.
export type Seller = { merchantId: string; email: string | null; account: string };
export type MerchantStatus = {
  merchantId: string; trackingId: string | null; paymentsReceivable: boolean; emailConfirmed: boolean;
  primaryEmail: string | null; permissionsGranted: boolean;
  /** The seller's legal business name, when PayPal returns one. */
  legalName?: string | null;
  /** The seller's primary currency (ISO 4217), when PayPal returns one. */
  currency?: string | null;
};
// Partner Referrals v2 and the merchant-integrations lookups, always on the platform's own credentials.
export type PayPalPartner = {
  createReferral(trackingId: string, returnUrl: string): Promise<{ actionUrl: string }>;
  merchantStatus(merchantId: string): Promise<MerchantStatus | null>;
  merchantIdForTracking(trackingId: string): Promise<string | null>;
};
// The features this partner app may ask for today, in one referral, so the seller consents once.
// PayPal answers 422 FEATURES_UNAUTHORIZED for the whole referral if one feature is not granted to the partner.
// Checked on sandbox 2026-11-12: INVOICE_READ_WRITE, PAYOUTS and TRACKING_SHIPMENT_READWRITE are not granted yet.
// Add them back once PayPal approves them for this partner.
export const PARTNER_FEATURES = [
  'PAYMENT', 'REFUND', 'ADVANCED_TRANSACTIONS_SEARCH', 'READ_SELLER_DISPUTE', 'UPDATE_SELLER_DISPUTE',
  'ACCESS_MERCHANT_INFORMATION', 'PAYPAL_BALANCE', 'BILLING_AGREEMENT',
] as const;

export class PayPalError extends Error {
  status: number;
  upstream: number | null;
  constructor(message: string, status: number, upstream: number | null = null) {
    super(message);
    this.status = status;
    this.upstream = upstream;
  }
}

type Creds = { clientId: string; clientSecret: string };

// Unsigned, as PayPal's partner docs show: base64 header and payload, an empty signature.
export function authAssertion(clientId: string, merchantId: string): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64');
  return `${b64({ alg: 'none' })}.${b64({ iss: clientId, payer_id: merchantId })}.`;
}

function createTokenSource(creds: Creds) {
  let token: { value: string; exp: number } | null = null;
  let tokenInFlight: Promise<string> | null = null;

  async function fetchToken(): Promise<string> {
    const res = await fetch(`${config.paypal.baseUrl}/v1/oauth2/token`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${Buffer.from(`${creds.clientId}:${creds.clientSecret}`).toString('base64')}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: 'grant_type=client_credentials',
      signal: AbortSignal.timeout(config.paypal.timeoutMs),
    });
    if (!res.ok) throw new PayPalError(`PayPal auth failed (${res.status})`, 502);
    const j = (await res.json()) as { access_token: string; expires_in: number };
    token = { value: j.access_token, exp: Date.now() + (j.expires_in - 60) * 1000 };
    return token.value;
  }

  return async function accessToken(): Promise<string> {
    if (token && token.exp > Date.now()) return token.value;
    tokenInFlight ??= fetchToken().finally(() => { tokenInFlight = null; });
    return tokenInFlight;
  };
}

function createRest(creds: Creds, accessToken: () => Promise<string>, seller: Seller | null) {
  return async function rest(method: string, path: string, body?: unknown, requestId?: string): Promise<any> {
    const headers: Record<string, string> = { Authorization: `Bearer ${await accessToken()}`, 'Content-Type': 'application/json' };
    if (requestId) headers['PayPal-Request-Id'] = requestId;
    if (seller) headers['PayPal-Auth-Assertion'] = authAssertion(creds.clientId, seller.merchantId);
    if (config.paypal.bnCode) headers['PayPal-Partner-Attribution-Id'] = config.paypal.bnCode;
    if (method !== 'GET') headers.Prefer = 'return=representation';
    const res = await fetch(`${config.paypal.baseUrl}${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(config.paypal.timeoutMs),
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : {};
    if (!res.ok) throw new PayPalError(`PayPal ${method} ${path.split('/').slice(0, 4).join('/')} failed (${res.status}): ${data?.name ?? ''} ${data?.details?.[0]?.issue ?? ''}`.trim(), 502, res.status);
    return data;
  };
}

// The Agent Toolkit sends no PayPal-Auth-Assertion, so it runs the demo merchant's invoices; a connected seller's go through rest.
function createClient(creds: Creds, accessToken: () => Promise<string>, seller: Seller | null): PayPal {
  const rest = createRest(creds, accessToken, seller);

  // One toolkit per PayPal client. The toolkit keeps its own token forever and takes the request id
  // from its context, so each call gets our cached token and its own PayPal-Request-Id. Calls run one at a time.
  const toolkit = seller ? null : new PayPalAgentToolkit({
    clientId: creds.clientId,
    clientSecret: creds.clientSecret,
    configuration: {
      actions: { invoices: { create: true, send: true, sendReminder: true } },
      context: { sandbox: config.paypal.sandbox },
    },
  });
  const tkClient = toolkit?.client as unknown as { _accessToken?: string; _context: Record<string, unknown> };
  const tools = toolkit?.getTools() ?? {};
  let queue: Promise<unknown> = Promise.resolve();

  async function toolkitCall(tool: string, args: Record<string, unknown>, requestId: string): Promise<any> {
    const t = tools[tool];
    if (!t?.execute) throw new PayPalError(`toolkit tool ${tool} missing`, 500);
    const run = async () => {
      tkClient._accessToken = await accessToken();
      tkClient._context.request_id = requestId;
      try {
        return await t.execute!(args, { toolCallId: requestId, messages: [] });
      } finally {
        delete tkClient._context.request_id;
      }
    };
    const p = queue.then(run, run);
    queue = p.catch(() => undefined);
    const out = await p;
    const data = typeof out === 'string' ? (out ? JSON.parse(out) : {}) : out;
    if (data?.error || data?.code === 'PAYPAL_API_HTTP_ERROR') {
      throw new PayPalError(`PayPal toolkit ${tool} failed: ${String(data?.error?.message ?? data?.message ?? 'error').slice(0, 200)}`, 502);
    }
    return data ?? {};
  }

  const link = (links: { rel: string; href: string }[] | undefined, rel: string) => links?.find((l) => l.rel === rel)?.href ?? null;

  const money = (m: { value?: string; currency_code?: string } | undefined): Money | null =>
    m?.value && m.currency_code ? { value: m.value, currency: m.currency_code } : null;
  const dispute = (d: any): PayPalDispute => ({
    id: String(d.dispute_id), status: String(d.status ?? 'UNKNOWN'), reason: String(d.reason ?? 'UNKNOWN'),
    amount: money(d.dispute_amount), due_date: d.seller_response_due_date ?? null, created_at: String(d.create_time ?? ''),
    stage: d.dispute_life_cycle_stage ?? null,
  });

  // The invoice the toolkit makes, with the seller as invoicer. PayPal's partner invoicing guide sets the seller's primary email there.
  async function sellerInvoice(i: InvoiceInput, requestId: string) {
    const recipient = i.clientName || i.clientEmail
      ? [{ billing_info: { ...(i.clientName ? { name: { given_name: i.clientName } } : {}), ...(i.clientEmail ? { email_address: i.clientEmail } : {}) } }]
      : undefined;
    const invoicer = { ...(i.businessName ? { business_name: i.businessName } : {}), ...(seller?.email ? { email_address: seller.email } : {}) };
    const created = await rest('POST', '/v2/invoicing/invoices', {
      detail: { currency_code: i.currency },
      ...(Object.keys(invoicer).length ? { invoicer } : {}),
      ...(recipient ? { primary_recipients: recipient } : {}),
      items: [{ name: i.item, quantity: '1', unit_amount: { currency_code: i.currency, value: i.value } }],
    }, `${requestId}-create`);
    const id: string | undefined = created.id ?? String(created.href ?? '').split('/').pop();
    if (!id || !/^INV2-[A-Z0-9-]+$/.test(id)) throw new PayPalError('PayPal returned no invoice id', 502);
    const sent = await rest('POST', `/v2/invoicing/invoices/${id}/send`, { send_to_recipient: Boolean(i.clientEmail) }, `${requestId}-send`);
    const payLink = typeof sent?.href === 'string' && sent.rel === 'payer-view' ? sent.href : `${config.paypal.webUrl}/invoice/p/#${id}`;
    return { id, status: 'SENT', payLink };
  }

  async function getInvoiceRaw(id: string) {
    return rest('GET', `/v2/invoicing/invoices/${encodeURIComponent(id)}`);
  }

  return {
    async createAndSendInvoice(i, requestId) {
      if (seller) return sellerInvoice(i, requestId);
      const recipient = i.clientName || i.clientEmail
        ? [{ billing_info: { ...(i.clientName ? { name: { given_name: i.clientName } } : {}), ...(i.clientEmail ? { email_address: i.clientEmail } : {}) } }]
        : undefined;
      const created = await toolkitCall('create_invoice', {
        currency_code: i.currency,
        ...(i.businessName ? { invoicer_business_name: i.businessName } : {}),
        ...(recipient ? { primary_recipients: recipient } : {}),
        items: [{ name: i.item, quantity: '1', unit_amount: { currency_code: i.currency, value: i.value } }],
      }, `${requestId}-create`);
      const id: string | undefined = created.id ?? String(created.href ?? '').split('/').pop();
      if (!id || !/^INV2-[A-Z0-9-]+$/.test(id)) throw new PayPalError('PayPal returned no invoice id', 502);
      const sent = await toolkitCall('send_invoice', { invoice_id: id, send_to_recipient: Boolean(i.clientEmail) }, `${requestId}-send`);
      const payLink = typeof sent?.href === 'string' && sent.rel === 'payer-view' ? sent.href : `${config.paypal.webUrl}/invoice/p/#${id}`;
      return { id, status: 'SENT', payLink };
    },

    async createOrder(i, requestId) {
      const o = await rest('POST', '/v2/checkout/orders', {
        intent: 'CAPTURE',
        purchase_units: [{
          description: i.item.slice(0, 127),
          amount: { currency_code: i.currency, value: i.value, breakdown: { item_total: { currency_code: i.currency, value: i.value } } },
          items: [{ name: i.item.slice(0, 127), quantity: '1', unit_amount: { currency_code: i.currency, value: i.value } }],
        }],
      }, requestId);
      return { id: o.id, status: o.status, approveLink: link(o.links, 'approve') ?? link(o.links, 'payer-action') };
    },

    async createSubscription(i, requestId) {
      const productId: string = i.productId ?? (await rest('POST', '/v1/catalogs/products', { name: 'Muninn services', type: 'SERVICE' }, i.productRequestId)).id;
      const planId: string = i.planId ?? (await rest('POST', '/v1/billing/plans', {
        product_id: productId, name: `${i.currency} ${i.value} every ${i.interval}`, status: 'ACTIVE',
        billing_cycles: [{
          frequency: { interval_unit: i.interval.toUpperCase(), interval_count: 1 }, tenure_type: 'REGULAR', sequence: 1, total_cycles: 0,
          pricing_scheme: { fixed_price: { value: i.value, currency_code: i.currency } },
        }],
        payment_preferences: { auto_bill_outstanding: true, payment_failure_threshold: 1 },
      }, i.planRequestId)).id;
      const sub = await rest('POST', '/v1/billing/subscriptions', {
        plan_id: planId, ...(i.clientEmail ? { subscriber: { email_address: i.clientEmail } } : {}),
      }, requestId);
      const approveLink = link(sub.links, 'approve');
      if (!/^I-[A-Z0-9]+$/.test(sub?.id ?? '') || !approveLink) throw new PayPalError('PayPal returned no subscription approve link', 502);
      return { id: sub.id, status: String(sub.status ?? 'APPROVAL_PENDING'), approveLink, productId, planId };
    },

    async getInvoice(id) {
      const inv = await getInvoiceRaw(id);
      const tx = inv?.payments?.transactions?.[0];
      return { status: String(inv?.status ?? 'UNKNOWN'), captureId: tx?.payment_id ?? null };
    },

    async remind(id, requestId) {
      if (seller) {
        await rest('POST', `/v2/invoicing/invoices/${encodeURIComponent(id)}/remind`, {}, requestId);
        return;
      }
      await toolkitCall('send_invoice_reminder', { invoice_id: id }, requestId);
    },

    async captureOrder(id, requestId) {
      const o = await rest('POST', `/v2/checkout/orders/${encodeURIComponent(id)}/capture`, {}, requestId);
      return { status: o.status, captureId: o?.purchase_units?.[0]?.payments?.captures?.[0]?.id ?? null };
    },

    async refundCapture(captureId, value, currency, requestId) {
      const r = await rest('POST', `/v2/payments/captures/${encodeURIComponent(captureId)}/refund`,
        { amount: { value, currency_code: currency } }, requestId);
      return { id: r.id, status: r.status };
    },

    async warmUp() {
      await accessToken();
    },

    // Transaction Search allows at most 31 days per query and 500 rows per page.
    async searchTransactions(start, end) {
      const out: PayPalTxn[] = [];
      const iso = (d: Date) => `${d.toISOString().slice(0, 19)}Z`;
      for (let page = 1, pages = 1; page <= pages && page <= 5; page++) {
        const qs = new URLSearchParams({
          start_date: iso(start), end_date: iso(end), fields: 'transaction_info,payer_info', page_size: '500', page: String(page),
        });
        const r = await rest('GET', `/v1/reporting/transactions?${qs}`);
        pages = Number(r?.total_pages ?? 1);
        for (const t of r?.transaction_details ?? []) {
          const ti = t.transaction_info ?? {};
          const pi = t.payer_info ?? {};
          const amount = money(ti.transaction_amount);
          if (!ti.transaction_id || !amount) continue;
          const pn = pi.payer_name ?? {};
          const name = pn.alternate_full_name ?? ([pn.given_name, pn.surname].filter(Boolean).join(' ') || null);
          out.push({
            id: ti.transaction_id, event_code: String(ti.transaction_event_code ?? ''), date: String(ti.transaction_initiation_date ?? ''),
            status: String(ti.transaction_status ?? ''), amount, fee: money(ti.fee_amount),
            payer_name: name, payer_email: pi.email_address ?? null, invoice_id: ti.invoice_id ?? null, subject: ti.transaction_subject ?? null,
          });
        }
      }
      return out;
    },

    async listDisputes() {
      const r = await rest('GET', '/v1/customer/disputes?page_size=50');
      return (r?.items ?? []).filter((d: any) => d?.dispute_id).map(dispute);
    },

    async getDispute(id) {
      let d: any;
      try {
        d = await rest('GET', `/v1/customer/disputes/${encodeURIComponent(id)}`);
      } catch (e) {
        if (e instanceof PayPalError && (e.upstream === 404 || e.upstream === 403)) return null;
        throw e;
      }
      const tx = d?.disputed_transactions?.[0];
      return {
        ...dispute(d),
        buyer_name: tx?.buyer?.name ?? null,
        transaction_id: tx?.seller_transaction_id ?? null,
        messages: (d?.messages ?? []).map((m: any) => ({ posted_by: String(m.posted_by ?? ''), time: String(m.time_posted ?? ''), content: String(m.content ?? '') })),
      };
    },

    async createDatedInvoice(i, requestId) {
      const [given, ...more] = (i.clientName ?? '').split(' ');
      const found = await rest('POST', '/v2/invoicing/search-invoices?page_size=1', { invoice_number: i.invoiceNumber });
      const inv = found?.items?.[0] ?? await rest('POST', '/v2/invoicing/invoices', {
        detail: {
          currency_code: i.currency, invoice_date: i.invoiceDate, reference: i.reference, invoice_number: i.invoiceNumber,
          payment_term: { due_date: i.dueDate },
        },
        ...(i.businessName ? { invoicer: { business_name: i.businessName } } : {}),
        primary_recipients: [{
          billing_info: { ...(i.clientName ? { name: { given_name: given, ...(more.length ? { surname: more.join(' ') } : {}) } } : {}), ...(i.clientEmail ? { email_address: i.clientEmail } : {}) },
        }],
        items: [{ name: i.item, quantity: '1', unit_amount: { currency_code: i.currency, value: i.value } }],
      }, `${requestId}-create`);
      if (!/^INV2-[A-Z0-9-]+$/.test(inv?.id ?? '')) throw new PayPalError('PayPal returned no invoice id', 502);
      if (inv.status === 'DRAFT') {
        await rest('POST', `/v2/invoicing/invoices/${inv.id}/send`, { send_to_recipient: false, send_to_invoicer: false }, `${requestId}-send`);
      }
      const now = await getInvoiceRaw(inv.id);
      return {
        id: inv.id, status: String(now?.status ?? 'UNPAID'), payLink: `${config.paypal.webUrl}/invoice/p/#${inv.id}`,
        dueDate: String(now?.detail?.payment_term?.due_date ?? i.dueDate),
      };
    },

    async recordPayment(id, p, requestId) {
      const r = await rest('POST', `/v2/invoicing/invoices/${encodeURIComponent(id)}/payments`, {
        method: p.method, payment_date: p.date, note: p.note, amount: { currency_code: p.currency, value: p.value },
      }, requestId);
      return { paymentId: String(r?.payment_id ?? '') };
    },

    async getSubscription(id) {
      const s = await rest('GET', `/v1/billing/subscriptions/${encodeURIComponent(id)}`);
      return {
        status: String(s?.status ?? 'UNKNOWN'), nextBillingAt: s?.billing_info?.next_billing_time ?? null,
        lastPaidAt: s?.billing_info?.last_payment?.time ?? null,
      };
    },

    async changeSubscription(id, to, reason, requestId) {
      await rest('POST', `/v1/billing/subscriptions/${encodeURIComponent(id)}/${to}`, { reason: reason.slice(0, 127) }, requestId);
    },

    async deleteRecordedPayment(invoiceId, paymentId, requestId) {
      await rest('DELETE', `/v2/invoicing/invoices/${encodeURIComponent(invoiceId)}/payments/${encodeURIComponent(paymentId)}`, undefined, requestId);
    },

    async cancelInvoice(id, notify, requestId) {
      await rest('POST', `/v2/invoicing/invoices/${encodeURIComponent(id)}/cancel`, { send_to_recipient: notify, send_to_invoicer: false }, requestId);
    },

    async recordRefund(id, r, requestId) {
      const out = await rest('POST', `/v2/invoicing/invoices/${encodeURIComponent(id)}/refunds`, {
        method: r.method, refund_date: r.date, amount: { currency_code: r.currency, value: r.value },
      }, requestId);
      return { refundId: String(out?.refund_id ?? '') };
    },

    async getBalances() {
      const r = await rest('GET', '/v1/reporting/balances');
      return (r?.balances ?? []).filter((b: any) => b?.currency && b?.available_balance?.value != null).map((b: any) => ({
        currency: String(b.currency), available: String(b.available_balance.value), primary: !!b.primary,
      }));
    },

    async createPayout(p, requestId) {
      const r = await rest('POST', '/v1/payments/payouts', {
        sender_batch_header: { sender_batch_id: requestId, email_subject: 'You have a payment', email_message: p.note.slice(0, 1000) },
        items: [{ recipient_type: p.phone ? 'PHONE' : 'EMAIL', receiver: p.phone ?? p.email, amount: { value: p.value, currency: p.currency }, note: p.note.slice(0, 4000), sender_item_id: requestId.slice(0, 63) }],
      }, requestId);
      const batchId = String(r?.batch_header?.payout_batch_id ?? '');
      if (!batchId) throw new PayPalError('PayPal returned no payout batch id', 502);
      return { batchId, status: String(r?.batch_header?.batch_status ?? 'PENDING') };
    },

    async getPayoutItem(batchId) {
      const r = await rest('GET', `/v1/payments/payouts/${encodeURIComponent(batchId)}`);
      const it = r?.items?.[0];
      return it?.payout_item_id ? { itemId: String(it.payout_item_id), status: String(it.transaction_status ?? 'PENDING') } : null;
    },

    async cancelPayoutItem(itemId, requestId) {
      const r = await rest('POST', `/v1/payments/payouts-item/${encodeURIComponent(itemId)}/cancel`, {}, requestId);
      return { status: String(r?.transaction_status ?? 'RETURNED') };
    },

    async acceptClaim(id, note, requestId) {
      await rest('POST', `/v1/customer/disputes/${encodeURIComponent(id)}/accept-claim`, { note: note.slice(0, 2000), accept_claim_type: 'REFUND' }, requestId);
    },

    async makeOffer(id, o, requestId) {
      await rest('POST', `/v1/customer/disputes/${encodeURIComponent(id)}/make-offer`, {
        note: o.note.slice(0, 2000), offer_type: 'REFUND', offer_amount: { currency_code: o.currency, value: o.value },
      }, requestId);
    },

    async sendDisputeMessage(id, message, requestId) {
      await rest('POST', `/v1/customer/disputes/${encodeURIComponent(id)}/send-message`, { message }, requestId);
    },

    async verifyWebhook(h, event) {
      if (!config.paypal.webhookId) return false;
      const r = await rest('POST', '/v1/notifications/verify-webhook-signature', {
        auth_algo: h['paypal-auth-algo'],
        cert_url: h['paypal-cert-url'],
        transmission_id: h['paypal-transmission-id'],
        transmission_sig: h['paypal-transmission-sig'],
        transmission_time: h['paypal-transmission-time'],
        webhook_id: config.paypal.webhookId,
        webhook_event: event,
      });
      return r?.verification_status === 'SUCCESS';
    },
  };
}

function createPartner(creds: Creds, accessToken: () => Promise<string>): PayPalPartner {
  const rest = createRest(creds, accessToken, null);
  const partnerId = () => {
    if (!config.paypal.partnerMerchantId) throw new PayPalError('PAYPAL_PARTNER_MERCHANT_ID is not set', 503);
    return encodeURIComponent(config.paypal.partnerMerchantId);
  };
  const orNullOn404 = async <T>(run: () => Promise<T>): Promise<T | null> => {
    try {
      return await run();
    } catch (e) {
      if (e instanceof PayPalError && e.upstream === 404) return null;
      throw e;
    }
  };
  return {
    async createReferral(trackingId, returnUrl) {
      const r = await rest('POST', '/v2/customer/partner-referrals', {
        tracking_id: trackingId,
        operations: [{
          operation: 'API_INTEGRATION',
          api_integration_preference: {
            rest_api_integration: {
              integration_method: 'PAYPAL', integration_type: 'THIRD_PARTY',
              third_party_details: { features: [...PARTNER_FEATURES] },
            },
          },
        }],
        products: ['EXPRESS_CHECKOUT'],
        legal_consents: [{ type: 'SHARE_DATA_CONSENT', granted: true }],
        partner_config_override: { return_url: returnUrl },
      });
      const actionUrl = (r?.links as { rel: string; href: string }[] | undefined)?.find((l) => l.rel === 'action_url')?.href;
      if (!actionUrl || !actionUrl.startsWith(`${config.paypal.webUrl}/`)) throw new PayPalError('PayPal returned no sign-up link', 502);
      return { actionUrl };
    },

    async merchantIdForTracking(trackingId) {
      const r = await orNullOn404(() => rest('GET', `/v1/customer/partners/${partnerId()}/merchant-integrations?tracking_id=${encodeURIComponent(trackingId)}`));
      return typeof r?.merchant_id === 'string' && r.merchant_id ? r.merchant_id : null;
    },

    async merchantStatus(merchantId) {
      const r = await orNullOn404(() => rest('GET', `/v1/customer/partners/${partnerId()}/merchant-integrations/${encodeURIComponent(merchantId)}`));
      if (!r || r.merchant_id !== merchantId) return null;
      // The seller granted this app's third-party permissions.
      const granted = (r.oauth_integrations ?? []).some((o: any) =>
        o?.integration_type === 'OAUTH_THIRD_PARTY' && (o?.oauth_third_party ?? []).some((t: any) => t?.partner_client_id === creds.clientId));
      return {
        merchantId, trackingId: typeof r.tracking_id === 'string' ? r.tracking_id : null,
        paymentsReceivable: r.payments_receivable === true, emailConfirmed: r.primary_email_confirmed === true,
        primaryEmail: typeof r.primary_email === 'string' ? r.primary_email : null, permissionsGranted: granted,
        legalName: typeof r.legal_name === 'string' && r.legal_name.trim() ? r.legal_name.trim() : null,
        currency: typeof r.primary_currency === 'string' && /^[A-Za-z]{3}$/.test(r.primary_currency) ? r.primary_currency.toUpperCase() : null,
      };
    },
  };
}

// sellerOf: the user's connected PayPal account, or null. Without one, the user runs on the shared sandbox demo merchant.
export function createPayPalProvider(creds: Creds, sellerOf: (userId: string) => Seller | null = () => null): PayPalProvider {
  const accessToken = createTokenSource(creds);
  const platform = createClient(creds, accessToken, null);
  const partner = createPartner(creds, accessToken);
  return {
    forUser: (userId: string) => {
      const seller = sellerOf(userId);
      return seller ? createClient(creds, accessToken, seller) : platform;
    },
    forAccount: (userId: string, account: string | null) => {
      if (!account) return platform;
      const seller = sellerOf(userId);
      if (seller?.account !== account) throw new PayPalError('the PayPal account that made this is no longer connected', 409);
      return createClient(creds, accessToken, seller);
    },
    platform: () => platform,
    partner: () => partner,
  };
}

export const getPayPalClientForUser = (provider: PayPalProvider, userId: string) => provider.forUser(userId);
