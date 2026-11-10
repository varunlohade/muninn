import { PayPalAgentToolkit } from '@paypal/agent-toolkit/ai-sdk';
import { config } from './config.ts';

export type InvoiceInput = {
  value: string; currency: string; item: string; clientName: string | null; clientEmail: string | null; businessName: string | null;
};
export type PayPal = {
  createAndSendInvoice(i: InvoiceInput, requestId: string): Promise<{ id: string; status: string; payLink: string | null }>;
  createOrder(i: { value: string; currency: string; item: string }, requestId: string): Promise<{ id: string; status: string; approveLink: string | null }>;
  getInvoice(id: string): Promise<{ status: string; captureId: string | null }>;
  remind(id: string, requestId: string): Promise<void>;
  captureOrder(id: string, requestId: string): Promise<{ status: string; captureId: string | null }>;
  refundCapture(captureId: string, value: string, currency: string, requestId: string): Promise<{ id: string; status: string }>;
  verifyWebhook(headers: Record<string, string | undefined>, event: unknown): Promise<boolean>;
  warmUp(): Promise<void>;
};
export type PayPalProvider = {
  forUser(userId: string): PayPal;
  platform(): PayPal;
};

export class PayPalError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
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
    if (!res.ok) throw new PayPalError(`PayPal ${method} ${path.split('/').slice(0, 4).join('/')} failed (${res.status}): ${data?.name ?? ''} ${data?.details?.[0]?.issue ?? ''}`.trim(), 502);
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
