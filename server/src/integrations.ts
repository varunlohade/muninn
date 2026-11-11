import type { Cipher } from './crypto.ts';
import type { Db } from './db.ts';
import { config } from './config.ts';

export type Capability =
  | 'invoices' | 'pay_links' | 'reminders' | 'subscriptions' | 'refunds' | 'transactions' | 'disputes'
  | 'contacts' | 'review_link' | 'payment_alerts'
  | 'device_reminders' | 'supplier_payouts' | 'bookings' | 'store_orders';

// server: the server holds the connection. device: the phone does the work and the server stores nothing.
export type Provider = {
  id: string;
  name: string;
  description: string | null;
  capabilities: Capability[];
  available: boolean;
  where: 'server' | 'device';
  // Returns the config to store (encrypted) for this user. PayPal connects to the one sandbox merchant.
  connect?(userId: string): Record<string, unknown>;
};

export const PROVIDERS: Provider[] = [
  {
    id: 'paypal',
    name: 'PayPal',
    description: 'Connected. Invoices, pay links, repeat billing, refunds, disputes.',
    capabilities: ['invoices', 'pay_links', 'reminders', 'subscriptions', 'refunds', 'transactions', 'disputes'],
    available: true,
    where: 'server',
    connect: () => ({ account: 'platform_merchant', environment: config.paypal.sandbox ? 'sandbox' : 'live' }),
  },
  { id: 'contacts', name: 'Contacts', description: "Pick a client's email from your contacts. Stays on this phone.", capabilities: ['contacts'], available: true, where: 'device' },
  { id: 'google_reviews', name: 'Google reviews', description: 'Paste your review link. Muninn adds it to thank-you messages.', capabilities: ['review_link'], available: true, where: 'server' },
  { id: 'slack', name: 'Slack', description: 'Get a message when a client pays.', capabilities: ['payment_alerts'], available: true, where: 'server' },
  { id: 'reminders', name: 'Reminders', description: null, capabilities: ['device_reminders'], available: false, where: 'device' },
  {
    id: 'paypal_payouts', name: 'Supplier payouts (PayPal)', description: 'Pay a supplier from the keyboard: "pay joe $200 joe@x.com".',
    capabilities: ['supplier_payouts'], available: true, where: 'server',
  },
  { id: 'calendly', name: 'Calendly', description: null, capabilities: ['bookings'], available: false, where: 'server' },
  { id: 'google_calendar', name: 'Google Calendar', description: null, capabilities: ['bookings'], available: false, where: 'server' },
  { id: 'shopify', name: 'Shopify orders', description: null, capabilities: ['store_orders'], available: false, where: 'server' },
];

export type IntegrationView = {
  id: string; name: string; description: string | null; capabilities: Capability[];
  status: 'connected' | 'not_connected' | 'on_device' | 'coming_soon'; connected_at: string | null;
};

// paypalLabel: the connected PayPal account, masked, or null while the user runs on the demo merchant.
export function createIntegrations(db: Db, cipher: Cipher, now: () => number, paypalLabel: (userId: string) => string | null = () => null) {
  function connect(userId: string, provider: Provider) {
    if (!provider.available || !provider.connect) throw new Error(`${provider.id} cannot connect yet`);
    const cfg = provider.connect(userId);
    db.putIntegration(userId, { provider: provider.id, status: 'connected', connected_at: now(), config_enc: cipher.encrypt(userId, JSON.stringify(cfg)) });
  }

  // PayPal is the platform's own merchant for the hackathon, so every user is connected on first use.
  function ensureDefaults(userId: string) {
    const have = new Set(db.listIntegrations(userId).map((r) => r.provider));
    for (const p of PROVIDERS) if (p.available && p.connect && !have.has(p.id)) connect(userId, p);
  }

  function status(userId: string, providerId: string): 'connected' | 'not_connected' {
    return db.listIntegrations(userId).some((r) => r.provider === providerId && r.status === 'connected') ? 'connected' : 'not_connected';
  }

  function list(userId: string): IntegrationView[] {
    ensureDefaults(userId);
    // Google reviews is the review link on the profile; supplier payouts ride on the PayPal row; the others have their own row.
    const reviewLink = !!db.getProfile(userId)?.review_url;
    const rows = new Map(db.listIntegrations(userId).map((r) => [r.provider, r]));
    const connected = (id: string, r: { status: string } | undefined) =>
      (id === 'google_reviews' ? reviewLink : (id === 'paypal_payouts' ? rows.get('paypal') : r)?.status === 'connected');
    const own = paypalLabel(userId);
    const describe = (p: Provider) => p.id !== 'paypal' ? p.description
      : own ? `PayPal connected \u00B7 ${own}` : 'Demo PayPal (sandbox)';
    return PROVIDERS.map((p) => {
      const r = rows.get(p.id);
      return {
        id: p.id, name: p.name, description: describe(p), capabilities: p.capabilities,
        status: !p.available ? 'coming_soon' : p.where === 'device' ? 'on_device' : connected(p.id, r) ? 'connected' : 'not_connected',
        connected_at: p.available && r?.connected_at ? new Date(r.connected_at).toISOString() : null,
      };
    });
  }

  return { connect, ensureDefaults, status, list };
}
