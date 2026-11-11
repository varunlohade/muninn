import { PayPalAgentToolkit } from '@paypal/agent-toolkit/ai-sdk';
import { config } from './config.ts';

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
};
// Explicit dates and a reference tag; sent without emailing the recipient. Used by the demo seed.
// invoiceNumber is unique per merchant, so a re-run finds the invoice a crashed run left behind instead of making a second one.
export type DatedInvoiceInput = InvoiceInput & { invoiceDate: string; dueDate: string; reference: string; invoiceNumber: string };
export type Money = { value: string; currency: string };
export type Interval = 'week' | 'month' | 'year';
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
  forUser(userId: string): PayPal;
  platform(): PayPal;
};

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

function createClient(creds: Creds): PayPal {
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

  async function accessToken(): Promise<string> {
    if (token && token.exp > Date.now()) return token.value;
    tokenInFlight ??= fetchToken().finally(() => { tokenInFlight = null; });
    return tokenInFlight;
  }

  async function rest(method: string, path: string, body?: unknown, requestId?: string): Promise<any> {
    const headers: Record<string, string> = { Authorization: `Bearer ${await accessToken()}`, 'Content-Type': 'application/json' };
    if (requestId) headers['PayPal-Request-Id'] = requestId;
    if (method !== 'GET') headers.Prefer = 'return=representation';
    const res = await fetch(`${config.paypal.baseUrl}${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(config.paypal.timeoutMs),
    });
    const text = await res.text();
    const data = text ? JSON.parse(text) : {};
    if (!res.ok) throw new PayPalError(`PayPal ${method} ${path.split('/').slice(0, 4).join('/')} failed (${res.status}): ${data?.name ?? ''} ${data?.details?.[0]?.issue ?? ''}`.trim(), 502, res.status);
    return data;
  }

  // One toolkit per PayPal client. The toolkit keeps its own token forever and takes the request id
  // from its context, so each call gets our cached token and its own PayPal-Request-Id. Calls run one at a time.
  const toolkit = new PayPalAgentToolkit({
    clientId: creds.clientId,
    clientSecret: creds.clientSecret,
    configuration: {
      actions: { invoices: { create: true, send: true, sendReminder: true } },
      context: { sandbox: config.paypal.sandbox },
    },
  });
  const tkClient = toolkit.client as unknown as { _accessToken?: string; _context: Record<string, unknown> };
  const tools = toolkit.getTools();
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

  async function getInvoiceRaw(id: string) {
    return rest('GET', `/v2/invoicing/invoices/${encodeURIComponent(id)}`);
  }

  return {
    async createAndSendInvoice(i, requestId) {
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

// One sandbox merchant for the hackathon. Real "Connect PayPal" swaps this lookup for per-user credentials.
export function createPayPalProvider(creds: Creds): PayPalProvider {
  const platform = createClient(creds);
  return {
    forUser: (_userId: string) => platform,
    platform: () => platform,
  };
}

export const getPayPalClientForUser = (provider: PayPalProvider, userId: string) => provider.forUser(userId);
