// A local stand-in Muninn server for the iOS app and UI tests: fake AI, fake PayPal, in-memory DB, no network.
// usage: npm run fake   (PORT=0 picks a free port; the first line printed names it)
// Debug routes: GET /_log, POST /_reset, POST /_paid/:id (invoice, order or subscription id), POST /_next {"cls": {...}, "ext": {...}, "group": {...}, "route": {...}}
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import type { Classification, Extraction } from '../src/ai.ts';
import { config, type AskGroup, type AskRoute } from '../src/config.ts';
import { sha256 } from '../src/crypto.ts';
import { DEMO_CATALOG, DEMO_PROFILE } from '../src/seed.ts';
import { paidEvent, setup, subscriptionPaidEvent, webhookHeaders } from '../test/helpers.ts';

if (process.env.PAYPAL_ENV === 'live' || process.env.NODE_ENV === 'production') {
  console.error('fake server refuses to start with PAYPAL_ENV=live or NODE_ENV=production');
  process.exit(1);
}
globalThis.fetch = async () => {
  throw new Error('the fake server makes no network calls');
};

const FAKE_TOKEN = 'pkd_fake';
// The app only accepts long pkd_ tokens, so the short public token is swapped for this one on the way in.
const INNER_TOKEN = 'pkd_fake_local_only_device_token';
const DAY = 86_400_000;

type Next = { cls?: Partial<Classification>; ext?: Partial<Extraction>; group?: { group?: AskGroup; confidence?: number }; route?: { route?: AskRoute; confidence?: number } };
type LogEntry = { method: string; path: string; status: number; body: unknown };

function build() {
  const next: Next = {};
  const take = <K extends keyof Next>(k: K): Next[K] => {
    const v = next[k];
    delete next[k];
    return v;
  };
  const env = setup({
    get cls() { return take('cls'); },
    get ext() { return take('ext'); },
    get group() { return take('group'); },
    get route() { return take('route'); },
    apple: async () => { throw new Error('no Sign in with Apple on the fake server'); },
  });
  const { db, cipher } = env;
  const userId = db.createUser();
  db.addDevice(userId, sha256(INNER_TOKEN), 'fake');
  db.putProfile(userId, DEMO_PROFILE);
  for (const it of DEMO_CATALOG) db.addItem(userId, { name: it.name, price_cents: it.price * 100, currency: 'USD' });
  const t = Date.now();
  const enc = (v: string) => cipher.encrypt(userId, v);
  db.insertInvoice({
    id: 'INV2-FAKE-UNPAID', user_id: userId, status: 'SENT', amount_cents: 12000, currency: 'USD', item: 'Color',
    client_name_enc: enc('Jordan Ray'), client_email_enc: enc('jordan.ray@example.com'), pay_link: 'https://paypal.test/inv/unpaid',
    due_at: t - 2 * DAY, created_at: t - 9 * DAY,
  });
  db.insertInvoice({
    id: 'INV2-FAKE-PAID', user_id: userId, status: 'SENT', amount_cents: 4500, currency: 'USD', item: 'Haircut',
    client_name_enc: enc('Maya Lopez'), client_email_enc: enc('maya.lopez@example.com'), pay_link: 'https://paypal.test/inv/paid',
    due_at: t + 6 * DAY, created_at: t - DAY,
  });
  db.setInvoiceStatus(userId, 'INV2-FAKE-PAID', 'PAID', t - 3600_000, 'CAP-FAKE-1');
  db.insertOrder({
    id: 'ORDER-FAKE-OPEN', user_id: userId, status: 'CREATED', amount_cents: 3500, currency: 'USD', item: 'Blowout',
    client_name_enc: enc('Ava Chen'), approve_link: 'https://paypal.test/approve/open', created_at: t - 2 * 3600_000,
  });
  return { ...env, next, log: [] as LogEntry[] };
}

let state = build();
const fake = new Hono();

fake.get('/_log', (c) => c.json({ requests: state.log, paypal: state.calls, ai: state.aiCalls }));
fake.post('/_reset', (c) => {
  state = build();
  return c.json({ ok: true });
});
fake.post('/_next', async (c) => {
  const b = (await c.req.json().catch(() => ({}))) as Next;
  if (b.cls) state.next.cls = b.cls;
  if (b.ext) state.next.ext = b.ext;
  if (b.group) state.next.group = b.group;
  if (b.route) state.next.route = b.route;
  return c.json({ ok: true, next: state.next });
});
// Plays the PayPal webhook the real server would get when the client pays.
fake.post('/_paid/:id', async (c) => {
  const id = c.req.param('id');
  // A repeat bill: the client approves it, then PayPal takes the first payment.
  const events = state.db.ownerOfInvoice(id) ? [paidEvent(id)]
    : state.db.ownerOfSubscription(id) ? [{ event_type: 'BILLING.SUBSCRIPTION.ACTIVATED', resource: { id } }, subscriptionPaidEvent(id, `SALE-${Date.now()}`)]
    : [{ event_type: 'CHECKOUT.ORDER.APPROVED', resource: { id } }];
  let handled = true;
  for (const event of events) {
    const res = await state.app.request('/webhooks/paypal', {
      method: 'POST', headers: { 'Content-Type': 'application/json', ...webhookHeaders }, body: JSON.stringify(event),
    });
    handled &&= !!((await res.json()) as { handled?: boolean }).handled;
  }
  return c.json({ ok: handled, id }, handled ? 200 : 404);
});

fake.all('*', async (c) => {
  const req = c.req.raw;
  const headers = new Headers(req.headers);
  if (headers.get('authorization') === `Bearer ${FAKE_TOKEN}`) headers.set('authorization', `Bearer ${INNER_TOKEN}`);
  const text = ['GET', 'HEAD'].includes(req.method) ? '' : await req.text();
  const res = await state.app.fetch(new Request(req.url, { method: req.method, headers, body: text || undefined }));
  let body: unknown = text || null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {}
  state.log.push({ method: req.method, path: new URL(req.url).pathname, status: res.status, body });
  return res;
});

serve({ fetch: fake.fetch, port: config.port, hostname: '127.0.0.1' }, (info) => {
  console.log(`fake muninn on http://127.0.0.1:${info.port}  token ${FAKE_TOKEN}`);
});
